--!nonstrict
-- Hermes Agent chat panel - the [[panel]] entry.
--
-- Port of v4's Panel.qml plus components/ApprovalCard.qml, MessageBubble.qml,
-- SummaryPopup.qml and MarkdownView.qml. The floating right-side panel is the closest v5
-- equivalent of v4's docked side panel; PinnedPanelWindow.qml has no v5 counterpart (there
-- is no layer-shell / always-on-top window API), so pinning is gone - see the README.
--
-- The panel owns no bridge state. It renders whatever the service published on
-- noctalia.state and asks for work by publishing a command:
--
--   hermes.state / hermes.bridge / hermes.providers / hermes.models   read
--   hermes.cmd = { op = ..., n = <nonce> }                            write
--
-- Layout, top to bottom: header, summary strip, approval card, tool-activity line, the
-- transcript scroll, the model picker (collapsed behind the header's sliders button) and
-- the composer.
--
-- Divergences from v4, all forced by the v5 UI vocabulary:
--   * ui.markdown replaces MarkdownLogic.js + MarkdownView.qml. It has no code-block
--     affordance, so the transcript pre-splits each assistant message on fenced code and
--     renders the fences itself as a monospace slab with a copy button.
--   * ui.label replaces the "markdown = false" plain-text mode user messages relied on.
--   * The provider/model comboboxes from the v4 Settings page live here instead, because
--     v5 settings are manifest-declared only.
--   * Pinning, the persistent side window, and the 1200 ms copy flash (replaced by a
--     two-tick flash on the panel's 1 s tick) are gone.

local ICON = "assets/hermes-icon.png"
-- A generic family alias, resolved through the system font database. noctalia.loadFont is
-- only needed for a family shipped as a file; if no "monospace" alias exists on the system
-- the labels simply fall back to the panel's default font.
local MONO_FONT = "monospace"

local STATUS_KEY = {
  offline = "status.offline",
  idle = "status.idle",
  busy = "status.busy",
  attention = "status.attention",
  degraded = "status.degraded",
  error = "status.error",
  unknown = "status.unknown",
}

-- Matches v4 Panel.statusColor(): unknown/idle/busy all render in the accent colour.
local STATUS_COLOR = {
  offline = "error",
  error = "error",
  attention = "#f59e0b",
  degraded = "#f97316",
  idle = "primary",
  busy = "primary",
  unknown = "primary",
}

local state = nil
local bridge = { status = "offline", error = "" }
local providers = { loading = false, error = "", items = {} }
local models = { provider = "", loading = false, error = "", items = {} }

-- Composer: the input is uncontrolled, so `draft` only mirrors it; bumping composerKey
-- recreates the field (and re-grabs focus) which is how it is cleared after a send.
local draft = ""
local composerKey = 0

-- Model picker.
local showPicker = false
local selectedProvider = ""
local selectedModel = ""
local persistModel = false
local providerLabels = {}
local providerKeys = {}
local modelLabels = {}
local modelEntries = {}

-- Copy-button flash (two panel ticks ~ 2 s; v4 used a 1200 ms timer).
local copiedKey = nil
local copiedTicks = 0

-- The state watches and the panel tick can fire while the panel is closed; there is nothing
-- to draw then, so they only re-render while it is open.
local isOpen = false

local cmdSeq = 0

-- Forward declaration: the code-block copy button (built before the tree assembler) needs to
-- re-render for its flash, and the tree assembler uses the copy button. A Lua local is only
-- visible after its declaration, so `render` is declared here and assigned below.
local render

-- ── Helpers ─────────────────────────────────────────────────────────────────────────────

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function asString(value)
  if type(value) == "string" then
    return value
  end
  return ""
end

-- Safe nested lookup: every snapshot field may be missing while the bridge is starting.
local function deep(root, ...)
  local node = root
  for _, key in ipairs({ ... }) do
    if type(node) ~= "table" then
      return nil
    end
    node = node[key]
  end
  return node
end

-- The nonce makes every command a distinct value, so sending the same prompt twice still
-- re-triggers the service's watcher on hermes.cmd.
local function sendCmd(cmd)
  cmdSeq += 1
  cmd.n = cmdSeq
  noctalia.state.set("hermes.cmd", cmd)
end

local function bridgeOnline()
  return type(bridge) == "table" and bridge.status == "online"
end

local function bridgeError()
  return type(bridge) == "table" and asString(bridge.error) or ""
end

local function derivedStatus()
  if not bridgeOnline() then
    return "offline"
  end
  local hermesStatus = asString(deep(state, "hermes", "status"))
  if hermesStatus ~= "" and hermesStatus ~= "unknown" then
    return hermesStatus
  end
  local gatewayStatus = asString(deep(state, "summary", "gateway", "status"))
  if gatewayStatus == "running" then
    return "idle"
  end
  return "unknown"
end

local function statusText(status)
  return noctalia.tr(STATUS_KEY[status] or "status.unknown")
end

local function statusColor(status)
  return STATUS_COLOR[status] or "primary"
end

local function sessionRunning()
  return deep(state, "session", "running") == true
end

local function isBusy()
  return sessionRunning() or asString(deep(state, "hermes", "status")) == "busy"
end

-- summary.model first (what the agent reports), then the session's own model, then the
-- configured defaults - the same precedence v4 Settings.qml and Panel.qml used.
local function modelLabel()
  local provider = asString(deep(state, "summary", "model", "provider"))
  if provider == "" then
    provider = asString(deep(state, "hermes", "provider"))
  end
  if provider == "" then
    provider = trim(noctalia.getConfig("defaultProvider"))
  end
  local model = asString(deep(state, "summary", "model", "name"))
  if model == "" then
    model = asString(deep(state, "hermes", "model"))
  end
  if model == "" then
    model = trim(noctalia.getConfig("defaultModel"))
  end
  if provider ~= "" and model ~= "" then
    return provider .. " / " .. model
  end
  if model ~= "" then
    return model
  end
  if provider ~= "" then
    return provider
  end
  return noctalia.tr("panel.no_model")
end

local function cronLabel()
  local active = deep(state, "summary", "cron", "active")
  local total = deep(state, "summary", "cron", "total")
  return noctalia.tr("summary.cron_value", {
    active = tostring(type(active) == "number" and active or 0),
    total = tostring(type(total) == "number" and total or 0),
  })
end

local function mcpLabel()
  local enabled = deep(state, "summary", "mcp", "enabled")
  local total = deep(state, "summary", "mcp", "total")
  local totalCount = type(total) == "number" and total or 0
  if totalCount == 0 then
    return noctalia.tr("summary.no_mcp_servers")
  end
  return noctalia.tr("summary.mcp_value", {
    enabled = tostring(type(enabled) == "number" and enabled or 0),
    total = tostring(totalCount),
  })
end

local function gatewayLabel()
  local platforms = deep(state, "summary", "gateway", "platforms")
  if type(platforms) == "table" then
    local parts = {}
    for name, value in pairs(platforms) do
      table.insert(parts, tostring(name) .. ": " .. tostring(value))
    end
    table.sort(parts)
    if #parts > 0 then
      return table.concat(parts, ", ")
    end
  end
  local status = asString(deep(state, "summary", "gateway", "status"))
  if status ~= "" then
    return status
  end
  return noctalia.tr("summary.unknown")
end

-- Tool-event counters computed by the bridge from its event list.
local function activityCounts()
  local count = deep(state, "summary", "activity", "tool_events")
  local running = deep(state, "summary", "activity", "running_tools")
  return type(count) == "number" and count or 0, type(running) == "number" and running or 0,
    asString(deep(state, "summary", "activity", "last_tool"))
end

-- The compact line above the transcript (v4 Panel.activityLabel).
local function activityLine()
  local count, running, last = activityCounts()
  if count == 0 then
    return ""
  end
  if running > 0 then
    return noctalia.tr("panel.background_running", { count = tostring(running) })
  end
  return noctalia.tr("panel.background_actions_last", {
    count = tostring(count),
    tool = last ~= "" and last or "tool",
  })
end

-- ── Fence splitting ─────────────────────────────────────────────────────────────────────
-- ui.markdown has no code-block slot, so assistant text is split on ``` / ~~~ fences and the
-- code is rendered by hand. An unterminated fence keeps the rest of the message as code,
-- matching MarkdownLogic.js's streaming behaviour in v4.

local function eachLine(text)
  local lines = {}
  local start = 1
  while true do
    local newline = text:find("\n", start, true)
    if newline == nil then
      table.insert(lines, text:sub(start))
      return lines
    end
    table.insert(lines, text:sub(start, newline - 1))
    start = newline + 1
  end
end

local function splitFences(text)
  local parts = {}
  local buffer = {}
  local inCode = false
  local lang = ""

  local function flush(kind)
    if kind == "code" then
      table.insert(parts, { kind = "code", lang = lang, text = table.concat(buffer, "\n") })
      lang = ""
    elseif #buffer > 0 then
      table.insert(parts, { kind = "text", text = table.concat(buffer, "\n") })
    end
    buffer = {}
  end

  for _, line in ipairs(eachLine(text)) do
    local fence, info = line:match("^%s*([`~]+)%s*([%w%+%-%._]*)%s*$")
    if fence ~= nil and #fence >= 3 then
      flush(inCode and "code" or "text")
      inCode = not inCode
      if inCode then
        lang = info or ""
      end
    else
      table.insert(buffer, line)
    end
  end
  flush(inCode and "code" or "text")
  return parts
