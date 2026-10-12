--!nonstrict
-- Hermes Agent bridge service - the [[service]] entry.
--
-- This replaces the old v4 Main.qml, which owned the bridge process, the shared state
-- object and every HTTP call. v5 entries are isolated VMs with no shared Lua memory
-- (pluginApi.mainInstance does not exist), so this service is the only entry that talks
-- to the bridge and it republishes everything through noctalia.state:
--
--   hermes.state      the whole bridge snapshot (the state model, see the README)
--   hermes.bridge     { status = "online"|"offline", error = "<last error>" }
--   hermes.providers  { loading, error, items = { {key,name,source,status}, ... } }
--   hermes.models     { provider, loading, error, items = { {provider,model,name}, ... } }
--   hermes.cmd        command channel: a UI entry sets { op = ..., n = <nonce> }, the
--                     service runs it, then sets the key back to nil.
--
-- v4 behaviour preserved on purpose:
--   * /health is probed every statusPollIntervalSec; /state is polled fast (1.5 s) while
--     state.session.running and slowly when idle.
--   * a transport failure marks the bridge offline and keeps the message, exactly like
--     v4's setBridgeError().
--   * client-only mode never spawns anything locally and takes the token from settings;
--     otherwise the token is read from <stateFile dir>/bridge.token.
--   * autoStartBridge respawns after a failed health check; autoStartGateway starts the
--     Hermes gateway on the first-run detection.
--
-- Divergences forced by v5, all documented in the README:
--   * settings are read-only (there is no saveSettings), so the first-run /detect result
--     is latched in pluginDataDir()/detection.json instead of being written back.
--   * there is no file watch, so the state file is ignored and /state is polled instead.
--   * runAsync returns no PID, so stopping the bridge is a pkill by command line.
--   * the bridge is spawned with the argv form of runAsync (plugin_api 24), which avoids
--     any shell quoting around the paths.
--
-- NB: this file declares every piece of mutable state before the functions that touch it.
-- A Lua `local` is only visible to code textually after it, and the tick-loop counters are
-- referenced from most helpers below.

local TICK_MS = 500
-- 20 probes at 500 ms: the same ~10 s budget v4's bridgeRetryTimer allowed.
local START_MAX_ATTEMPTS = 20
-- A local bridge writes bridge.token right after it binds; 20 ticks is a generous window
-- before we tell the user the token never appeared.
local TOKEN_WAIT_MAX_TICKS = 20

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = 19777
local DEFAULT_STATE_FILE = "~/.cache/noctalia-hermes/state.json"
local DEFAULT_HOME = "~/.hermes"
local DEFAULT_COMMAND = "hermes"

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function log(message)
  noctalia.log("hermes-agent: " .. tostring(message))
end

-- ── Mutable state ───────────────────────────────────────────────────────────────────────

-- Configuration, re-read by readConfig() on load and on every onConfigChanged().
local host = DEFAULT_HOST
local port = DEFAULT_PORT
local stateFile = DEFAULT_STATE_FILE
local autoStartBridge = true
local autoStartGateway = true
local clientOnly = false
local tokenManual = ""
local pollSec = 30

-- First-run /detect latch (settings cannot be written back in v5).
local detected = { configured = false, hermesHome = "", hermesCommand = "" }

local token = ""
local tokenWaitTicks = 0

local bridgeStatus = "offline"
local bridgeError = ""

local currentSnapshot = nil
local stateInFlight = false
local healthInFlight = false

local providersState = { loading = false, error = "", items = {} }
local modelsState = { provider = "", loading = false, error = "", items = {} }

-- Tick loop: 500 ms resolution, with health/state cadences counted in ticks.
local tick = 0
local phase = "probe" -- "probe" | "starting" | "online"
local startAttempts = 0
local nextStartTick = 0
local nextHealthTick = 0
local nextStateTick = 0

-- ── Configuration ───────────────────────────────────────────────────────────────────────
-- noctalia.getConfig is read-only and single-argument: there is no fallback chain, so every
-- default is applied here by hand.

