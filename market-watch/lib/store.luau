--!nonstrict
-- Runtime state and configuration files.
--
-- The manifest settings are READ-ONLY (noctalia.getConfig has no setter), so every
-- value the user can change from the settings panel lives here instead: the watch
-- list, the bar asset, the display mode and both alert rules. They are stored as
-- JSON under noctalia.pluginDataDir()/market.json, which survives plugin updates.
--
-- This module owns three things:
--   1. watch-list normalisation (the v4 symbol / instrument-reference grammar),
--   2. loading and saving market.json,
--   3. the ~/Downloads/crypto-market-config.json export/import file.
--
-- lib/providers.luau and lib/alerts.luau are pure and take no host dependency;
-- this module is the one that calls noctalia (json + filesystem), so it is not
-- exercised by the lua5.4 harness. They are injected through configure() rather
-- than required from here: `require` paths inside a subdirectory are not
-- specified to resolve relative to the requiring file, so the service - which
-- sits in the plugin root - loads them and hands them over.

local Store = {}

-- Bumping this marks a watch list that has been fully rewritten from bare symbols
-- to "<provider>:<marketType>:<exchangeSymbol>" ids. v4 wrote it as a marker only
-- and never branched on the stored value; the port keeps that behaviour so an
-- older market.json still loads.
Store.SCHEMA_VERSION = 2

Store.DEFAULT_WATCH_LIST = { "btc", "eth", "bnb", "sol", "xrp" }
Store.VALID_SOURCES = { "huobi", "binance", "okx", "coingecko" }
Store.VALID_MARKET_TYPES = { "spot", "perpetual" }
Store.VALID_DISPLAY_MODES = { "text", "compact" }

-- v4 accepted "zh" as an alias; only the legacy config file can still carry it.
local LEGACY_LANGUAGE_ALIASES = { en = "en", ["zh-CN"] = "zh-CN", zh = "zh-CN" }

local deps = nil

function Store.configure(providers, alerts)
  deps = { providers = providers, alerts = alerts }
  return Store
end

local function providers()
  return deps and deps.providers or nil
end

local function alerts()
  return deps and deps.alerts or nil
end

-- The host documents noctalia.json.decode as returning (value, err), but a parse
-- error is the one failure that must never escape into a service callback: a raised
-- error would abort the whole command handler. pcall makes either behaviour safe.
local function decode_json(text)
  local ok, value, err = pcall(noctalia.json.decode, text)
  if not ok then
    return nil, tostring(value)
  end
  return value, err
end

local function log(message)
  if type(noctalia) == "table" and noctalia.log ~= nil then
    noctalia.log("market-watch: " .. message)
  end
end