end

-- ── Pieces ──────────────────────────────────────────────────────────────────────────────

local function copyCode(key, text)
  noctalia.copyToClipboard(text, "text/plain")
  copiedKey = key
  copiedTicks = 2
  render()
end

local function codeSlab(key, lang, text)
  local copied = copiedKey == key
  return ui.column({
    key = key,
    gap = 4,
    fill = "surface_variant/0.6",
    border = "outline",
    borderWidth = 1,
    radius = 6,
    padding = 8,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.label({
        text = lang ~= "" and lang or noctalia.tr("bubble.code"),
        fontSize = 10,
        fontWeight = "semibold",
        color = "on_surface_variant",
        flexGrow = 1,
      }),
      ui.button({
        glyph = copied and "check" or "copy",
        text = copied and noctalia.tr("bubble.copied") or noctalia.tr("bubble.copy"),
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("bubble.copy"),
        onClick = function()
          copyCode(key, text)
        end,
      }),
    }),
    ui.label({ text = text, fontFamily = MONO_FONT, fontSize = 12 }),
  })
end

local function messageRows()
  local rows = {}
  local messages = deep(state, "messages")
  if type(messages) ~= "table" or #messages == 0 then
    table.insert(rows, ui.column({ align = "center", gap = 6, padding = 20 }, {
      ui.glyph({
        name = bridgeOnline() and "message-circle" or "power",
        size = 28,
        color = "on_surface_variant",
      }),
      ui.label({
        text = bridgeOnline() and noctalia.tr("panel.no_session") or noctalia.tr("panel.bridge_offline"),
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
    return rows
  end

  for index, message in ipairs(messages) do
    if type(message) == "table" then
      local id = tostring(message.id or index)
      local role = asString(message.role) ~= "" and asString(message.role) or "assistant"
      local text = asString(message.text)
      if text == "" then
        text = asString(message.content)
      end

      if role == "user" then
        -- Literal text: v4 rendered user messages with markdown disabled so a typed "*" or
        -- "#" was never reinterpreted.
        table.insert(rows, ui.column({
          key = "u-" .. id,
          gap = 4,
          fill = "primary/0.18",
          radius = 8,
          padding = 8,
        }, {
          ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "user", size = 12, color = "primary" }),
            ui.label({ text = noctalia.tr("bubble.you"), fontSize = 11, fontWeight = "semibold", color = "primary" }),
          }),
          ui.label({ text = text }),
        }))
      else
        table.insert(rows, ui.row({ key = "a-" .. id .. "-h", gap = 4, align = "center" }, {
          ui.glyph({ name = "sparkles", size = 12, color = "primary" }),
          ui.label({
            text = noctalia.tr("bubble.hermes"),
            fontSize = 11,
            fontWeight = "semibold",
            color = "on_surface_variant",
            flexGrow = 1,
          }),
        }))
        for partIndex, part in ipairs(splitFences(text)) do
          if part.kind == "code" then
            table.insert(rows, codeSlab("a-" .. id .. "-c" .. partIndex, part.lang, part.text))
          elseif trim(part.text) ~= "" then
            table.insert(rows, ui.markdown({ key = "a-" .. id .. "-m" .. partIndex, text = part.text }))
          end
        end
      end
    end
  end
  return rows
end

local function summaryRow(labelKey, value)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = noctalia.tr(labelKey), fontSize = 11, color = "on_surface_variant", width = 76 }),
    ui.label({ text = value, fontSize = 11, color = "on_surface", flexGrow = 1, textAlign = "end", maxLines = 1 }),
  })