local function readConfig()
  local configuredHost = trim(noctalia.getConfig("bridgeHost"))
  host = configuredHost ~= "" and configuredHost or DEFAULT_HOST

  local configuredPort = noctalia.getConfig("bridgePort")
  if type(configuredPort) == "number" and configuredPort >= 1024 and configuredPort <= 65535 then
    port = math.floor(configuredPort)
  else
    port = DEFAULT_PORT
  end

  local configuredFile = trim(noctalia.getConfig("stateFile"))
  stateFile = configuredFile ~= "" and configuredFile or DEFAULT_STATE_FILE

  autoStartBridge = noctalia.getConfig("autoStartBridge") == true
  autoStartGateway = noctalia.getConfig("autoStartGateway") == true
  clientOnly = noctalia.getConfig("clientOnlyMode") == true
  tokenManual = trim(noctalia.getConfig("bridgeTokenManual"))

  local configuredPoll = noctalia.getConfig("statusPollIntervalSec")
  if type(configuredPoll) == "number" and configuredPoll >= 5 and configuredPoll <= 300 then
    pollSec = math.floor(configuredPoll)
  else
    pollSec = 30
  end
end

-- ── First-run detection persistence ─────────────────────────────────────────────────────
-- v4 stored the /detect result in settings (hermesHome, hermesCommand, the default model,
-- and a `configured` latch). v5 cannot write settings, so only the latch and the two paths
-- are kept. They are a fallback for when the user leaves the declared defaults in place -
-- the bridge auto-detects on its own when it is handed "~/.hermes"/"hermes".

local function detectionPath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return dir .. "/detection.json"
end

local function saveDetected()
  local path = detectionPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(detected)
  if type(encoded) == "string" then
    noctalia.writeFile(path, encoded)
  end
end

local function loadDetected()
  local path = detectionPath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or trim(raw) == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  detected.configured = decoded.configured == true
  if type(decoded.hermesHome) == "string" then
    detected.hermesHome = decoded.hermesHome
  end
  if type(decoded.hermesCommand) == "string" then
    detected.hermesCommand = decoded.hermesCommand
  end
end

-- The declared defaults double as "the user did not choose", so a detected path wins over
-- them. An explicit non-default value always wins.
local function effectiveHome()
  local configured = trim(noctalia.getConfig("hermesHome"))
  if configured ~= "" and configured ~= DEFAULT_HOME then
    return configured
  end
  if detected.hermesHome ~= "" then
    return detected.hermesHome
  end
  return configured ~= "" and configured or DEFAULT_HOME
end

local function effectiveCommand()
  local configured = trim(noctalia.getConfig("hermesCommand"))
  if configured ~= "" and configured ~= DEFAULT_COMMAND then
    return configured
  end
  if detected.hermesCommand ~= "" then
    return detected.hermesCommand
  end
  return configured ~= "" and configured or DEFAULT_COMMAND
end

-- Resolved once per configuration read (and once after detection), so spawnBridge passes the
-- values actually in effect and onConfigChanged can tell whether a path changed. It cannot
-- live inside readConfig(): effectiveHome/effectiveCommand are declared below it, and a Lua
-- local is not visible to code textually above it.
local hermesHomeResolved = DEFAULT_HOME
local hermesCommandResolved = DEFAULT_COMMAND

local function resolvePaths()
  hermesHomeResolved = effectiveHome()
  hermesCommandResolved = effectiveCommand()
end

-- ── Endpoint and token plumbing ─────────────────────────────────────────────────────────

-- The token lives next to the state file (the bridge derives it the same way), and the
-- server helper script prints it from there.
local function stateDir()
  local file = noctalia.expandPath(stateFile)
  local dir = file:match("^(.*)/[^/]*$")
  if dir == nil or dir == "" then
    return noctalia.expandPath("~/.cache/noctalia-hermes")
  end
  return dir
end

local function targetLabel()
  return host .. ":" .. tostring(port)
end

local function baseUrl()
  return "http://" .. host .. ":" .. tostring(port)
end

local function readTokenFromFile()
  local raw = noctalia.readFile(stateDir() .. "/bridge.token")
  if type(raw) == "string" then
    local value = trim(raw)
    if value ~= "" then
      return value
    end
  end
  return nil
end

-- ── Bridge status ───────────────────────────────────────────────────────────────────────

local function publishBridge()
  noctalia.state.set("hermes.bridge", { status = bridgeStatus, error = bridgeError })
end

-- offline = false keeps the bridge "online" while still surfacing an operation error (a 500
-- from /gateway/start, say). v4 flipped the whole bridge offline on any non-2xx; that made
-- the bar pill claim the bridge was gone when it had just answered, so only transport and
-- auth failures take the pill down now.
local function setBridgeError(message, offline)
  bridgeError = message or ""
  if offline ~= false then
    bridgeStatus = "offline"
  end
  publishBridge()
end

local function markOnline()
  if bridgeStatus ~= "online" or bridgeError ~= "" then
    bridgeStatus = "online"
    bridgeError = ""
    publishBridge()
  end