local function includes(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

Store.includes = includes

local function trim(value)
  local text = type(value) == "string" and value or (value == nil and "" or tostring(value))
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

Store.trim = trim

-- ── References ──────────────────────────────────────────────────────────────

-- "<provider>:<marketType>:<exchangeSymbol>", where the exchange symbol may
-- itself contain colons (OKX style suffixes). Anything else is a legacy bare
-- symbol such as "btc".
function Store.reference_parts(text)
  local value = trim(text)
  if value == "" then
    return nil
  end

  local parts = {}
  for part in (value .. ":"):gmatch("([^:]*):") do
    table.insert(parts, part)
  end

  if #parts < 3 then
    return nil
  end
  if not includes(Store.VALID_SOURCES, parts[1]) then
    return nil
  end
  if not includes(Store.VALID_MARKET_TYPES, parts[2]) then
    return nil
  end

  local exchange_symbol = table.concat(parts, ":", 3)
  if exchange_symbol == "" then
    return nil
  end

  return {
    id = value,
    provider = parts[1],
    market_type = parts[2],
    exchange_symbol = exchange_symbol,
  }
end

function Store.is_qualified(reference, source, market_type)
  local parts = Store.reference_parts(reference)
  return parts ~= nil and parts.provider == source and parts.market_type == market_type
end

-- One watch entry: a fully qualified id stays as it is, an object contributes its
-- `id`, and anything else is normalised to a bare symbol that the catalog
-- resolution step can later rewrite into an id.
function Store.normalize_reference(reference)
  local active_providers = providers()
  if active_providers == nil then
    return ""
  end

  if type(reference) == "table" then
    -- v4 stringified an object without an id ("[object Object]"); an empty
    -- reference is the safer reading of a malformed entry.
    local id = reference.id
    if type(id) == "string" and id ~= "" then
      return id
    end
    return ""
  end

  local text = trim(reference)
  if text == "" then
    return ""
  end
  if Store.reference_parts(text) ~= nil then
    return text
  end
  return active_providers.normalize_symbol(text)
end

-- Order-preserving de-duplication; the order is the panel's row order.
function Store.normalize_watch_list(assets)
  local result = {}
  local seen = {}
  if type(assets) ~= "table" then
    return result
  end

  for _, asset in ipairs(assets) do
    local reference = Store.normalize_reference(asset)
    if reference ~= "" and not seen[reference] then
      seen[reference] = true
      table.insert(result, reference)
    end
  end
  return result
end

-- CoinGecko has no market types, so its catalog is always treated as spot.
function Store.effective_market_type(source, market_type)
  if source == "coingecko" then
    return "spot"
  end
  if not includes(Store.VALID_MARKET_TYPES, market_type) then
    return "spot"
  end
  return market_type
end

-- A file-name safe cache key for logos and catalogs.
function Store.sanitize_key(text)
  local key = tostring(text or "asset"):gsub("[^A-Za-z0-9._-]", "_")
  if key == "" then
    return "asset"
  end
  return key
end

-- ── Directories and paths ───────────────────────────────────────────────────

function Store.data_dir()
  local dir, err = noctalia.pluginDataDir()
  if dir == nil or dir == "" then
    log("no plugin data directory: " .. tostring(err))
    return nil
  end
  noctalia.mkdirAll(dir)
  return dir
end

function Store.subdir(name)
  local dir = Store.data_dir()
  if dir == nil then
    return nil
  end
  local path = dir .. "/" .. name
  noctalia.mkdirAll(path)
  return path
end

function Store.runtime_path()
  local dir = Store.data_dir()
  if dir == nil then
    return nil
  end
  return dir .. "/market.json"
end

-- Resolved instrument metadata, so a restart does not re-resolve every symbol and
-- keeps the display names and availability it already learned. The file is tiny
-- (only the instruments actually in use), which matters because a single callback
-- has a CPU budget: lib/store.luau refuses to decode anything oversized instead of
-- blowing it.
Store.MAX_CACHE_BYTES = 65536

function Store.instruments_path()
  local dir = Store.data_dir()
  if dir == nil then
    return nil
  end
  return dir .. "/instruments.json"
end

function Store.load_instruments()
  local path = Store.instruments_path()
  if path == nil then
    return {}
  end

  local raw = noctalia.readFile(path)
  if raw == nil or trim(raw) == "" then
    return {}
  end
  if #raw > Store.MAX_CACHE_BYTES then
    log("instruments.json is " .. tostring(#raw) .. " bytes; ignoring it")
    return {}
  end

  local decoded, err = decode_json(raw)
  if type(decoded) ~= "table" or type(decoded.instruments) ~= "table" then
    log("instruments.json could not be parsed (" .. tostring(err) .. ")")
    return {}
  end

  -- Only keep well-formed rows: this file is the one input that can outlive a
  -- plugin version, so every field is re-validated on the way in.
  local result = {}
  local count = 0
  for id, instrument in pairs(decoded.instruments) do
    if type(instrument) == "table"
      and type(id) == "string"
      and type(instrument.exchange_symbol) == "string"
      and instrument.exchange_symbol ~= ""
      and type(instrument.symbol) == "string"
      and instrument.symbol ~= ""
      and includes(Store.VALID_SOURCES, instrument.provider)
      and includes(Store.VALID_MARKET_TYPES, instrument.market_type)
    then
      result[id] = {
        id = id,
        provider = instrument.provider,
        market_type = instrument.market_type,
        exchange_symbol = instrument.exchange_symbol,
        symbol = instrument.symbol,
        display_symbol = type(instrument.display_symbol) == "string" and instrument.display_symbol
          or string.upper(instrument.symbol),
        name = type(instrument.name) == "string" and instrument.name or "",
        base = type(instrument.base) == "string" and instrument.base or string.upper(instrument.symbol),
        quote = type(instrument.quote) == "string" and instrument.quote or "USDT",
        status = type(instrument.status) == "string" and instrument.status or "constructed",
        logo_url = type(instrument.logo_url) == "string" and instrument.logo_url or "",
      }
      count = count + 1
      if count >= 512 then
        break
      end
    end
  end
  return result
end

function Store.save_instruments(instruments)
  local path = Store.instruments_path()
  if path == nil then
    return false
  end
  local encoded, err = noctalia.json.encode({ version = 1, instruments = instruments }, false)
  if encoded == nil then
    log("instruments.json could not be encoded: " .. tostring(err))
    return false
  end
  noctalia.writeFile(path, encoded)
  return true
end

-- The v4 path is kept on purpose: it is the file users already know, and the
-- README states plainly that exporting writes to it.
function Store.config_path()
  return noctalia.expandPath("~/Downloads/crypto-market-config.json")
end

-- ── Runtime state ───────────────────────────────────────────────────────────

-- Canonical runtime shape. `seed` is an optional first-run list; no caller passes one
-- now that the watch list is edited in the panel rather than declared as a setting, so
-- this normally falls back to DEFAULT_WATCH_LIST. The parameter stays for the tests
-- and for importing a legacy list.
function Store.default_runtime(seed)
  local watch_list = Store.normalize_watch_list(seed)
  if #watch_list == 0 then
    watch_list = Store.normalize_watch_list(Store.DEFAULT_WATCH_LIST)
  end
  local active_alerts = alerts()
  return {
    watch_list = watch_list,
    bar_coin = watch_list[1],
    display_mode = "text",
    price_alerts = active_alerts and active_alerts.normalize_price_alerts({}) or {},
    rapid_alert = active_alerts and active_alerts.normalize_rapid_alert({})
      or { enabled = false, threshold_percent = 5, window_minutes = 5, cooldown_minutes = 30, instrument_ids = {} },
    watch_list_schema_version = Store.SCHEMA_VERSION,
  }
end

-- Legacy camelCase field names, so a v4 export can also be dropped in as
-- market.json. Every unknown or malformed value falls back to the seeded one.
function Store.map_price_alerts(raw)
  local active_alerts = alerts()
  if active_alerts == nil then
    return {}
  end
  if type(raw) ~= "table" then
    return {}
  end

  local mapped = {}
  for id, rule in pairs(raw) do
    if type(rule) == "table" then
      mapped[id] = {
        enabled = rule.enabled,
        upper_price = rule.upper_price ~= nil and rule.upper_price or rule.upperPrice,
        lower_price = rule.lower_price ~= nil and rule.lower_price or rule.lowerPrice,
      }
    end
  end
  return active_alerts.normalize_price_alerts(mapped)
end

function Store.map_rapid_alert(raw)
  local active_alerts = alerts()
  if active_alerts == nil then
    return {}
  end
  if type(raw) ~= "table" then
    return {}
  end

  local function pick(snake, camel)
    if raw[snake] ~= nil then
      return raw[snake]
    end
    return raw[camel]
  end

  return active_alerts.normalize_rapid_alert({
    enabled = raw.enabled,
    threshold_percent = pick("threshold_percent", "thresholdPercent"),
    window_minutes = pick("window_minutes", "windowMinutes"),
    cooldown_minutes = pick("cooldown_minutes", "cooldownMinutes"),
    instrument_ids = pick("instrument_ids", "instrumentIds"),
  })
end

-- Merge a decoded JSON object into the runtime. Accepts the port's snake_case
-- keys and the v4 camelCase ones; `bar_coin` is always forced back into the list,
-- exactly as v4's applyConfig did.
function Store.apply_persisted(runtime, persisted)
  if type(persisted) ~= "table" then
    return runtime
  end

  local next_runtime = {
    watch_list = runtime.watch_list,
    bar_coin = runtime.bar_coin,
    display_mode = runtime.display_mode,
    price_alerts = runtime.price_alerts,
    rapid_alert = runtime.rapid_alert,
    watch_list_schema_version = runtime.watch_list_schema_version,
  }

  local raw_watch_list = persisted.watch_list ~= nil and persisted.watch_list or persisted.watchList
  if type(raw_watch_list) == "table" then
    local watch_list = Store.normalize_watch_list(raw_watch_list)
    if #watch_list > 0 then
      next_runtime.watch_list = watch_list
    end
  end

  local raw_bar_coin = persisted.bar_coin ~= nil and persisted.bar_coin or persisted.barCoin
  if raw_bar_coin ~= nil then
    local reference = Store.normalize_reference(raw_bar_coin)
    if reference ~= "" then
      next_runtime.bar_coin = reference
    end
  end

  local raw_display_mode = persisted.display_mode ~= nil and persisted.display_mode or persisted.displayMode
  if includes(Store.VALID_DISPLAY_MODES, raw_display_mode) then
    next_runtime.display_mode = raw_display_mode
  end

  local raw_price_alerts = persisted.price_alerts ~= nil and persisted.price_alerts or persisted.priceAlerts
  if type(raw_price_alerts) == "table" then
    next_runtime.price_alerts = Store.map_price_alerts(raw_price_alerts)
  end

  local raw_rapid_alert = persisted.rapid_alert ~= nil and persisted.rapid_alert or persisted.rapidAlert
  if type(raw_rapid_alert) == "table" then
    next_runtime.rapid_alert = Store.map_rapid_alert(raw_rapid_alert)
  end

  local raw_schema = persisted.watch_list_schema_version
    ~= nil and persisted.watch_list_schema_version
    or persisted.watchListSchemaVersion
  if type(raw_schema) == "number" then
    next_runtime.watch_list_schema_version = raw_schema
  end

  if not includes(next_runtime.watch_list, next_runtime.bar_coin) then
    next_runtime.bar_coin = next_runtime.watch_list[1]
  end
  return next_runtime
end

function Store.load_runtime(seed)
  local runtime = Store.default_runtime(seed)
  local path = Store.runtime_path()
  if path == nil then
    return runtime
  end

  local raw = noctalia.readFile(path)
  if raw == nil or trim(raw) == "" then
    return runtime
  end

  local decoded, err = decode_json(raw)
  if type(decoded) ~= "table" then
    log("market.json could not be parsed (" .. tostring(err) .. "); using defaults")
    return runtime
  end
  return Store.apply_persisted(runtime, decoded)
end

function Store.save_runtime(runtime)
  local path = Store.runtime_path()
  if path == nil then
    return false
  end
  local encoded, err = noctalia.json.encode(runtime, true)
  if encoded == nil then
    log("market.json could not be encoded: " .. tostring(err))
    return false
  end
  local ok, write_err = noctalia.writeFile(path, encoded)
  if not ok then
    log("market.json could not be written: " .. tostring(write_err))
  end
  return ok
end

-- ── Export / import ─────────────────────────────────────────────────────────

-- The mutable state is exported in this plugin's canonical snake_case shape; the
-- read-only manifest settings are appended as plain values so the file documents
-- the full configuration. They are informational: the plugin cannot write
-- settings, so an import reports them instead of applying them.
function Store.export_config(runtime, static)
  local path = Store.config_path()
  local payload = {
    watch_list = runtime.watch_list,
    bar_coin = runtime.bar_coin,
    display_mode = runtime.display_mode,
    price_alerts = runtime.price_alerts,
    rapid_alert = runtime.rapid_alert,
    watch_list_schema_version = Store.SCHEMA_VERSION,
    data_source = static.source,
    market_type = static.market_type,
    proxy_url = static.proxy_url,
    refresh_interval = static.refresh_interval,
    red_rises = static.red_rises,
  }

  local encoded, err = noctalia.json.encode(payload, true)
  if encoded == nil then
    log("config export could not be encoded: " .. tostring(err))
    return false
  end
  local ok, write_err = noctalia.writeFile(path, encoded)
  if not ok then
    log("config export failed: " .. tostring(write_err))
  end
  return ok
end

-- Parse an imported config file. Returns payload (nil on failure) plus an error
-- tag, or the payload plus a list of read-only keys that could not be applied.
-- Validation mirrors v4's normalizeImportedConfig: unknown values are ignored,
-- and the runtime is never left in an invalid state.
function Store.parse_imported(text)
  if type(text) ~= "string" or trim(text) == "" then
    return nil, "empty"
  end

  local decoded, err = decode_json(text)
  if type(decoded) ~= "table" then
    return nil, "parse:" .. tostring(err)
  end

  local payload = {
    watch_list = nil,
    bar_coin = nil,
    display_mode = nil,
    price_alerts = nil,
    rapid_alert = nil,
    ignored = {},
  }

  local raw_watch_list = decoded.watch_list ~= nil and decoded.watch_list or decoded.watchList
  if type(raw_watch_list) == "table" then
    local watch_list = Store.normalize_watch_list(raw_watch_list)
    if #watch_list > 0 then
      payload.watch_list = watch_list
    end
  end

  local raw_bar_coin = decoded.bar_coin ~= nil and decoded.bar_coin or decoded.barCoin
  if type(raw_bar_coin) == "string" and trim(raw_bar_coin) ~= "" then
    payload.bar_coin = Store.normalize_reference(raw_bar_coin)
  end

  local raw_display_mode = decoded.display_mode ~= nil and decoded.display_mode or decoded.displayMode
  if includes(Store.VALID_DISPLAY_MODES, raw_display_mode) then
    payload.display_mode = raw_display_mode
  end

  local raw_price_alerts = decoded.price_alerts ~= nil and decoded.price_alerts or decoded.priceAlerts
  if type(raw_price_alerts) == "table" then
    payload.price_alerts = Store.map_price_alerts(raw_price_alerts)
  end

  local raw_rapid_alert = decoded.rapid_alert ~= nil and decoded.rapid_alert or decoded.rapidAlert
  if type(raw_rapid_alert) == "table" then
    payload.rapid_alert = Store.map_rapid_alert(raw_rapid_alert)
  end

  -- Read-only values the plugin is not allowed to write. Reported, never applied.
  local read_only = {
    { "data_source", "dataSource" },
    { "market_type", "marketType" },
    { "proxy_url", "proxyUrl" },
    { "refresh_interval", "refreshInterval" },
    { "red_rises", "redRises" },
    -- Dropped in v5: the shell owns both of these now.
    { "language", "language" },
    { "panel_position", "panelPosition" },
  }
  for _, pair in ipairs(read_only) do
    if decoded[pair[1]] ~= nil or decoded[pair[2]] ~= nil then
      table.insert(payload.ignored, pair[1])
    end
  end

  return payload, nil
end

-- Apply a parsed payload on top of the runtime, mirroring v4's
-- normalizeImportedConfig: only present, valid values replace the current ones,
-- and the bar asset is forced back inside the watch list.
function Store.apply_imported(runtime, payload)
  if type(payload) ~= "table" then
    return runtime
  end

  local next_runtime = {
    watch_list = payload.watch_list or runtime.watch_list,
    bar_coin = payload.bar_coin or runtime.bar_coin,
    display_mode = payload.display_mode or runtime.display_mode,
    price_alerts = payload.price_alerts or runtime.price_alerts,
    rapid_alert = payload.rapid_alert or runtime.rapid_alert,
    watch_list_schema_version = Store.SCHEMA_VERSION,
  }

  if #next_runtime.watch_list == 0 then
    next_runtime.watch_list = runtime.watch_list
  end
  if next_runtime.bar_coin == nil or not includes(next_runtime.watch_list, next_runtime.bar_coin) then
    next_runtime.bar_coin = next_runtime.watch_list[1]
  end
  return next_runtime
end

return Store