end

local function approvalCard()
  local approval = deep(state, "approval")
  if type(approval) ~= "table" or approval.pending ~= true then
    return nil
  end
  local toolName = asString(approval.tool_name)
  if toolName == "" then
    toolName = asString(approval.tool)
  end
  local message = asString(approval.message)
  if message == "" then
    message = asString(approval.reason)
  end

  return ui.column({
    gap = 8,
    fill = "#f59e0b24",
    border = "#f59e0b",
    borderWidth = 1,
    radius = 8,
    padding = 10,
  }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "shield-question", size = 18, color = "#f59e0b" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({
          text = toolName ~= "" and toolName or noctalia.tr("panel.approval_required"),
          fontWeight = "semibold",
          maxLines = 1,
        }),
        ui.label({ text = message, fontSize = 12, color = "on_surface_variant", visible = message ~= "" }),
      }),
    }),
    ui.row({ gap = 6, justify = "end" }, {
      ui.button({ text = noctalia.tr("panel.deny"), glyph = "x", onClick = "onDeny" }),
      ui.button({ text = noctalia.tr("panel.approve"), glyph = "check", variant = "primary", onClick = "onApprove" }),
      ui.button({ text = noctalia.tr("panel.approve_session"), glyph = "checks", onClick = "onApproveSession" }),
    }),
  })