end

-- ── HTTP ────────────────────────────────────────────────────────────────────────────────
-- One helper for every call, mirroring v4's getJson/postJson error mapping: status 0 ->
-- "unreachable", 403 -> "wrong bridge token", everything else -> the failure text. A JSON
-- body is preferred over the bare status code, which is how the specific gateway/oneshot
-- messages reach the UI.

local function request(method, path, body, auth, onOk, onErr)
  local headers = {}
  local options = { method = method, url = baseUrl() .. path, headers = headers }

  if auth and token ~= "" then
    table.insert(headers, "X-Bridge-Token: " .. token)
  end

  if body ~= nil then
    if type(body) == "string" then
      -- Passed literally: an empty Lua table can encode as [] rather than {}, and the
      -- bridge rejects a non-object body with "invalid_payload".
      options.body = body
    else
      options.body = noctalia.json.encode(body) or "{}"
    end
    table.insert(headers, "Content-Type: application/json")
  end

  noctalia.http(options, function(res)
    local decoded
    if type(res.body) == "string" and res.body ~= "" then
      local value = noctalia.json.decode(res.body)
      if type(value) == "table" then
        decoded = value
      end
    end

    local transportOk = res.ok and res.status ~= 0
    if transportOk and res.status >= 200 and res.status < 300 then
      if decoded == nil then
        setBridgeError(noctalia.tr("error.invalid_response"))
        return
      end
      if onOk then
        onOk(decoded)
      end
      return
    end

    local message
    local offline = true
    if not transportOk then
      message = noctalia.tr("error.connection_failed", { target = targetLabel() })
    elseif res.status == 403 then
      message = noctalia.tr("error.auth_failed")
      -- The cached token is stale (the bridge restarted, or client-only mode was switched):
      -- drop it so the next tick re-reads bridge.token.
      if not clientOnly then
        token = ""
        tokenWaitTicks = 0
      end
    else
      local text
      if decoded ~= nil then
        if type(decoded.message) == "string" and decoded.message ~= "" then
          text = decoded.message
        elseif type(decoded.error) == "string" and decoded.error ~= "" then
          text = decoded.error
        end
      end
      message = text or noctalia.tr("error.request_failed", { status = tostring(res.status) })
      offline = false
    end

    if onErr then
      onErr(message, offline)
    else
      setBridgeError(message, offline)
    end
  end)
  return true
end

local function get(path, auth, onOk, onErr)
  return request("GET", path, nil, auth, onOk, onErr)
end

local function post(path, body, onOk, onErr)
  return request("POST", path, body, true, onOk, onErr)
end

-- ── Snapshot plumbing ───────────────────────────────────────────────────────────────────

local function applySnapshot(data)
  if type(data) ~= "table" then
    return
  end
  currentSnapshot = data
  noctalia.state.set("hermes.state", data)
end

-- A response to a mutating call is either the raw snapshot (/session/create) or
-- { result, state }; `data.state or data` unwraps both, exactly like the v4 callers did.
local function applyWrapped(data)
  local snapshot = data.state
  if type(snapshot) ~= "table" then
    snapshot = data
  end
  -- Guard against a response that carries no snapshot at all: publishing, say, only
  -- { result = ... } as hermes.state would blank the transcript.
  if type(snapshot) ~= "table" or (snapshot.session == nil and snapshot.bridge == nil) then
    return
  end
  applySnapshot(snapshot)
end

local function sessionRunning()
  local session = currentSnapshot ~= nil and currentSnapshot.session or nil
  return type(session) == "table" and session.running == true
end

-- 1500 ms while a prompt streams, otherwise the configured interval (pollSec * 2 ticks).
local function stateIntervalTicks()
  if sessionRunning() then
    return 3
  end
  return pollSec * 2
end

local function fetchState()
  if stateInFlight then
    return
  end
  stateInFlight = true
  nextStateTick = tick + stateIntervalTicks()
  get("/state", true, function(data)
    stateInFlight = false
    markOnline()
    applySnapshot(data)
  end, function(message, offline)
    stateInFlight = false
    setBridgeError(message, offline)
  end)
end

-- ── Bridge operations ───────────────────────────────────────────────────────────────────

local function opNewSession()
  post("/session/create", "{}", function(data)
    markOnline()
    applyWrapped(data)
  end)
end

local function opResume(sessionId)
  if trim(sessionId) == "" then
    return
  end
  post("/session/resume", { session_id = sessionId }, function(data)
    markOnline()
    applyWrapped(data)
  end)