end

-- ── Model picker ────────────────────────────────────────────────────────────────────────

local function buildProviderOptions()
  providerLabels = { noctalia.tr("settings.provider_current") }
  providerKeys = { "" }
  local seen = { [""] = true }
  local items = type(providers) == "table" and providers.items or nil
  if type(items) == "table" then
    for _, item in ipairs(items) do
      if type(item) == "table" then
        local key = asString(item.key)
        if key == "" then
          key = asString(item.provider)
        end
        if key ~= "" and not seen[key] then
          seen[key] = true
          local name = asString(item.name)
          table.insert(providerKeys, key)
          table.insert(providerLabels, name ~= "" and name ~= key and (name .. " (" .. key .. ")") or key)
        end
      end
    end
  end
  -- The active provider must always be selectable, even when /providers did not list it.
  if selectedProvider ~= "" and not seen[selectedProvider] then
    table.insert(providerKeys, selectedProvider)
    table.insert(providerLabels, selectedProvider)
  end
end

local function buildModelOptions()
  modelLabels = {}
  modelEntries = {}
  -- Only surface the list once it belongs to the provider that is actually selected; until
  -- the service answers load_models, `models` still holds the previous provider's list.
  if type(models) ~= "table" or asString(models.provider) ~= selectedProvider then
    return
  end
  local items = models.items
  if type(items) == "table" then
    for _, item in ipairs(items) do
      if type(item) == "table" then
        local model = asString(item.model)
        local provider = asString(item.provider)
        if model ~= "" then
          table.insert(modelEntries, { provider = provider, model = model })
          local name = asString(item.name)
          if name == "" then
            name = model
          end
          if provider ~= "" and name == model then
            name = model .. " (" .. provider .. ")"
          end
          table.insert(modelLabels, name)
        end
      end
    end
  end
end

local function providerIndex()
  for index, key in ipairs(providerKeys) do
    if key == selectedProvider then
      return index - 1
    end
  end
  return 0
end

local function modelIndex()
  for index, entry in ipairs(modelEntries) do
    if entry.provider == selectedProvider and entry.model == selectedModel then
      return index - 1
    end
  end
  return 0
end

-- Adopt whatever the session already reports so the dropdowns open on the live model, the
-- same way v4 Settings.qml seeded its fields from the detected model.
local function syncSelectionFromSnapshot()
  if selectedProvider == "" then
    local provider = asString(deep(state, "summary", "model", "provider"))
    if provider == "" then
      provider = asString(deep(state, "hermes", "provider"))
    end
    if provider == "" then
      provider = trim(noctalia.getConfig("defaultProvider"))
    end
    selectedProvider = provider
  end
  if selectedModel == "" then
    local model = asString(deep(state, "summary", "model", "name"))
    if model == "" then
      model = asString(deep(state, "hermes", "model"))
    end
    if model == "" then
      model = trim(noctalia.getConfig("defaultModel"))
    end
    selectedModel = model
  end
end

local function modelPicker()
  buildProviderOptions()
  buildModelOptions()

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("settings.provider_select"), fontSize = 11, color = "on_surface_variant", width = 76 }),
      ui.select({
        options = providerLabels,
        selectedIndex = providerIndex(),
        placeholder = noctalia.tr("settings.provider_select"),
        flexGrow = 1,
        onChange = "onProviderSelected",
      }),
    }),
  }

  local modelsError = type(models) == "table" and asString(models.error) or ""
  if type(models) == "table" and models.loading == true then
    table.insert(children, ui.label({ text = noctalia.tr("settings.models_loading"), fontSize = 11, color = "on_surface_variant" }))
  elseif modelsError ~= "" then
    table.insert(children, ui.label({ text = noctalia.tr("settings.models_failed", { error = modelsError }), fontSize = 11, color = "error" }))
  elseif #modelLabels > 0 then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("settings.model_select"), fontSize = 11, color = "on_surface_variant", width = 76 }),
      ui.select({
        options = modelLabels,
        selectedIndex = modelIndex(),
        placeholder = noctalia.tr("settings.model_select"),
        flexGrow = 1,
        onChange = "onModelSelected",
      }),
    }))
  end

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.toggle({ checked = persistModel, onChange = "onPersistToggled" }),
    ui.label({ text = noctalia.tr("settings.persist_model"), fontSize = 11, flexGrow = 1 }),
    ui.button({
      text = noctalia.tr("settings.apply_model"),
      glyph = "refresh",
      variant = "primary",
      controlSize = "sm",
      enabled = selectedModel ~= "",
      onClick = "onApplyModel",
    }),
  }))

  return ui.column({ gap = 6, border = "outline", borderWidth = 1, radius = 8, padding = 8 }, children)
end

-- ── Render ──────────────────────────────────────────────────────────────────────────────