end

-- /prompt creates a session server-side when there is none, so the composer never needs a
-- separate create call (the bridge's _handle_prompt does exactly this).
local function opPrompt(text)
  local value = trim(text)
  if value == "" then
    return
  end
  post("/prompt", { text = value }, function(data)
    markOnline()
    applyWrapped(data)
  end)
end

local function opInterrupt()
  post("/interrupt", "{}", function(data)
    markOnline()
    applyWrapped(data)
  end)
end

local function opApproval(choice, all)
  post("/approval", { choice = choice, all = all == true }, function(data)
    markOnline()
    applyWrapped(data)
  end)
end

local function opModel(provider, model, persist)
  local value = trim(model)
  if value == "" then
    return
  end
  post("/model", { provider = provider or "", model = value, persist = persist == true }, function(data)
    markOnline()
    applyWrapped(data)
  end)
end

-- `hermes -z <text>` on the server; the bridge waits up to 600 s for it.
local function opOneShot(text)
  local value = trim(text)
  if value == "" then
    return
  end
  post("/oneshot", { text = value }, function(data)
    markOnline()
    applyWrapped(data)
  end)
end

local function opGatewayStart()
  post("/gateway/start", "{}", function()
    markOnline()
    fetchState()
  end)
end

local function opGatewayStop()
  post("/gateway/stop", "{}", function()
    markOnline()
    fetchState()
  end)
end

-- ── Provider/model catalogue ────────────────────────────────────────────────────────────
-- The v4 Settings.qml comboboxes were fed by GET /providers and GET /models. v5 has no
-- custom settings UI, so the service fetches the same endpoints and the chat panel's
-- dropdowns read the published result.

local function publishProviders()
  noctalia.state.set("hermes.providers", {
    loading = providersState.loading,
    error = providersState.error,
    items = providersState.items,
  })
end

local function publishModels()
  noctalia.state.set("hermes.models", {
    provider = modelsState.provider,
    loading = modelsState.loading,
    error = modelsState.error,
    items = modelsState.items,
  })
end

local function opLoadProviders()
  providersState.loading = true
  providersState.error = ""
  publishProviders()
  get("/providers", true, function(data)
    providersState.loading = false
    providersState.error = ""
    providersState.items = type(data.providers) == "table" and data.providers or {}
    markOnline()
    publishProviders()
  end, function(message, offline)
    providersState.loading = false
    providersState.error = message
    publishProviders()
    setBridgeError(message, offline)
  end)
end

local function opLoadModels(provider, refresh)
  local key = trim(provider)
  modelsState.provider = key
  modelsState.items = {}
  if key == "" then
    modelsState.loading = false
    modelsState.error = ""
    publishModels()
    return
  end
  modelsState.loading = true
  modelsState.error = ""
  publishModels()
  local path = "/models?provider=" .. noctalia.string.urlEncode(key) .. "&refresh=" .. (refresh and "1" or "0")
  get(path, true, function(data)
    modelsState.loading = false
    modelsState.items = type(data.models) == "table" and data.models or {}
    modelsState.error = type(data.error) == "string" and data.error or ""
    markOnline()
    publishModels()
  end, function(message, offline)
    modelsState.loading = false
    modelsState.error = message
    publishModels()
    setBridgeError(message, offline)
  end)
end

-- ── First-run auto-configuration ────────────────────────────────────────────────────────

local function autoConfigure()
  -- Latched before the request so one failure cannot retry /detect on every poll. v4 ran it
  -- once per install too (it flipped the `configured` setting).
  detected.configured = true
  saveDetected()
  get("/detect", false, function(data)
    if type(data.hermesHome) == "string" and data.hermesHome ~= "" then
      detected.hermesHome = data.hermesHome
    end
    if type(data.hermesCommand) == "string" and data.hermesCommand ~= "" then
      detected.hermesCommand = data.hermesCommand
    end
    saveDetected()
    -- A later respawn should use the detected paths rather than the declared defaults.
    resolvePaths()
    log("detected hermes home: " .. tostring(detected.hermesHome))
    if autoStartGateway and type(data.gateway) == "table" then
      local status = tostring(data.gateway.status or "")
      if status == "offline" or status == "stopped" or status == "unknown" then
        opGatewayStart()
      end
    end
  end, function(message)
    log("detection failed: " .. tostring(message))
  end)
end

-- ── Process lifecycle ───────────────────────────────────────────────────────────────────

-- No PID is available from runAsync, so the bridge is killed by matching its command line.
-- Deliberately blunt: it also matches a bridge the user started by hand with
-- scripts/hermes-bridge-serve.sh. The official mpvpaper plugin documents the same
-- limitation. Only called when the plugin is torn down or client-only mode is enabled.
local function stopBridge()
  if clientOnly then
    return
  end
  log("stopping local bridge (pkill hermes_bridge.py)")
  noctalia.runAsync({ "pkill", "-f", "hermes_bridge.py" })
end

local function spawnBridge()
  if clientOnly or phase == "starting" then
    return
  end
  local dir = noctalia.pluginDir()
  if type(dir) ~= "string" or dir == "" then
    setBridgeError(noctalia.tr("error.bridge_spawn_failed"))
    return
  end

  phase = "starting"
  startAttempts = 0
  nextStartTick = tick + 1
  -- The bridge writes a fresh token when it starts, so forget the cached one.
  token = ""
  tokenWaitTicks = 0

  local launched = noctalia.runAsync({
    "python3",
    dir .. "/scripts/hermes_bridge.py",
    "--host", host,
    "--port", tostring(port),
    "--state-file", noctalia.expandPath(stateFile),
    "--hermes-home", noctalia.expandPath(hermesHomeResolved),
    "--hermes-command", hermesCommandResolved,
  })
  if not launched then
    phase = "probe"
    setBridgeError(noctalia.tr("error.bridge_spawn_failed"))
  end
end

local function handleUnreachable()
  if clientOnly then
    setBridgeError(noctalia.tr("error.remote_unreachable", { target = targetLabel() }))
  elseif autoStartBridge then
    spawnBridge()
  else
    setBridgeError(noctalia.tr("error.connection_failed", { target = targetLabel() }))
  end
end

local function onBridgeOnline()
  phase = "online"
  startAttempts = 0
  markOnline()
  if not detected.configured then
    autoConfigure()
  end
  fetchState()
end

local function ensureBridge()
  if healthInFlight then
    return
  end
  healthInFlight = true
  get("/health", false, function(data)
    healthInFlight = false
    if type(data.bridge) == "table" and data.bridge.status == "online" then
      onBridgeOnline()
    else
      handleUnreachable()
    end
  end, function()
    healthInFlight = false
    handleUnreachable()
  end)
end

-- ── Command channel ─────────────────────────────────────────────────────────────────────
-- UI entries cannot share Lua memory, so they publish { op = ... } on hermes.cmd and this
-- watcher runs it. Each command carries an `n` nonce from the caller: two identical prompts
-- in a row would otherwise be the same value and might not re-trigger the watcher.

local function runCommand(cmd)
  local op = cmd.op
  if op == "refresh" then
    ensureBridge()
  elseif op == "new_session" then
    opNewSession()
  elseif op == "resume" then
    opResume(cmd.session_id)
  elseif op == "prompt" then
    opPrompt(cmd.text)
  elseif op == "interrupt" then
    opInterrupt()
  elseif op == "approval" then
    opApproval(trim(cmd.choice), cmd.all)
  elseif op == "model" then
    opModel(cmd.provider, cmd.model, cmd.persist)
  elseif op == "oneshot" then
    opOneShot(cmd.text)
  elseif op == "gateway_start" then
    opGatewayStart()
  elseif op == "gateway_stop" then
    opGatewayStop()
  elseif op == "load_providers" then
    opLoadProviders()
  elseif op == "load_models" then
    opLoadModels(cmd.provider, cmd.refresh)
  else
    log("unknown command op: " .. tostring(op))
  end
end

noctalia.state.watch("hermes.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  runCommand(cmd)
  noctalia.state.set("hermes.cmd", nil)
end)

-- ── IPC ─────────────────────────────────────────────────────────────────────────────────
-- noctalia msg plugin chengongliang/hermes-agent:bridge all <event> [payload]

function onIpc(event, payload)
  local text = payload or ""
  if event == "refresh" then
    runCommand({ op = "refresh" })
  elseif event == "new-session" then
    runCommand({ op = "new_session" })
  elseif event == "resume" then
    runCommand({ op = "resume", session_id = text })
  elseif event == "prompt" then
    runCommand({ op = "prompt", text = text })
  elseif event == "oneshot" then
    runCommand({ op = "oneshot", text = text })
  elseif event == "interrupt" then
    runCommand({ op = "interrupt" })
  elseif event == "approve" then
    runCommand({ op = "approval", choice = "approved" })
  elseif event == "approve-all" then
    runCommand({ op = "approval", choice = "approved", all = true })
  elseif event == "deny" then
    runCommand({ op = "approval", choice = "denied" })
  elseif event == "gateway-start" then
    runCommand({ op = "gateway_start" })
  elseif event == "gateway-stop" then
    runCommand({ op = "gateway_stop" })
  elseif event == "providers" then
    runCommand({ op = "load_providers" })
  end
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────────────────

function onEnable()
  log("enabled")
  phase = "probe"
  nextHealthTick = tick
end

function onExit(_signal, reason)
  -- A reload keeps the bridge: the new runtime re-detects it through /health, and a second
  -- spawn would only fail to bind the port.
  if reason == "disable" or reason == "uninstall" or reason == "shutdown" then
    stopBridge()
  end
end

function onConfigChanged()
  -- getConfig() already returns the new values here, so the previous state comes from the
  -- locals the last readConfig()/resolvePaths() left behind.
  local wasClientOnly = clientOnly
  local wasHost = host
  local wasPort = port
  local wasStateFile = stateFile
  local wasHome = hermesHomeResolved
  local wasCommand = hermesCommandResolved

  readConfig()
  resolvePaths()

  local targetChanged = host ~= wasHost
    or port ~= wasPort
    or stateFile ~= wasStateFile
    or hermesHomeResolved ~= wasHome
    or hermesCommandResolved ~= wasCommand

  if clientOnly ~= wasClientOnly then
    -- Same runtime switch v4 performed: enabling client-only tears the local bridge down
    -- and hands the token over to the settings field.
    if clientOnly then
      stopBridge()
      token = tokenManual
    else
      token = ""
    end
    tokenWaitTicks = 0
    phase = "probe"
    bridgeStatus = "offline"
    bridgeError = ""
    publishBridge()
  elseif targetChanged and not clientOnly then
    -- The endpoint moved. Dropping back to probing re-detects a healthy bridge on the new
    -- address, and spawns a new one when nothing answers there. The old process (if any) is
    -- left alone - killing it here could take down a bridge the user runs by hand.
    phase = "probe"
    token = ""
    tokenWaitTicks = 0
    bridgeStatus = "offline"
    bridgeError = ""
    publishBridge()
  end

  -- Re-arm both cadences with the new interval.
  nextHealthTick = tick
  nextStateTick = tick
  log("configuration changed")
end

-- ── Tick loop ───────────────────────────────────────────────────────────────────────────

function update()
  tick += 1

  -- Local mode: pick up bridge.token as soon as the bridge writes it, or re-read it after a
  -- stale-token 403 cleared the cache.
  if not clientOnly and token == "" then
    local fromFile = readTokenFromFile()
    if fromFile ~= nil then
      token = fromFile
      tokenWaitTicks = 0
      log("bridge token loaded")
    end
  end

  if phase == "starting" then
    if tick >= nextStartTick then
      nextStartTick = tick + 1
      startAttempts += 1
      if startAttempts > START_MAX_ATTEMPTS then
        phase = "probe"
        startAttempts = 0
        setBridgeError(noctalia.tr("error.bridge_start_failed"))
        nextHealthTick = tick + pollSec * 2
      elseif not healthInFlight then
        healthInFlight = true
        get("/health", false, function(data)
          healthInFlight = false
          if type(data.bridge) == "table" and data.bridge.status == "online" then
            onBridgeOnline()
          end
        end, function()
          -- Expected while the process is still booting; the attempt budget handles it.
          healthInFlight = false
        end)
      end
    end
    return
  end

  if tick >= nextHealthTick then
    nextHealthTick = tick + pollSec * 2
    ensureBridge()
  end

  if bridgeStatus == "online" and tick >= nextStateTick then
    -- Authenticated calls wait for the token; without it every /state would be a 403.
    if clientOnly or token ~= "" then
      fetchState()
    else
      nextStateTick = tick + 1
      tokenWaitTicks += 1
      if tokenWaitTicks == TOKEN_WAIT_MAX_TICKS then
        setBridgeError(noctalia.tr("error.token_missing"), false)
      end
    end
  end
end

-- ── Entry point ─────────────────────────────────────────────────────────────────────────

-- Detection first: effectiveHome/effectiveCommand fall back to it when the settings keep
-- their declared defaults.
loadDetected()
readConfig()
resolvePaths()
if clientOnly then
  token = tokenManual
end
noctalia.setUpdateInterval(TICK_MS)
publishBridge()
publishProviders()
publishModels()