render = function()
  local status = derivedStatus()
  local color = statusColor(status)
  local online = bridgeOnline()
  local busy = isBusy()
  local activity = activityLine()

  local sections = {}

  -- Header: icon, status dot, title + live model, status word, picker toggle, close.
  table.insert(sections, ui.row({ align = "center", gap = 8 }, {
    ui.image({ path = ICON, width = 20, height = 20, fit = "contain" }),
    ui.box({ width = 8, height = 8, radius = 4, fill = color }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = modelLabel(), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = statusText(status), fontSize = 12, color = color }),
    ui.button({
      glyph = "adjustments",
      variant = showPicker and "secondary" or "ghost",
      tooltip = noctalia.tr("panel.model_picker"),
      onClick = "onTogglePicker",
    }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
  }))

  -- Summary strip (the v4 SummaryPopup content, folded into the panel).
  table.insert(sections, ui.column({ gap = 2, fill = "surface_variant/0.4", radius = 8, padding = 8 }, {
    summaryRow("summary.model", modelLabel()),
    summaryRow("summary.cron", cronLabel()),
    summaryRow("summary.mcp", mcpLabel()),
    summaryRow("summary.gateway", gatewayLabel()),
    summaryRow("summary.activity", activity ~= "" and activity or noctalia.tr("summary.no_background_actions")),
  }))

  local card = approvalCard()
  if card ~= nil then
    table.insert(sections, card)
  end

  if activity ~= "" and (noctalia.getConfig("showToolActivity") == true or busy) then
    table.insert(sections, ui.row({ gap = 6, align = "center", fill = "surface_variant", radius = 6, paddingH = 8, paddingV = 4 }, {
      ui.glyph({ name = busy and "loader" or "activity", size = 14, color = "on_surface_variant" }),
      ui.label({ text = activity, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
    }))
  end

  -- A bridge-level error is worth showing even when the bridge is up (a failed gateway
  -- start, say), which is why this is separate from the offline empty state.
  local bridgeNotice = bridgeError()
  if online and bridgeNotice ~= "" then
    table.insert(sections, ui.row({ gap = 6, align = "center", fill = "error/0.15", radius = 6, paddingH = 8, paddingV = 4 }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
      ui.label({ text = bridgeNotice, fontSize = 12, flexGrow = 1, maxLines = 2 }),
    }))
  end

  table.insert(sections, ui.scroll({ flexGrow = 1, gap = 8, stickToBottom = true }, messageRows()))

  if showPicker then
    table.insert(sections, modelPicker())
  end

  table.insert(sections, ui.row({ gap = 6, align = "end" }, {
    ui.button({
      glyph = "plus",
      tooltip = noctalia.tr("panel.new_session"),
      onClick = "onNewSession",
    }),
    ui.input({
      key = "composer-" .. tostring(composerKey),
      value = draft,
      multiline = true,
      submitOnEnter = true,
      placeholder = noctalia.tr("panel.placeholder"),
      flexGrow = 1,
      focus = true,
      enabled = online,
      onChange = "onDraftChange",
      onSubmit = "onSubmitPrompt",
    }),
    ui.button({
      text = busy and noctalia.tr("panel.interrupt") or noctalia.tr("panel.send"),
      glyph = busy and "octagon" or "send",
      variant = busy and "destructive" or "primary",
      enabled = online and (busy or trim(draft) ~= ""),
      onClick = busy and "onInterrupt" or "onSendClicked",
    }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 8 }, sections))
end

-- ── Composer / actions ──────────────────────────────────────────────────────────────────

local function submitPrompt(value)
  local text = trim(value)
  if text == "" then
    return
  end
  -- The bridge's /prompt creates a session when there is none, so no create call is needed.
  sendCmd({ op = "prompt", text = text })
  draft = ""
  composerKey += 1
  render()
end

function onDraftChange(value)
  local had = trim(draft) ~= ""
  draft = value or ""
  -- Re-render only when emptiness flips, so the Send button enables exactly when v4's did
  -- without a full tree diff on every keystroke.
  if had ~= (trim(draft) ~= "") then
    render()
  end
end

function onSubmitPrompt(value)
  submitPrompt(value)
end

function onSendClicked()
  submitPrompt(draft)
end

function onInterrupt()
  sendCmd({ op = "interrupt" })
end

function onNewSession()
  sendCmd({ op = "new_session" })
end

function onApprove()
  sendCmd({ op = "approval", choice = "approved" })
end

function onApproveSession()
  sendCmd({ op = "approval", choice = "approved", all = true })
end

function onDeny()
  sendCmd({ op = "approval", choice = "denied" })
end

function onCloseClicked()
  panel.close()
end

function onTogglePicker()
  showPicker = not showPicker
  if showPicker then
    syncSelectionFromSnapshot()
    sendCmd({ op = "load_providers" })
    if selectedProvider ~= "" then
      sendCmd({ op = "load_models", provider = selectedProvider })
    end
  end
  render()
end

function onProviderSelected(index, _text)
  local position = (tonumber(index) or 0) + 1
  local key = providerKeys[position] or ""
  selectedProvider = key
  selectedModel = ""
  modelLabels = {}
  modelEntries = {}
  if key ~= "" then
    sendCmd({ op = "load_models", provider = key })
  end
  render()
end

function onModelSelected(index, _text)
  local position = (tonumber(index) or 0) + 1
  local entry = modelEntries[position]
  if entry == nil then
    return
  end
  selectedProvider = entry.provider
  selectedModel = entry.model
  render()
end

function onPersistToggled(value)
  persistModel = value == "true"
  render()
end

function onApplyModel()
  if selectedModel == "" then
    return
  end
  sendCmd({ op = "model", provider = selectedProvider, model = selectedModel, persist = persistModel })
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────────────────

function onOpen(_context)
  isOpen = true
  state = noctalia.state.get("hermes.state") or state
  bridge = noctalia.state.get("hermes.bridge") or bridge
  providers = noctalia.state.get("hermes.providers") or providers
  models = noctalia.state.get("hermes.models") or models
  copiedKey = nil
  copiedTicks = 0
  -- Panel ticks drive the copy-button flash (a 1 s resolution).
  panel.setWantsSecondTicks(true)
  syncSelectionFromSnapshot()
  sendCmd({ op = "refresh" })
  render()
end

function onClose()
  isOpen = false
  copiedKey = nil
  copiedTicks = 0
  panel.setWantsSecondTicks(false)
end

function update()
  if copiedTicks > 0 then
    copiedTicks -= 1
    if copiedTicks == 0 then
      copiedKey = nil
      if isOpen then
        render()
      end
    end
  end
end

noctalia.state.watch("hermes.state", function(value)
  state = type(value) == "table" and value or nil
  syncSelectionFromSnapshot()
  if isOpen then
    render()
  end
end)

noctalia.state.watch("hermes.bridge", function(value)
  bridge = type(value) == "table" and value or { status = "offline", error = "" }
  if isOpen then
    render()
  end
end)

noctalia.state.watch("hermes.providers", function(value)
  providers = type(value) == "table" and value or { loading = false, error = "", items = {} }
  if isOpen then
    render()
  end
end)

noctalia.state.watch("hermes.models", function(value)
  models = type(value) == "table" and value or { provider = "", loading = false, error = "", items = {} }
  -- Adopt the first model for the provider when nothing is selected yet, like v4's
  -- Settings.qml did (firstModelForProvider).
  if selectedModel == "" and selectedProvider ~= "" and asString(models.provider) == selectedProvider then
    buildModelOptions()
    local first = modelEntries[1]
    if first ~= nil then
      selectedModel = first.model
    end
  end
  if isOpen then
    render()
  end
end)
