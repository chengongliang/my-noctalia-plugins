--!nonstrict
-- Market Watch service - the plugin's only stateful entry.
--
-- v4 kept all of this in Main.qml (an Item every other component reached through
-- `pluginApi.mainInstance`). v5 entries are isolated VMs with no shared memory, so
-- the same responsibilities live here and are published through `noctalia.state`;
-- every other entry is a thin client:
--
--   published (this service owns them):
--     market.config       runtime + read-only configuration for the UI, including the
--                         bar carousel block (enabled, interval, followed ids,
--                         current rotation index and the entry on the bar)
--     market.bar          the resolved bar instrument (id, symbols, availability)
--     market.watch        the watch list resolved in order, for display
--     market.instruments  instrument id -> instrument metadata (only what is used)
--     market.quotes       instrument id -> { open, close, high, low, volume,
--                                          change, is_rising, updated_at }
--     market.status       instrument id -> { status, error_code, error_message,
--                                          updated_at, failure_count, next_retry_at }
--     market.logos        instrument id -> absolute path of a cached logo
--     market.health       { error, error_code } - plugin-wide problems only
--     market.busy         true until the current load settles (v4's isLoading)
--     market.search       { query, results, pending, nonce } - reply to the search op
--     market.config_message { key, detail, error, nonce } - export/import feedback
--
--   command channel (clients write it, this service consumes and clears it):
--     market.cmd = { op = ..., nonce = ... }
--     refresh / refresh_all / force_refresh / add_watch / remove_watch /
--     move_watch / set_bar_coin / toggle_display_mode / set_price_alert /
--     set_rapid_alert / set_carousel / export_config / import_config / search
--
-- The bar carousel (auto-rotating the bar asset) is new capability, not a v4
-- restoration: v4's BarWidget.qml had no wheel handler and Main.qml only ran a
-- refresh Timer and a logo-retry Timer. It reuses this file's update() heartbeat
-- rather than adding a timer, and it never issues a request of its own - advancing
-- the rotation is a table lookup plus one publish.
--
-- ── Execution-budget rules this file obeys ──────────────────────────────────
-- A single v5 callback has a CPU budget, and subprocess stdout is truncated at
-- 1 MiB. Both bit the v4 design, which resolved the watch list against a bulk
-- catalogue (~1.4 MB for Huobi spot):
--   * no bulk catalogue is ever downloaded or decoded;
--   * every HTTP body is size-guarded and decoded only below MAX_DECODE_BYTES;
--   * CommandResult.stdoutTruncated is checked before any parse;
--   * curl gets --max-filesize so an oversized response fails fast;
--   * instruments are built on demand from the bare symbol, verified per symbol
--     where a small endpoint exists (Binance, OKX), and otherwise confirmed by
--     the first quote;
--   * search runs against the small search endpoints, debounced and cached;
--   * publication is split. A landed quote and a carousel advance used to rewrite the
--     whole eleven-key state map, so a twelve-instrument cycle published thirteen times
--     and the allocation churn alone could exhaust the budget. They now mark what changed
--     and update() flushes each group (logos, bar, quotes) at most once per heartbeat;
--   * work a callback abort could strand is reset inside a pcall. The shell enforces the
--     budget by raising a Lua error, which skips every later line of the aborted
--     callback - that is how a stuck `pumping` flag or a leaked in-flight slot used to
--     stop all refreshing until the entry was reloaded.
--
-- This file (and lib/store.luau) deliberately stays Lua 5.4-parseable - no `+=`,
-- no string interpolation - so an offline mock host can execute the real service
-- end to end against the tests/fixtures payloads. lib/alerts.luau and
-- lib/providers.luau hold to the same rule for the `lua5.4 tests/*` harnesses.
--
-- Read-only manifest settings (data_source, market_type, proxy_url, refresh_interval,
-- red_rises) are the static configuration: a plugin cannot write settings, so
-- everything the user can change at runtime - the watch list, the bar coin, the alert
-- rules - lives in pluginDataDir()/market.json, which lib/store.luau owns.

local providers = require("./lib/providers.luau")
local alerts = require("./lib/alerts.luau")
local store = require("./lib/store.luau")

store.configure(providers, alerts)

local PLUGIN_ID = "chengongliang/market-watch"
local PANEL_WATCH = PLUGIN_ID .. ":watch"

-- One heartbeat tick drives four things: the refresh cycle, the quote queue, the
-- debounced search and the logo retry sweep. The *cycle* keeps the user's
-- refresh_interval (floored for CoinGecko), but the queue must keep draining
-- between cycles - with 4 workers and more than 4 watched instruments, tying the
-- pump to the cycle would leave the remaining quotes waiting a whole interval,
-- which v4 never did.
local BASE_TICK_MS = 500
local MAX_CONCURRENT_QUOTES = 4
local RETRY_CAP_MS = 300000
-- Twice curl's --max-time plus the runAsync timeout, so only a genuinely lost callback is
-- treated as a stale slot.
local IN_FLIGHT_TIMEOUT_MS = 60000
local LOGO_RETRY_COOLDOWN_MS = 60000
local MAX_SEARCH_RESULTS = 10
-- Budget guards. 100 KiB of JSON is the practical ceiling for one decode.
local MAX_DECODE_BYTES = 102400
local QUOTE_MAX_BYTES = 65536
local API_MAX_BYTES = 262144
local SEARCH_DEBOUNCE_MS = 350
local SEARCH_CACHE_TTL_MS = 600000
local SEARCH_CACHE_MAX = 64

-- ── Forward declarations ────────────────────────────────────────────────────
-- These call each other (refresh -> queue -> logo -> search -> resolution), so
-- each is declared as a local here and assigned further down. Without this, a
-- later `local function` would be invisible to an earlier body.

local refresh_market_data
local pump_queue
local request_logo
local search_external_logo
local search_trading_view_logo
local download_trading_view_logo
local verify_instrument
local run_search
local resolve_coingecko
local set_quote_failure
local bar_info
local watch_rows
local carousel_enabled
local carousel_interval_seconds
local carousel_entries
local carousel_position_of
local bar_reference

-- ── Static configuration (read-only manifest settings) ──────────────────────

local function read_static()
  local source = noctalia.getConfig("data_source")
  if not store.includes(store.VALID_SOURCES, source) then
    source = "huobi"
  end

  local market_type = noctalia.getConfig("market_type")
  if not store.includes(store.VALID_MARKET_TYPES, market_type) then
    market_type = "spot"
  end
  market_type = store.effective_market_type(source, market_type)

  local proxy_url = noctalia.getConfig("proxy_url")
  if type(proxy_url) ~= "string" then
    proxy_url = ""
  end
  proxy_url = store.trim(proxy_url)

  -- v4 clamped the interval to 1..60 in three places; the manifest's min/max do
  -- that for the host settings GUI, and this covers a stale config value too.
  local refresh_interval = alerts.to_number(noctalia.getConfig("refresh_interval")) or 5
  refresh_interval = math.floor(math.max(1, math.min(60, refresh_interval)) + 0.5)

  local red_rises = noctalia.getConfig("red_rises") == true

  -- The watch list is not configuration: it is runtime state the user edits in the
  -- settings panel, persisted in market.json. The store seeds the built-in default list
  -- when no saved state exists yet.

  return {
    source = source,
    market_type = market_type,
    proxy_url = proxy_url,
    refresh_interval = refresh_interval,
    red_rises = red_rises,
  }
end

local static = read_static()

-- ── Runtime state ───────────────────────────────────────────────────────────

local runtime = nil -- loaded from pluginDataDir()/market.json during startup

-- Only the instruments actually in use (watch list, bar asset, search picks).
local instruments = {}
local instruments_dirty = false
local health = { error = "", error_code = "" }

local quotes = {}
local status = {}
local queue = {}
local queued = {}
local in_flight = {} -- instrument id -> generation of the request in flight
local in_flight_at = {} -- instrument id -> nowMs() when that request started
local pumping = false
local generation = 0

-- Alert state is deliberately in memory only: a reload re-arms the rules instead
-- of firing a burst of notifications for crossings that predate the restart.
local price_alert_states = {}
local rapid_history = {}
local rapid_states = {}

local logos = {}
local logo_failures = {}
local logo_in_flight = {}
local tv_logo_ids = {}
local logo_dir_cache = nil

local busy = true
local cycle_armed = false
local next_cycle_at = 0
local last_logo_sweep_at = 0
-- 0 means "not armed yet": the next tick arms the interval without advancing, so
-- enabling the carousel (or reloading with it on) does not jump immediately.
local next_carousel_at = 0
local search_payload = { query = "", results = {}, pending = false, nonce = 0 }
local config_message = nil

local search_cache = {}
local pending_search = nil
local search_in_flight = false

local pending_resolutions = {}
local resolution_in_flight = false
local resolving_reference = nil

-- ── Publish helpers ─────────────────────────────────────────────────────────

local function copy_map(source)
  local out = {}
  for key, value in pairs(source) do
    out[key] = value
  end
  return out
end

local function copy_list(source)
  local out = {}
  for index, value in ipairs(source) do
    out[index] = value
  end
  return out
end

local function copy_price_alerts()
  local out = {}
  for id, rule in pairs(runtime.price_alerts) do
    out[id] = {
      enabled = rule.enabled,
      upper_price = rule.upper_price,
      lower_price = rule.lower_price,
    }
  end
  return out
end

local function public_config()
  local rapid = runtime.rapid_alert
  return {
    source = static.source,
    market_type = static.market_type,
    proxy_url = static.proxy_url,
    refresh_interval = static.refresh_interval,
    red_rises = static.red_rises,
    watch_list = copy_list(runtime.watch_list),
    bar_coin = runtime.bar_coin,
    display_mode = runtime.display_mode,
    -- `ids` is the *effective* followed set (watch-list order), never empty while the
    -- watch list has entries: market.json may store an empty list as the shorthand for
    -- "rotate everything", but the panel's follow toggles need the resolved set.
    carousel = {
      enabled = carousel_enabled(),
      interval = carousel_interval_seconds(),
      ids = copy_list(carousel_entries()),
      index = carousel_position_of(carousel_entries(), bar_reference()) or 0,
      entry = bar_reference() or "",
    },
    price_alerts = copy_price_alerts(),
    rapid_alert = {
      enabled = rapid.enabled,
      threshold_percent = rapid.threshold_percent,
      window_minutes = rapid.window_minutes,
      cooldown_minutes = rapid.cooldown_minutes,
      instrument_ids = copy_list(rapid.instrument_ids),
    },
  }
end

-- Publication is split three ways. `publish()` writes the whole picture and is what the
-- command paths use; the two hot paths - a quote landing, a carousel advance - only mark
-- the group they touched and update() flushes it. Every state.set deep-copies and
-- serialises its map, so republishing everything once per landed quote was the most
-- expensive thing this file did, and its allocation churn fed the GC on the same thread
-- the CPU budget is measured on.
local pending_quotes = false
local pending_bar = false
local pending_logos = false

local function publish_bar()
  noctalia.state.set("market.config", public_config())
  noctalia.state.set("market.bar", bar_info())
end

local function publish_quotes()
  noctalia.state.set("market.quotes", copy_map(quotes))
  noctalia.state.set("market.status", copy_map(status))
  noctalia.state.set("market.busy", busy)
end

local function publish_logos()
  noctalia.state.set("market.logos", copy_map(logos))
end

local function publish()
  publish_bar()
  noctalia.state.set("market.watch", watch_rows())
  noctalia.state.set("market.instruments", copy_map(instruments))
  publish_quotes()
  publish_logos()
  noctalia.state.set("market.health", { error = health.error, error_code = health.error_code })
  noctalia.state.set("market.search", search_payload)
  if config_message ~= nil then
    noctalia.state.set("market.config_message", config_message)
  end
  -- Cleared only once every key was written: a publish aborted halfway would otherwise
  -- drop the group it had not reached yet until the next unrelated full publish.
  pending_bar = false
  pending_quotes = false
  pending_logos = false
end

local function persist()
  runtime.watch_list_schema_version = store.SCHEMA_VERSION
  store.save_runtime(runtime)
end

-- ── Instruments ─────────────────────────────────────────────────────────────

local function register_instrument(instrument)
  if instrument == nil or instrument.id == nil then
    return instrument
  end
  instruments[instrument.id] = instrument
  instruments_dirty = true
  return instrument
end

local function queue_resolution(reference)
  if reference == nil or reference == "" or reference == resolving_reference then
    return
  end
  pending_resolutions[reference] = true
end

-- v4's getInstrument, minus the catalogue: an exact id or a qualified reference is
-- built immediately, a bare symbol is built for the current provider, and
-- CoinGecko - whose ids cannot be derived from a symbol - is resolved through its
-- search endpoint on a later tick.
local function instrument_for(reference)
  if type(reference) == "table" and reference.id ~= nil then
    return reference
  end

  local text = store.trim(reference)
  if text == "" then
    return nil
  end
  local cached = instruments[text]
  if cached ~= nil then
    return cached
  end

  local parsed = store.reference_parts(text)
  if parsed ~= nil then
    -- A qualified reference carries its own provider and market type; the base
    -- asset is recovered from the exchange symbol.
    local base = providers.base_from_exchange_symbol(parsed.exchange_symbol)
    return register_instrument(providers.create_instrument(
      parsed.provider,
      parsed.market_type,
      parsed.exchange_symbol,
      base,
      "",
      base,
      providers.quote_currency(parsed.provider),
      "constructed",
      ""
    ))
  end

  local base = providers.normalize_symbol(text)
  if base == "" then
    return nil
  end

  if static.source == "coingecko" then
    -- "btc" is not a coin id: the /search endpoint has to answer this one.
    queue_resolution(text)
    return nil
  end

  return register_instrument(providers.construct_instrument(static.source, static.market_type, base, ""))
end

local function mark_unavailable(instrument)
  if instrument == nil then
    return
  end
  instrument.status = "unresolved"
  register_instrument(instrument)
  set_quote_failure(instrument, "unavailable", noctalia.tr("settings.unavailable"))
end

-- ── Bar carousel ────────────────────────────────────────────────────────────
-- The bar shows one asset at a time; when the carousel is on it rotates through the
-- followed subset of the watch list on the user's interval. `bar_coin` is never
-- touched by the rotation - it stays the explicit choice the user made, and it is
-- what the bar shows again the moment the carousel is switched off.

carousel_enabled = function()
  return runtime.carousel_enabled == true
end

carousel_interval_seconds = function()
  return store.normalize_carousel_interval(runtime.carousel_interval)
end

-- The rotation is the followed subset intersected with the watch list, in watch-list
-- order. Entries that were removed from the watch list therefore drop out on their
-- own; an empty subset (or one whose assets all left) means "rotate everything".
carousel_entries = function()
  local list = runtime.watch_list
  local followed = {}
  local ids = runtime.carousel_ids
  if type(ids) ~= "table" or #ids == 0 then
    for _, reference in ipairs(list) do
      table.insert(followed, reference)
    end
    return followed
  end

  local wanted = {}
  for _, id in ipairs(ids) do
    wanted[id] = true
  end
  for _, reference in ipairs(list) do
    if wanted[reference] then
      table.insert(followed, reference)
    end
  end
  if #followed == 0 then
    for _, reference in ipairs(list) do
      table.insert(followed, reference)
    end
  end
  return followed
end

carousel_position_of = function(entries, reference)
  for index, entry in ipairs(entries) do
    if entry == reference then
      return index
    end
  end
  return nil
end

-- "Unresolved" is this plugin's only unavailable state: a constructed or quoted
-- instrument is usable, and one still being resolved (CoinGecko) already has a symbol
-- to show, so it counts as usable too.
local function carousel_is_usable(reference)
  local instrument = instrument_for(reference)
  if instrument == nil then
    return pending_resolutions[reference] == true
  end
  return instrument.status ~= "unresolved"
end

-- Follows the rotation from the stored cursor, skipping entries the provider does not
-- list. With the carousel on the bar must not sit on "--" while another followed asset
-- has data, so the skip happens on every read rather than only on an advance.
local function carousel_active_reference()
  local entries = carousel_entries()
  local count = #entries
  if count == 0 then
    return nil
  end

  local start = math.floor(alerts.to_number(runtime.carousel_index) or 1)
  if start < 1 or start > count then
    start = ((start - 1) % count) + 1
  end

  for offset = 0, count - 1 do
    local index = ((start - 1 + offset) % count) + 1
    local reference = entries[index]
    if carousel_is_usable(reference) then
      -- Remember where the skip landed so a manual step moves from what is on screen.
      -- Deliberately not persisted: this runs on every publish, and a restart resumes
      -- on the same asset anyway (the unusable one is skipped again).
      runtime.carousel_index = index
      return reference
    end
  end
  return entries[start]
end

-- One notch of rotation, skipping unusable entries: the caller can rely on the cursor
-- landing on something with data whenever anything followed has it.
local function carousel_step(delta)
  local entries = carousel_entries()
  local count = #entries
  local step = delta > 0 and 1 or -1
  if count == 0 or delta == 0 then
    return false
  end

  -- Start from what is on the bar: the skip in carousel_active_reference may already
  -- have moved the cursor past an unavailable asset.
  carousel_active_reference()
  local start = math.floor(alerts.to_number(runtime.carousel_index) or 1)
  if start < 1 or start > count then
    start = ((start - 1) % count) + 1
  end

  for offset = 1, count do
    local index = ((start - 1 + step * offset) % count + count) % count + 1
    -- A full lap with nothing usable is better spent on the next entry than on no move.
    if offset == count or carousel_is_usable(entries[index]) then
      runtime.carousel_index = index
      return true
    end
  end
  return false
end

local function carousel_advance()
  return carousel_step(1)
end

local function carousel_reset_timer()
  next_carousel_at = 0
end

local function carousel_clamp_index()
  local count = #carousel_entries()
  local index = math.floor(alerts.to_number(runtime.carousel_index) or 1)
  if count == 0 then
    runtime.carousel_index = 1
    return
  end
  if index < 1 or index > count then
    runtime.carousel_index = ((index - 1) % count) + 1
  end
end

-- The asset the bar should name right now: the rotation entry when the carousel is on,
-- the user's explicit pick otherwise.
bar_reference = function()
  if carousel_enabled() then
    local current = carousel_active_reference()
    if current ~= nil then
      return current
    end
  end
  return runtime.bar_coin
end

bar_info = function()
  -- The shape must not change: widget.luau renders exactly these keys.
  local reference = bar_reference() or runtime.bar_coin
  local instrument = instrument_for(reference)
  if instrument == nil then
    return {
      id = reference,
      symbol = string.upper(store.trim(reference)),
      pending = pending_resolutions[reference] == true,
    }
  end
  return {
    id = instrument.id,
    symbol = instrument.display_symbol,
    name = instrument.name,
    available = instrument.status ~= "unresolved",
  }
end

-- The watch list resolved for display, in order. Publishing it keeps the two
-- panels and the widget from each re-implementing instrument resolution and
-- guarantees they agree on how a stored reference maps to an instrument.
watch_rows = function()
  local rows = {}
  for index, reference in ipairs(runtime.watch_list) do
    local instrument = instrument_for(reference)
    if instrument == nil then
      rows[index] = {
        id = reference,
        symbol = string.upper(store.trim(reference)),
        name = "",
        -- Still being resolved (CoinGecko): not unavailable, just not ready.
        available = pending_resolutions[reference] == true,
        pending = pending_resolutions[reference] == true,
      }
    else
      rows[index] = {
        id = instrument.id,
        symbol = instrument.display_symbol,
        name = instrument.name,
        available = instrument.status ~= "unresolved",
      }
    end
  end
  return rows
end

-- ── HTTP ────────────────────────────────────────────────────────────────────

-- curl argv with the proxy injected when configured. The plugin keeps curl for
-- every network call precisely so a proxied setup works: noctalia.http has no
-- proxy field, and dropping `-x` would be a v4 regression. No `-f` here: provider
-- error bodies are how a bad symbol is recognised, so the body must survive a 4xx.
local function api_argv(url, max_bytes, with_origin)
  local argv = {
    "curl",
    "-sSL",
    "--connect-timeout",
    "10",
    "--max-time",
    "30",
    "--max-filesize",
    tostring(max_bytes or API_MAX_BYTES),
  }
  if with_origin then
    table.insert(argv, "-H")
    table.insert(argv, "Origin: https://www.tradingview.com")
  end
  if static.proxy_url ~= "" then
    table.insert(argv, "-x")
    table.insert(argv, static.proxy_url)
  end
  table.insert(argv, url)
  return argv
end

-- callback(ok, body, reason). Reasons: not-started, truncated, too-large, empty,
-- exit-N. A truncated or oversized body is never parsed: the capture limit is
-- 1 MiB and one decode may not exceed MAX_DECODE_BYTES.
local function api_get(url, max_bytes, callback, with_origin)
  if url == "" then
    callback(false, "", "no-url")
    return
  end

  local settled = false
  local function finish(ok, body, reason)
    if settled then
      return
    end
    settled = true
    callback(ok, body, reason)
  end

  local started = noctalia.runAsync(api_argv(url, max_bytes, with_origin), function(result)
    if result == nil then
      finish(false, "", "not-started")
      return
    end
    if result.stdoutTruncated == true then
      finish(false, "", "truncated")
      return
    end
    local body = result.stdout or ""
    if #body > (max_bytes or API_MAX_BYTES) then
      finish(false, "", "too-large")
      return
    end
    if result.exitCode ~= 0 then
      finish(false, body, "exit-" .. tostring(result.exitCode))
      return
    end
    if body == "" then
      finish(false, "", "empty")
      return
    end
    finish(true, body, "")
  end, 35000)

  if not started then
    finish(false, "", "not-started")
  end
end

-- A single guarded decode: size-capped, and never able to raise. A malformed
-- provider body has to degrade to a failed quote, not abort the callback.
local function decode_body(body)
  if type(body) ~= "string" or body == "" or #body > MAX_DECODE_BYTES then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function download_to(dest, url, callback)
  if dest == nil or url == "" then
    callback(false)
    return
  end

  if static.proxy_url ~= "" then
    -- noctalia.download has no proxy field, so a proxied setup keeps using curl.
    -- Downloads keep -f: an error page must never be saved as an image.
    local argv = { "curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", "-o", dest }
    if static.proxy_url ~= "" then
      table.insert(argv, "-x")
      table.insert(argv, static.proxy_url)
    end
    table.insert(argv, url)
    local started = noctalia.runAsync(argv, function(result)
      callback(result ~= nil and result.exitCode == 0)
    end, 35000)
    if not started then
      callback(false)
    end
    return
  end

  local started = noctalia.download(url, dest, function(ok)
    callback(ok == true)
  end)
  if not started then
    callback(false)
  end
end

-- ── Availability ────────────────────────────────────────────────────────────

-- Binance and OKX expose a per-symbol instrument endpoint that is small enough to
-- decode; Huobi has none (its catalogue is the payload behind this redesign) and
-- CoinGecko uses /search, so for both of those the first quote decides.
verify_instrument = function(instrument, callback)
  local url = providers.verification_url(instrument.provider, instrument.market_type, instrument.exchange_symbol)
  if url == "" then
    callback(true, "no-endpoint")
    return
  end

  api_get(url, API_MAX_BYTES, function(ok, body, reason)
    if not ok then
      -- A transport problem is not a verdict: let the quote decide.
      noctalia.log("market-watch: verification skipped for " .. instrument.id .. ": " .. tostring(reason))
      callback(true, "unverified")
      return
    end
    local decoded = decode_body(body)
    if decoded == nil then
      callback(true, "unreadable")
      return
    end
    local listed = providers.parse_verification(instrument.provider, instrument.market_type, decoded)
    callback(#listed > 0, "checked")
  end)
end

-- ── Quotes ──────────────────────────────────────────────────────────────────

local function valid_quote(parsed)
  if parsed == nil then
    return false
  end
  for _, field in ipairs({ "open", "close", "high", "low", "volume" }) do
    local value = parsed[field]
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
      return false
    end
  end
  return parsed.open > 0 and parsed.close > 0
end

local function set_quote_loading(instrument)
  local previous = status[instrument.id] or {}
  status[instrument.id] = {
    status = previous.status == "ready" and "ready" or "loading",
    updated_at = previous.updated_at or 0,
    failure_count = previous.failure_count or 0,
    next_retry_at = previous.next_retry_at or 0,
    error_code = "",
    error_message = "",
  }
end

local function evaluate_price_alert_for_quote(instrument, quote)
  local rule = runtime.price_alerts[instrument.id]
  if rule == nil then
    return
  end

  local checked = alerts.evaluate_price_alert(rule, quote.close, price_alert_states[instrument.id])
  price_alert_states[instrument.id] = checked.state

  for _, trigger in ipairs(checked.triggers) do
    local key = trigger.direction == "upper" and "notifications.price_upper" or "notifications.price_lower"
    local body = noctalia.tr(key, {
      symbol = instrument.display_symbol ~= "" and instrument.display_symbol or instrument.exchange_symbol,
      threshold = providers.format_price(trigger.threshold),
      price = providers.format_price(quote.close),
    })
    -- v4 passed a toast icon (arrow-up / arrow-down); v5's notify() takes a title
    -- and a body only, so the direction survives in the message text.
    noctalia.notify(noctalia.tr("notifications.price_alert_title"), body)
    noctalia.log(
      "market-watch: price alert " .. instrument.id .. " " .. trigger.direction .. " at " .. tostring(quote.close)
    )
  end
end

local function evaluate_rapid_alert_for_quote(instrument, quote)
  local rule = alerts.normalize_rapid_alert(runtime.rapid_alert)
  if not alerts.is_rapid_alert_selected(rule, instrument.id) then
    return
  end

  local now = quote.updated_at
  local history = rapid_history[instrument.id]
  if type(history) ~= "table" then
    history = {}
  end

  local appended = {}
  for index, sample in ipairs(history) do
    appended[index] = sample
  end
  table.insert(appended, { at = now, price = quote.close })

  local trimmed = alerts.trim_samples(appended, now, rule.window_minutes)
  rapid_history[instrument.id] = trimmed

  local checked = alerts.evaluate_rapid_move(trimmed, rule, rapid_states[instrument.id], now)
  rapid_states[instrument.id] = checked.state

  if checked.trigger ~= nil then
    local key = checked.trigger.direction == "rise" and "notifications.rapid_rise" or "notifications.rapid_fall"
    local body = noctalia.tr(key, {
      symbol = instrument.display_symbol ~= "" and instrument.display_symbol or instrument.exchange_symbol,
      change = string.format("%.2f%%", math.abs(checked.trigger.change_percent)),
      window = rule.window_minutes,
    })
    noctalia.notify(noctalia.tr("notifications.rapid_alert_title"), body)
    noctalia.log(
      "market-watch: rapid alert "
        .. instrument.id
        .. " "
        .. checked.trigger.direction
        .. " "
        .. string.format("%.2f%%", checked.trigger.change_percent)
    )
  end
end

local function set_quote_success(instrument, parsed)
  local change = (parsed.close - parsed.open) / parsed.open * 100
  local now = noctalia.nowMs()
  local quote = {
    open = parsed.open,
    close = parsed.close,
    high = parsed.high,
    low = parsed.low,
    volume = parsed.volume,
    change = change,
    -- Equality counts as rising, exactly as in v4.
    is_rising = parsed.close >= parsed.open,
    updated_at = now,
  }

  quotes[instrument.id] = quote
  status[instrument.id] = {
    status = "ready",
    updated_at = now,
    failure_count = 0,
    next_retry_at = 0,
    error_code = "",
    error_message = "",
  }

  -- The quote is the proof that the constructed symbol exists, so the cached
  -- metadata is upgraded from "constructed" to "online".
  if instrument.status ~= "online" then
    instrument.status = "online"
    register_instrument(instrument)
  end

  evaluate_price_alert_for_quote(instrument, quote)
  evaluate_rapid_alert_for_quote(instrument, quote)

  -- Logos are resolved lazily, like v4's panel did: the first quote for an
  -- instrument is a good moment to ask for its icon.
  request_logo(instrument.id)
end

set_quote_failure = function(instrument, code, message)
  local previous = status[instrument.id] or {}
  local failure_count = (alerts.to_number(previous.failure_count) or 0) + 1
  local has_quote = quotes[instrument.id] ~= nil
  -- Exponential backoff, capped at 5 minutes; an existing value stays on screen
  -- (status "stale") rather than being replaced by an error, so a single failed
  -- poll is invisible.
  local delay = math.min(RETRY_CAP_MS, 1000 * (2 ^ math.min(failure_count, 8)))

  status[instrument.id] = {
    status = has_quote and "stale" or "error",
    updated_at = previous.updated_at or 0,
    failure_count = failure_count,
    next_retry_at = noctalia.nowMs() + delay,
    error_code = code,
    error_message = message,
  }
  busy = false
  noctalia.log("market-watch: quote failed " .. instrument.id .. " " .. code .. ": " .. tostring(message))
end

local function start_quote_request(instrument, job_generation)
  local url = providers.quote_url(static.source, instrument.market_type, instrument)
  if url == "" then
    set_quote_failure(instrument, "unsupported", "provider cannot build a quote request")
    return
  end

  in_flight[instrument.id] = job_generation
  in_flight_at[instrument.id] = noctalia.nowMs()
  set_quote_loading(instrument)

  local done = false
  local function finish(ok, body, reason)
    if done then
      return
    end
    done = true

    if job_generation == generation then
      -- The shell enforces its per-callback CPU budget by raising a Lua error, and this
      -- body does the most work of anything in the file (a JSON decode plus the state it
      -- keeps). Inside a pcall because an abort here would otherwise skip the slot release
      -- below - an entry that is never released starves that instrument for good.
      local handled, failure = pcall(function()
        if not ok then
          -- Oversized or truncated bodies are never parsed; the message says so.
          local message = store.trim(reason)
          if reason == "too-large" or reason == "truncated" then
            message = noctalia.tr("panel.response_too_large")
          end
          set_quote_failure(instrument, "network-error", message)
        else
          local decoded = decode_body(body)
          if decoded == nil then
            set_quote_failure(instrument, "parse-error", noctalia.tr("panel.bad_response"))
          elseif providers.parse_error(static.source, decoded) then
            -- An explicit provider error means this symbol is not tradable here:
            -- stop retrying it and label the row, exactly like v4's unresolved path.
            noctalia.log("market-watch: " .. instrument.id .. " is not available from " .. static.source)
            mark_unavailable(instrument)
          else
            local parsed = providers.parse_quote(static.source, decoded, instrument)
            if valid_quote(parsed) then
              set_quote_success(instrument, parsed)
            else
              set_quote_failure(instrument, "invalid-response", noctalia.tr("panel.bad_response"))
            end
          end
        end
      end)
      if not handled then
        -- Deliberately not recorded as a quote failure: the request did arrive, the
        -- callback just ran out of budget. The next cycle asks again.
        noctalia.log("market-watch: quote handling interrupted for " .. instrument.id .. ": " .. tostring(failure))
      end
    end

    if in_flight[instrument.id] == job_generation then
      in_flight[instrument.id] = nil
      in_flight_at[instrument.id] = nil
    end
    busy = false
    -- Flushed by update(), at most once per tick: a cycle lands twelve of these.
    pending_quotes = true
    pump_queue()
  end

  -- A budget interrupt is a Lua error. If it lands between taking the slot above and
  -- runAsync actually starting the process, the slot would stay taken with no request
  -- behind it (the job has already left the queue). Released here so the next cycle
  -- retries at once instead of waiting out IN_FLIGHT_TIMEOUT_MS.
  local started, start_failure = pcall(api_get, url, QUOTE_MAX_BYTES, finish)
  if not started then
    if in_flight[instrument.id] == job_generation then
      in_flight[instrument.id] = nil
      in_flight_at[instrument.id] = nil
    end
    noctalia.log("market-watch: request interrupted for " .. instrument.id .. ": " .. tostring(start_failure))
  end
end

-- Bounded worker pool: at most MAX_CONCURRENT_QUOTES curls at a time, so a long
-- watch list cannot spawn a process per instrument. The `pumping` guard keeps a
-- synchronous completion from re-entering the loop.
--
-- Occupied slots are derived from `in_flight` instead of being counted: a counter used to
-- drift whenever a callback was aborted halfway (one direction only), and a counter stuck
-- at the limit blocks every later pump just as effectively as a stuck guard flag.
local function active_requests()
  local count = 0
  for _ in pairs(in_flight) do
    count = count + 1
  end
  return count
end

pump_queue = function()
  if pumping then
    return
  end
  pumping = true

  -- A budget interrupt is a plain Lua error, so it unwinds through here. Held in a pcall
  -- purely to reset `pumping`: left set, every later pump becomes a no-op and the plugin
  -- stops refreshing silently until the entry is reloaded, with nothing in the log but
  -- stale prices.
  local ok, failure = pcall(function()
    while active_requests() < MAX_CONCURRENT_QUOTES and #queue > 0 do
      local job = table.remove(queue, 1)
      if queued[job.id] == job.generation then
        queued[job.id] = nil
      end
      if job.generation == generation then
        local instrument = instruments[job.id] or instrument_for(job.id)
        if instrument ~= nil and instrument.status ~= "unresolved" then
          start_quote_request(instrument, job.generation)
        end
      end
    end
  end)
  pumping = false
  if not ok then
    -- Whatever is left in the queue is picked up by the next tick.
    noctalia.log("market-watch: pump interrupted: " .. tostring(failure))
  end
end

local function fetch_quote(reference, force)
  if health.error_code ~= "" then
    return
  end

  local instrument = instrument_for(reference)
  if instrument == nil then
    -- A CoinGecko bare symbol: resolution is queued, the tick will retry it.
    return
  end
  local id = instrument.id

  if instrument.status == "unresolved" then
    if force ~= true then
      local unresolved = status[id]
      if unresolved == nil or unresolved.error_code ~= "unavailable" then
        set_quote_failure(instrument, "unavailable", noctalia.tr("settings.unavailable"))
      end
      return
    end
    -- An explicit user refresh re-tests an unavailable instrument once.
    instrument.status = "constructed"
    register_instrument(instrument)
  end

  local state = status[id]
  if not force and state ~= nil and (state.next_retry_at or 0) > 0 and noctalia.nowMs() < state.next_retry_at then
    return
  end
  if queued[id] == generation then
    return
  end
  if in_flight[id] == generation then
    -- A callback can be lost: the shell aborts one that blows its CPU budget, and a curl
    -- that is killed never reports back. The slot is treated as gone after the timeout so
    -- a lost answer cannot pin the instrument out of every later cycle (a manual refresh
    -- included, since it shares this guard).
    local started_at = in_flight_at[id] or 0
    if noctalia.nowMs() - started_at < IN_FLIGHT_TIMEOUT_MS then
      return
    end
    noctalia.log("market-watch: dropping the stale request for " .. id)
    in_flight[id] = nil
    in_flight_at[id] = nil
  end

  table.insert(queue, { id = id, generation = generation })
  queued[id] = generation
  pump_queue()
end

refresh_market_data = function(force)
  if #runtime.watch_list == 0 then
    busy = false
  end
  for _, reference in ipairs(runtime.watch_list) do
    fetch_quote(reference, force == true)
  end
  -- Flushed by update(): a cycle runs inside the heartbeat, and a full publish here was
  -- one of the two calls that most often blew the per-callback budget.
  pending_quotes = true
end

-- ── Logos ───────────────────────────────────────────────────────────────────

local function load_tv_logo_ids()
  local dir = store.data_dir()
  if dir == nil then
    return
  end
  local raw = noctalia.readFile(dir .. "/tradingview-logoids.json")
  if raw == nil or store.trim(raw) == "" or #raw > store.MAX_CACHE_BYTES then
    return
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return
  end
  for id, logoid in pairs(decoded) do
    if type(logoid) == "string" and logoid ~= "" then
      tv_logo_ids[id] = logoid
    end
  end
end

local function save_tv_logo_ids()
  local dir = store.data_dir()
  if dir == nil then
    return
  end
  local encoded = noctalia.json.encode(tv_logo_ids, true)
  if encoded ~= nil then
    noctalia.writeFile(dir .. "/tradingview-logoids.json", encoded)
  end
end

local function logo_dir()
  if logo_dir_cache == nil then
    logo_dir_cache = store.subdir("logos")
  end
  return logo_dir_cache
end

local function logo_path(id, extension)
  local dir = logo_dir()
  if dir == nil then
    return nil
  end
  return dir .. "/" .. store.sanitize_key(id) .. "." .. extension
end

-- v4 sniffed the cached file's MIME type with `file`; the manifest declares only
-- curl, so existence plus a non-zero size is the whole check here. A truncated
-- image is the one case this misses, and it degrades to the text badge anyway.
local function cached_file(path)
  if path == nil or not noctalia.fileExists(path) then
    return false
  end
  local info = noctalia.fileInfo(path)
  return info ~= nil and (info.size or 0) > 0
end

download_trading_view_logo = function(instrument, logoid, callback)
  local url = providers.trading_view_logo_url(logoid)
  if url == "" then
    callback(false)
    return
  end

  local dest = logo_path(instrument.id, "svg")
  download_to(dest, url, function(ok)
    if not ok or not cached_file(dest) then
      callback(false)
      return
    end

    -- ui.image is documented for local files; whether it decodes SVG depends on
    -- the shell's image plugins. When a converter happens to be installed the
    -- logo is rasterised, which always renders; otherwise the SVG path is
    -- published and the panel's text badge stays the fallback.
    if noctalia.commandExists("rsvg-convert") then
      local png = logo_path(instrument.id, "png")
      local started = noctalia.runAsync(
        { "rsvg-convert", "-w", "48", "-h", "48", "-o", png, dest },
        function(result)
          if result ~= nil and result.exitCode == 0 and cached_file(png) then
            callback(true, "png")
          else
            callback(true, "svg")
          end
        end,
        10000
      )
      if not started then
        callback(true, "svg")
      end
      return
    end

    callback(true, "svg")
  end)
end

search_trading_view_logo = function(instrument, callback)
  local query = instrument.base ~= "" and instrument.base or instrument.symbol
  local url = providers.trading_view_search_url(query)
  if url == "" then
    callback(false)
    return
  end

  api_get(url, API_MAX_BYTES, function(ok, body)
    if not ok then
      callback(false)
      return
    end
    local decoded = decode_body(body)
    local logoid = providers.parse_trading_view_logo_id(decoded, instrument)
    if logoid == "" then
      callback(false)
      return
    end
    -- The logoid is durable: the search endpoint is queried at most once per
    -- instrument, across sessions.
    tv_logo_ids[instrument.id] = logoid
    save_tv_logo_ids()
    download_trading_view_logo(instrument, logoid, callback)
  end, true)
end

search_external_logo = function(instrument, callback)
  local query = instrument.exchange_symbol
  if query == "" then
    query = instrument.symbol ~= "" and instrument.symbol or instrument.name
  end
  local url = providers.coingecko_search_url(query)

  api_get(url, API_MAX_BYTES, function(ok, body)
    if not ok then
      search_trading_view_logo(instrument, callback)
      return
    end
    local decoded = decode_body(body)
    local candidates = decoded ~= nil and providers.parse_coingecko_candidates(decoded) or {}

    -- CoinGecko search is fuzzy: only an exact coin id, or a single result whose
    -- symbol matches, is trustworthy enough to become the icon.
    local wanted_id = string.lower(instrument.exchange_symbol or "")
    local found = nil
    for _, candidate in ipairs(candidates) do
      if string.lower(candidate.exchange_symbol) == wanted_id then
        found = candidate
        break
      end
    end
    if found == nil then
      local matches = {}
      for _, candidate in ipairs(candidates) do
        if candidate.symbol == instrument.symbol then
          table.insert(matches, candidate)
        end
      end
      if #matches == 1 then
        found = matches[1]
      end
    end

    if found ~= nil then
      -- The candidate only carries the id here; the logo comes from the coin's own
      -- image URL, which /search does not return, so fall through to TradingView
      -- unless the instrument already has a provider logo URL.
      noctalia.log("market-watch: matched " .. found.id .. " for " .. instrument.id)
    end
    search_trading_view_logo(instrument, callback)
  end)
end

request_logo = function(reference)
  local instrument = instrument_for(reference)
  if instrument == nil or instrument.status == "unresolved" then
    return
  end

  local id = instrument.id
  if logos[id] ~= nil or logo_in_flight[id] then
    return
  end
  local failed_at = logo_failures[id]
  if failed_at ~= nil then
    if noctalia.nowMs() - failed_at < LOGO_RETRY_COOLDOWN_MS then
      return
    end
    logo_failures[id] = nil
  end

  -- Reuse a previous session's download before touching the network. The adopted path is
  -- marked for publication: `logos` used to reach the UI only because refresh_market_data
  -- published everything on every cycle, and a cached logo takes exactly this branch,
  -- which never touches the network and therefore never published on its own.
  local cached_png = logo_path(id, "png")
  if cached_file(cached_png) then
    logos[id] = cached_png
    pending_logos = true
    return
  end
  local cached_svg = logo_path(id, "svg")
  if cached_file(cached_svg) then
    logos[id] = cached_svg
    pending_logos = true
    return
  end

  logo_in_flight[id] = true
  local function finish(ok, extension)
    logo_in_flight[id] = nil
    local path = logo_path(id, extension or "png")
    if ok and cached_file(path) then
      logos[id] = path
    else
      -- A failed lookup is remembered so the sweep backs off for a minute.
      logo_failures[id] = noctalia.nowMs()
    end
    pending_logos = true
  end

  if instrument.logo_url ~= "" then
    download_to(logo_path(id, "png"), instrument.logo_url, function(ok)
      if ok then
        finish(true, "png")
      else
        search_external_logo(instrument, finish)
      end
    end)
    return
  end

  local known_logoid = tv_logo_ids[id]
  if known_logoid ~= nil then
    download_trading_view_logo(instrument, known_logoid, finish)
    return
  end

  search_external_logo(instrument, finish)
end

-- Periodic sweep: retries every instrument whose logo is still missing and whose
-- cooldown has elapsed (v4 used a 60 s Timer for the same job).
local function sweep_logos()
  for _, reference in ipairs(runtime.watch_list) do
    request_logo(reference)
  end
  -- Adopting an on-disk logo happens synchronously here and changes what every row draws,
  -- so it is published before this function returns instead of waiting for the tick flush:
  -- the first sweep runs in the busiest tick of the session (cycle + publish), and being
  -- cut short by a budget abort used to leave the panels without icons for a whole
  -- cooldown. Twelve short strings, once a minute.
  if pending_logos then
    publish_logos()
    pending_logos = false
  end
end

-- ── Search ──────────────────────────────────────────────────────────────────

local function search_cache_key(query)
  return static.source .. "|" .. static.market_type .. "|" .. string.lower(store.trim(query))
end

-- The one candidate that needs no network call: the constructed instrument for the
-- typed symbol, which is exactly what v4's catalogue resolution produced.
local function local_candidates(query)
  local results = {}
  if static.source == "coingecko" then
    return results
  end
  local base = providers.normalize_symbol(query)
  if base == "" then
    return results
  end
  local instrument = providers.construct_instrument(static.source, static.market_type, base, "")
  if instrument ~= nil then
    table.insert(results, instrument)
  end
  return results
end

local function publish_search(query, results, pending)
  local rows = {}
  for _, instrument in ipairs(results) do
    table.insert(rows, {
      id = instrument.id,
      symbol = instrument.display_symbol,
      name = instrument.name,
    })
  end
  search_payload = {
    query = query or "",
    results = rows,
    pending = pending == true,
    nonce = noctalia.nowMs(),
  }
  noctalia.state.set("market.search", search_payload)
end

local function trim_search_cache()
  local count = 0
  for _ in pairs(search_cache) do
    count = count + 1
  end
  while count > SEARCH_CACHE_MAX do
    local oldest_key = nil
    local oldest_at = nil
    for key, entry in pairs(search_cache) do
      if oldest_at == nil or entry.at < oldest_at then
        oldest_key = key
        oldest_at = entry.at
      end
    end
    if oldest_key == nil then
      break
    end
    search_cache[oldest_key] = nil
    count = count - 1
  end
end

run_search = function(query, done)
  local key = search_cache_key(query)
  local results = local_candidates(query)
  local seen = {}
  for _, instrument in ipairs(results) do
    seen[instrument.id] = true
  end

  local function merge(candidates)
    for _, instrument in ipairs(candidates) do
      if not seen[instrument.id] and #results < MAX_SEARCH_RESULTS then
        seen[instrument.id] = true
        table.insert(results, instrument)
      end
    end
  end

  local function finish()
    search_cache[key] = { results = results, at = noctalia.nowMs() }
    trim_search_cache()
    publish_search(query, results, false)
    if done ~= nil then
      done()
    end
  end

  if static.source == "coingecko" then
    api_get(providers.coingecko_search_url(query), API_MAX_BYTES, function(ok, body)
      if ok then
        local decoded = decode_body(body)
        if decoded ~= nil then
          merge(providers.parse_coingecko_candidates(decoded))
        end
      end
      finish()
    end)
    return
  end

  -- Crypto providers: TradingView's symbol search is the only small endpoint that
  -- lists exchange instruments, and the only way to reach tokenized-stock
  -- perpetuals (HTX "ZHIPUUSDT.P").
  api_get(providers.trading_view_search_url(query), API_MAX_BYTES, function(ok, body)
    if ok then
      local decoded = decode_body(body)
      if decoded ~= nil then
        merge(providers.parse_trading_view_candidates(decoded, static.source, static.market_type))
      end
    end
    finish()
  end, true)
end

-- Reply immediately from the cache or locally, then let update() run the debounced
-- lookup: the input fires on every keystroke, so only the last query may reach the
-- network.
local function request_search(query)
  local text = store.trim(query)
  if text == "" then
    pending_search = nil
    publish_search("", {}, false)
    return
  end

  local cached = search_cache[search_cache_key(text)]
  local now = noctalia.nowMs()
  if cached ~= nil and (now - cached.at) < SEARCH_CACHE_TTL_MS then
    -- A cache hit answers immediately, but it must also cancel a queued lookup:
    -- otherwise the superseded query would finish later and overwrite this reply.
    pending_search = nil
    publish_search(text, cached.results, false)
    return
  end

  publish_search(text, local_candidates(text), true)
  pending_search = { query = text, at = now }
end

-- ── CoinGecko resolution ────────────────────────────────────────────────────

-- Rules are keyed by instrument id, so any rewrite of a stored reference has to
-- carry them along: otherwise switching data source would leave the user's alerts
-- attached to ids that no longer exist in the list.
local function rekey_alerts(remap)
  if next(remap) == nil then
    return
  end
  local price_alerts = {}
  for id, rule in pairs(runtime.price_alerts) do
    price_alerts[remap[id] or id] = rule
  end
  runtime.price_alerts = price_alerts

  local rapid_ids = {}
  for _, id in ipairs(runtime.rapid_alert.instrument_ids) do
    table.insert(rapid_ids, remap[id] or id)
  end
  runtime.rapid_alert.instrument_ids = rapid_ids
end

local function rewrite_watch_reference(from, to)
  local changed = false
  local seen = {}
  local next_list = {}
  for _, reference in ipairs(runtime.watch_list) do
    local value = reference == from and to or reference
    if not seen[value] then
      seen[value] = true
      table.insert(next_list, value)
    end
  end
  if table.concat(next_list, "\n") ~= table.concat(runtime.watch_list, "\n") then
    changed = true
  end
  runtime.watch_list = next_list

  if runtime.bar_coin == from then
    runtime.bar_coin = to
    changed = true
  end
  if from ~= to then
    rekey_alerts({ [from] = to })
    -- The followed subset is matched against the watch list, so it has to follow the
    -- symbol rewrite too; otherwise resolving a CoinGecko symbol would silently drop the
    -- follow and fall back to rotating everything.
    if type(runtime.carousel_ids) == "table" and #runtime.carousel_ids > 0 then
      local next_ids = {}
      for _, reference in ipairs(runtime.carousel_ids) do
        table.insert(next_ids, reference == from and to or reference)
      end
      runtime.carousel_ids = store.normalize_watch_list(next_ids)
    end
    changed = true
  end
  if changed then
    persist()
  end
end

resolve_coingecko = function(reference, done)
  local query = providers.normalize_symbol(reference)
  local url = providers.coingecko_search_url(query)
  if url == "" then
    done()
    return
  end

  api_get(url, API_MAX_BYTES, function(ok, body)
    local candidates = {}
    if ok then
      local decoded = decode_body(body)
      if decoded ~= nil then
        candidates = providers.parse_coingecko_candidates(decoded)
      end
    end

    local pick = providers.pick_coingecko_candidate(candidates, reference)
    if pick == nil then
      -- Keep the entry visible but flagged, exactly like v4's unresolved rows.
      local placeholder = providers.create_instrument(
        "coingecko",
        "spot",
        query,
        query,
        "",
        query,
        "USD",
        "unresolved",
        ""
      )
      if placeholder ~= nil then
        register_instrument(placeholder)
        -- Store the placeholder id so the entry stops being a bare symbol: without
        -- this every publish would queue the same doomed lookup again.
        rewrite_watch_reference(reference, placeholder.id)
        set_quote_failure(placeholder, "unavailable", noctalia.tr("settings.unavailable"))
      end
      noctalia.log("market-watch: no CoinGecko coin matches '" .. tostring(reference) .. "'")
    else
      register_instrument(pick)
      rewrite_watch_reference(reference, pick.id)
      noctalia.log("market-watch: resolved '" .. tostring(reference) .. "' to " .. pick.id)
      publish()
      fetch_quote(pick.id, true)
    end
    done()
    publish()
  end)
end

-- ── Runtime mutations (all reached through the command channel) ─────────────

local function find_watch_index(id)
  local text = store.normalize_reference(id)
  if text == "" then
    return nil
  end
  for index, reference in ipairs(runtime.watch_list) do
    if reference == text then
      return index
    end
  end
  -- A first-run seed (or a legacy market.json) can still hold the bare symbol
  -- while the UI sends the resolved instrument id, so compare what both resolve to.
  local wanted = instrument_for(text)
  if wanted == nil then
    return nil
  end
  for index, reference in ipairs(runtime.watch_list) do
    local instrument = instrument_for(reference)
    if instrument ~= nil and instrument.id == wanted.id then
      return index
    end
  end
  return nil
end

local function add_watch(reference)
  local text = store.normalize_reference(reference)
  if text == "" then
    return
  end

  local instrument = instrument_for(text)
  local id = instrument ~= nil and instrument.id or text
  if store.includes(runtime.watch_list, id) then
    return
  end

  table.insert(runtime.watch_list, id)
  if #runtime.watch_list == 1 or runtime.bar_coin == nil then
    runtime.bar_coin = id
  end
  persist()
  publish()

  if instrument == nil then
    -- A CoinGecko bare symbol: the tick resolves it.
    queue_resolution(text)
    return
  end

  -- Ask the provider whether it really lists this symbol before polling it.
  verify_instrument(instrument, function(available)
    if available then
      fetch_quote(instrument.id, true)
    else
      mark_unavailable(instrument)
    end
    publish()
  end)
end

local function remove_watch(id, index)
  local target = nil
  if type(index) == "number" and index >= 1 and index <= #runtime.watch_list then
    target = index
  elseif id ~= nil then
    target = find_watch_index(store.normalize_reference(id))
  end
  if target == nil then
    return
  end

  local removed = table.remove(runtime.watch_list, target)
  if runtime.bar_coin == removed then
    runtime.bar_coin = runtime.watch_list[1]
  end

  -- The alert rule and the rapid-alert selection for a removed instrument are
  -- pruned too, so re-adding it later starts clean. Rules are keyed by instrument
  -- id, which can differ from the stored reference for a legacy entry.
  local resolved = instrument_for(removed)
  local removed_ids = { [removed] = true }
  if resolved ~= nil then
    removed_ids[resolved.id] = true
  end
  for id in pairs(removed_ids) do
    runtime.price_alerts[id] = nil
  end
  local kept = {}
  for _, instrument_id in ipairs(runtime.rapid_alert.instrument_ids) do
    if not removed_ids[instrument_id] then
      table.insert(kept, instrument_id)
    end
  end
  runtime.rapid_alert.instrument_ids = kept

  -- The rotation follows the watch list, so an asset that left stops being followed.
  -- (carousel_entries() would drop it anyway; this keeps market.json honest.)
  local followed = {}
  for _, reference in ipairs(runtime.carousel_ids or {}) do
    if not removed_ids[reference] then
      table.insert(followed, reference)
    end
  end
  runtime.carousel_ids = followed

  persist()
  publish()
end

local function move_watch(id, delta)
  local reference = store.normalize_reference(id)
  local index = find_watch_index(reference)
  if index == nil then
    return
  end
  local step = tonumber(delta) or 0
  if step == 0 then
    return
  end
  local target = math.max(1, math.min(#runtime.watch_list, index + (step > 0 and 1 or -1)))
  if target == index then
    return
  end
  local row = table.remove(runtime.watch_list, index)
  table.insert(runtime.watch_list, target, row)
  persist()
  publish()
end

-- Which way the wheel travelled. The widget steps exactly one entry of market.watch and
-- wraps at both ends, so the requested entry is the neighbour of whatever is on screen:
-- whichever neighbour relation holds gives the sign.
local function carousel_direction_towards(reference)
  local count = #runtime.watch_list
  if count < 2 then
    return 0
  end
  local shown = carousel_active_reference() or runtime.bar_coin
  local shown_position = carousel_position_of(runtime.watch_list, shown)
  local target_position = carousel_position_of(runtime.watch_list, reference)
  if shown_position == nil or target_position == nil then
    return 1
  end
  if (shown_position % count) + 1 == target_position then
    return 1
  end
  if ((shown_position - 2) % count) + 1 == target_position then
    return -1
  end
  return target_position > shown_position and 1 or -1
end

local function set_bar_coin(id)
  local reference = store.normalize_reference(id)
  local index = find_watch_index(reference)
  if index == nil then
    return
  end
  -- Store the entry as it is listed today, so the bar and the watch list agree. This is
  -- the user's explicit choice: the rotation never writes it, and switching the
  -- carousel off shows it again.
  runtime.bar_coin = runtime.watch_list[index]

  if not carousel_enabled() then
    persist()
    publish()
    return
  end

  -- Carousel on: the same command now moves the rotation. widget.luau cannot know about
  -- the carousel - it walks market.watch and sends the neighbouring entry - so the
  -- service translates that absolute pick into a rotation move: a followed entry
  -- becomes the cursor, an unfollowed one steps the rotation in the direction the
  -- wheel travelled. Either way the interval restarts, so the manual choice is never
  -- overridden by an advance the user did not cause.
  local position = carousel_position_of(carousel_entries(), runtime.bar_coin)
  if position ~= nil then
    runtime.carousel_index = position
  else
    carousel_step(carousel_direction_towards(runtime.bar_coin))
  end
  carousel_reset_timer()
  persist()
  publish()
end

local function toggle_display_mode()
  runtime.display_mode = runtime.display_mode == "text" and "compact" or "text"
  persist()
  publish()
end

local function set_price_alert(id, enabled, upper, lower)
  local key = store.trim(id)
  if key == "" then
    return
  end
  local current = runtime.price_alerts[key] or { enabled = false }
  local updated = {
    enabled = current.enabled,
    upper_price = current.upper_price,
    lower_price = current.lower_price,
  }
  if enabled ~= nil then
    updated.enabled = enabled == true
  end
  -- An empty string clears the bound, exactly like v4's price input.
  if upper ~= nil then
    updated.upper_price = alerts.as_positive_number(upper)
  end
  if lower ~= nil then
    updated.lower_price = alerts.as_positive_number(lower)
  end
  runtime.price_alerts[key] = alerts.normalize_price_alert(updated)
  persist()
  publish()
end

local function set_rapid_alert(command)
  local current = runtime.rapid_alert
  local next_alert = {
    enabled = current.enabled,
    threshold_percent = current.threshold_percent,
    window_minutes = current.window_minutes,
    cooldown_minutes = current.cooldown_minutes,
    instrument_ids = current.instrument_ids,
  }

  if command.enabled ~= nil then
    next_alert.enabled = command.enabled == true
  end
  if command.threshold_percent ~= nil then
    next_alert.threshold_percent = command.threshold_percent
  end
  if command.window_minutes ~= nil then
    next_alert.window_minutes = command.window_minutes
  end
  if command.cooldown_minutes ~= nil then
    next_alert.cooldown_minutes = command.cooldown_minutes
  end
  if command.instrument_ids ~= nil then
    next_alert.instrument_ids = command.instrument_ids
  end

  if command.toggle_instrument ~= nil then
    local wanted = store.normalize_reference(command.toggle_instrument)
    local ids = {}
    local found = false
    for _, instrument_id in ipairs(current.instrument_ids) do
      if instrument_id == wanted then
        found = true
      else
        table.insert(ids, instrument_id)
      end
    end
    if not found and wanted ~= "" then
      table.insert(ids, wanted)
    end
    next_alert.instrument_ids = ids
  end

  runtime.rapid_alert = alerts.normalize_rapid_alert(next_alert)
  persist()
  publish()
end

-- One op for the whole feature: the settings panel sends whichever fields changed,
-- exactly like set_rapid_alert. `toggle_id` works on the effective followed set, so
-- un-following one asset out of the empty-list shorthand produces an explicit list of
-- the others rather than a list containing only that asset.
local function set_carousel(command)
  local changed = false

  if command.enabled ~= nil then
    local enabled = command.enabled == true
    if enabled ~= carousel_enabled() then
      runtime.carousel_enabled = enabled
      changed = true
      if enabled then
        -- Do not jump on enable: put the cursor on the asset already on the bar when
        -- that asset is part of the rotation.
        local position = carousel_position_of(carousel_entries(), store.normalize_reference(runtime.bar_coin))
        if position ~= nil then
          runtime.carousel_index = position
        end
      end
    end
  end

  if command.interval ~= nil then
    local interval = store.normalize_carousel_interval(command.interval)
    if interval ~= runtime.carousel_interval then
      runtime.carousel_interval = interval
      changed = true
    end
  end

  local ids = store.normalize_carousel_ids(command.ids)
  if ids ~= nil then
    runtime.carousel_ids = ids
    changed = true
  end

  if command.toggle_id ~= nil then
    local wanted = store.normalize_reference(command.toggle_id)
    if wanted ~= "" then
      local next_ids = {}
      local found = false
      for _, reference in ipairs(carousel_entries()) do
        if reference == wanted then
          found = true
        else
          table.insert(next_ids, reference)
        end
      end
      if not found then
        table.insert(next_ids, wanted)
      end
      runtime.carousel_ids = next_ids
      changed = true
    end
  end

  local stepped = false
  if command.step ~= nil then
    local delta = tonumber(command.step)
    -- Stepping while the carousel is off would move state the user cannot see, so the
    -- panel disables its arrows and the service ignores the op.
    if delta ~= nil and delta ~= 0 and carousel_enabled() then
      stepped = carousel_step(delta)
    end
  end

  -- Any manual change restarts the interval: the user's action must not be undone by
  -- an advance that was already due.
  carousel_reset_timer()
  if changed then
    carousel_clamp_index()
  end
  if changed or stepped then
    persist()
    publish()
  end
end

local function set_config_message(key, detail, is_error)
  config_message = {
    key = key,
    detail = detail or "",
    error = is_error == true,
    nonce = noctalia.nowMs(),
  }
  noctalia.state.set("market.config_message", config_message)
end

local function export_config()
  if store.export_config(runtime, static) then
    set_config_message("settings.config_exported", "", false)
  else
    set_config_message("settings.config_import_failed", "", true)
  end
end

local function import_config()
  local raw = noctalia.readFile(store.config_path())
  if raw == nil or store.trim(raw) == "" then
    set_config_message("settings.config_import_missing", "", true)
    return
  end
  if #raw > store.MAX_CACHE_BYTES then
    set_config_message("settings.config_import_failed", noctalia.tr("panel.response_too_large"), true)
    return
  end

  local payload, err = store.parse_imported(raw)
  if payload == nil then
    local detail = ""
    if type(err) == "string" and err:sub(1, 6) == "parse:" then
      detail = noctalia.tr("panel.bad_response")
    end
    set_config_message("settings.config_import_failed", detail, true)
    return
  end

  runtime = store.apply_imported(runtime, payload)
  persist()
  publish()

  -- Read-only settings cannot be applied by a plugin; naming them tells the user
  -- where to change them (the host settings window).
  local detail = ""
  if #payload.ignored > 0 then
    detail = table.concat(payload.ignored, ", ")
  end
  set_config_message("settings.config_imported", detail, false)

  -- The imported alert rules, colours and symbols should take effect immediately.
  refresh_market_data(true)
end

local function force_refresh()
  -- A manual refresh ignores the backoff window and re-arms every instrument,
  -- including the ones already marked unavailable.
  for _, state in pairs(status) do
    state.next_retry_at = 0
  end
  refresh_market_data(true)
end

local function handle_command(command)
  if type(command) ~= "table" then
    return
  end

  local op = command.op
  if op == "refresh" then
    fetch_quote(command.id, false)
    publish()
  elseif op == "refresh_all" then
    refresh_market_data(false)
  elseif op == "force_refresh" then
    force_refresh()
  elseif op == "add_watch" then
    add_watch(command.ref)
  elseif op == "remove_watch" then
    remove_watch(command.id, command.index)
  elseif op == "move_watch" then
    move_watch(command.id, command.delta)
  elseif op == "set_bar_coin" then
    set_bar_coin(command.id)
  elseif op == "toggle_display_mode" then
    toggle_display_mode()
  elseif op == "set_price_alert" then
    set_price_alert(command.id, command.enabled, command.upper, command.lower)
  elseif op == "set_rapid_alert" then
    set_rapid_alert(command)
  elseif op == "set_carousel" then
    set_carousel(command)
  elseif op == "export_config" then
    export_config()
  elseif op == "import_config" then
    import_config()
  elseif op == "search" then
    request_search(command.query)
  else
    noctalia.log("market-watch: unknown command " .. tostring(op))
  end
end

-- v4 replaced a bare symbol with the full instrument id as soon as its catalogue
-- resolved it. On-demand resolution can do the same synchronously for every
-- provider except CoinGecko (which needs /search, and rewrites the entry there).
local function canonicalize_watch_list()
  local changed = false
  local next_list = {}
  local seen = {}
  for _, reference in ipairs(runtime.watch_list) do
    local instrument = instrument_for(reference)
    local value = instrument ~= nil and instrument.id or reference
    if value ~= reference then
      changed = true
    end
    if not seen[value] then
      seen[value] = true
      table.insert(next_list, value)
    else
      changed = true
    end
  end
  runtime.watch_list = next_list

  local bar = instrument_for(runtime.bar_coin)
  if bar ~= nil and bar.id ~= runtime.bar_coin then
    runtime.bar_coin = bar.id
    changed = true
  end
  if not store.includes(runtime.watch_list, runtime.bar_coin) then
    runtime.bar_coin = runtime.watch_list[1]
    changed = true
  end

  -- The followed subset is matched against the watch list, so a stored bare symbol has
  -- to become the same instrument id here or the subset would match nothing and
  -- silently fall back to rotating everything.
  if type(runtime.carousel_ids) == "table" and #runtime.carousel_ids > 0 then
    local next_ids = {}
    for _, reference in ipairs(runtime.carousel_ids) do
      local instrument = instrument_for(reference)
      table.insert(next_ids, instrument ~= nil and instrument.id or reference)
    end
    local normalized = store.normalize_watch_list(next_ids)
    if table.concat(normalized, "\n") ~= table.concat(runtime.carousel_ids, "\n") then
      changed = true
    end
    runtime.carousel_ids = normalized
  end

  if changed then
    persist()
  end
end

-- ── Provider rebinding (host settings changed) ──────────────────────────────

local function rebind_watch_list()
  local target_prefix = static.source .. ":" .. static.market_type .. ":"

  local function rebind(reference)
    local text = tostring(reference)
    if text:sub(1, #target_prefix) == target_prefix then
      return text
    end
    -- Reduce to the bare base symbol: from the cached instrument when it is known,
    -- otherwise from the reference itself.
    local cached = instruments[text]
    local base = cached ~= nil and cached.symbol or providers.base_from_exchange_symbol(text)
    if base == "" then
      base = providers.normalize_symbol(text)
    end
    if base == "" then
      return ""
    end
    if static.source == "coingecko" then
      -- Coin ids cannot be derived from a symbol: keep the bare symbol and let
      -- the resolver ask /search.
      return base
    end
    local instrument = providers.construct_instrument(static.source, static.market_type, base, "")
    return instrument ~= nil and instrument.id or base
  end

  local rebound = {}
  local remap = {}
  for _, reference in ipairs(runtime.watch_list) do
    local next_reference = rebind(reference)
    if next_reference ~= "" and next_reference ~= reference then
      remap[reference] = next_reference
    end
    table.insert(rebound, next_reference)
  end
  local next_list = store.normalize_watch_list(rebound)
  if #next_list > 0 then
    runtime.watch_list = next_list
  end

  local next_bar = rebind(runtime.bar_coin)
  if next_bar ~= "" then
    runtime.bar_coin = next_bar
  end
  if not store.includes(runtime.watch_list, runtime.bar_coin) then
    runtime.bar_coin = runtime.watch_list[1]
  end
  rekey_alerts(remap)

  -- The followed set is made of the same references as the watch list, so it has to be
  -- rebound through the same mapping or a provider switch would unfollow everything.
  if type(runtime.carousel_ids) == "table" and #runtime.carousel_ids > 0 then
    local next_ids = {}
    for _, reference in ipairs(runtime.carousel_ids) do
      table.insert(next_ids, rebind(reference))
    end
    runtime.carousel_ids = store.normalize_watch_list(next_ids)
  end
  carousel_clamp_index()
  persist()
end

-- Drop cached instruments that belong to the previous provider/market type, so the
-- cache cannot grow without bound and a stale row never leaks into the new view.
local function prune_instruments()
  local kept = {}
  local effective_type = static.market_type
  for id, instrument in pairs(instruments) do
    if instrument.provider == static.source and instrument.market_type == effective_type then
      kept[id] = instrument
    end
  end
  instruments = kept
  instruments_dirty = true
end

-- ── Entry callbacks ─────────────────────────────────────────────────────────

function onConfigChanged()
  local previous = static
  static = read_static()

  local provider_changed = previous.source ~= static.source or previous.market_type ~= static.market_type
  local proxy_changed = previous.proxy_url ~= static.proxy_url

  -- Both change how the network is reached: forget past logo failures.
  if proxy_changed or provider_changed then
    logo_failures = {}
  end

  -- Re-tune the cycle; the heartbeat itself never changes.
  cycle_armed = false
  next_cycle_at = 0

  if provider_changed then
    rebind_watch_list()
    carousel_reset_timer()
    prune_instruments()
    quotes = {}
    status = {}
    queue = {}
    queued = {}
    in_flight = {}
    in_flight_at = {}
    generation = generation + 1
    price_alert_states = {}
    rapid_history = {}
    rapid_states = {}
    pending_resolutions = {}
    search_cache = {}
    pending_search = nil
    busy = true
    publish()
    refresh_market_data(false)
    return
  end

  -- Only the interval, the proxy or the colours changed.
  refresh_market_data(false)
end

-- Plugin IPC, so the bar gesture bindings and `noctalia msg plugin ...` have
-- something to call. The v4 context menu's entries map onto:
--   open panel   -> toggle-panel (the widget's left click does this directly)
--   compact/full -> toggle-mode
--   refresh now  -> refresh-now
function onIpc(event, payload)
  if event == "refresh-now" or event == "refresh" then
    refresh_market_data(false)
  elseif event == "force-refresh" then
    force_refresh()
  elseif event == "toggle-mode" then
    toggle_display_mode()
  elseif event == "toggle-panel" then
    noctalia.togglePanel(PANEL_WATCH)
  elseif event == "status" then
    local bar = bar_info()
    local quote = quotes[bar.id]
    if quote == nil then
      noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.no_data"))
    else
      noctalia.notify(
        noctalia.tr("panel.title"),
        bar.symbol .. " " .. providers.format_price(quote.close) .. " " .. providers.format_change(quote.change)
      )
    end
  else
    noctalia.log("market-watch: unknown IPC event " .. tostring(event))
  end
end

function update()
  local now = noctalia.nowMs()

  if instruments_dirty then
    instruments_dirty = false
    store.save_instruments(instruments)
    -- register_instrument() marks the metadata dirty whenever an instrument is resolved,
    -- verified or upgraded by its first quote. The two views that show that metadata are
    -- published here, so an unavailable row cannot keep a stale availability badge now
    -- that a landed quote only republishes quotes/status/busy.
    noctalia.state.set("market.watch", watch_rows())
    noctalia.state.set("market.instruments", copy_map(instruments))
  end

  -- Debounced search: only the newest query reaches the network, and only after
  -- the user stops typing for SEARCH_DEBOUNCE_MS.
  if pending_search ~= nil and not search_in_flight and (now - pending_search.at) >= SEARCH_DEBOUNCE_MS then
    local request = pending_search
    pending_search = nil
    search_in_flight = true
    run_search(request.query, function()
      search_in_flight = false
    end)
  end

  -- CoinGecko resolutions, one in flight at a time.
  if not resolution_in_flight then
    for reference in pairs(pending_resolutions) do
      pending_resolutions[reference] = nil
      resolution_in_flight = true
      resolving_reference = reference
      resolve_coingecko(reference, function()
        resolution_in_flight = false
        resolving_reference = nil
      end)
      break
    end
  end

  -- CoinGecko's free tier is rate limited, so its floor is 10 s; every other
  -- provider can refresh as fast as the user asked (v4's Timer interval).
  local interval_ms = math.max(
    static.refresh_interval * 1000,
    static.source == "coingecko" and 10000 or 1000
  )

  if not cycle_armed or now >= next_cycle_at then
    cycle_armed = true
    next_cycle_at = now + interval_ms
    refresh_market_data(false)
  end

  -- Bar carousel. It runs on this same heartbeat - no second timer - and advances on
  -- schedule whether or not a panel is open. The advance is a table lookup plus the
  -- two-key publish that the tick flushes below.
  if carousel_enabled() and #runtime.watch_list > 0 then
    if next_carousel_at == 0 then
      next_carousel_at = now + carousel_interval_seconds() * 1000
    elseif now >= next_carousel_at then
      next_carousel_at = now + carousel_interval_seconds() * 1000
      if carousel_advance() then
        pending_bar = true
      end
    end
  elseif next_carousel_at ~= 0 then
    -- Switched off, or nothing to rotate: cancel the pending advance.
    next_carousel_at = 0
  end

  -- Keep draining the queue between cycles: a worker slot may have freed up.
  pump_queue()

  -- Flush what the hot paths marked. One write per changed group per tick instead of a
  -- full eleven-key publish per landed quote. Logos go first: their group is the one the
  -- UI cannot recompute, so an abort in a later branch must not starve it.
  if pending_logos then
    publish_logos()
    pending_logos = false
  end
  if pending_bar then
    publish_bar()
    pending_bar = false
  end
  if pending_quotes then
    publish_quotes()
    pending_quotes = false
  end

  if now - last_logo_sweep_at >= LOGO_RETRY_COOLDOWN_MS then
    -- The sweep is the only place a cached logo is adopted, and `last_logo_sweep_at` is
    -- advanced only once it completed: a budget abort halfway used to postpone the rest
    -- by a full cooldown, which is indistinguishable from "the logos are gone".
    local swept, sweep_failure = pcall(sweep_logos)
    if swept then
      last_logo_sweep_at = now
    else
      last_logo_sweep_at = now - LOGO_RETRY_COOLDOWN_MS + 5000
      noctalia.log("market-watch: logo sweep interrupted: " .. tostring(sweep_failure))
    end
  end
end

-- ── Startup ─────────────────────────────────────────────────────────────────

-- The heartbeat is constant: the user's refresh_interval drives the *cycle*, not
-- the service wake-up rate (see BASE_TICK_MS above).
noctalia.setUpdateInterval(BASE_TICK_MS)

-- curl is the plugin's only dependency and every data path uses it, so a missing
-- binary is reported once instead of failing N requests silently.
if not noctalia.commandExists("curl") then
  health.error_code = "missing-curl"
  health.error = noctalia.tr("panel.curl_missing")
  -- Nothing will ever settle, so never leave the panel on "loading".
  busy = false
end

runtime = store.load_runtime()
instruments = store.load_instruments()
load_tv_logo_ids()
-- Resolve whatever the stored list still describes as a bare symbol (the built-in
-- default list, or a market.json written by an earlier version) before publishing.
canonicalize_watch_list()

-- Publish before any network call so the widget can render its asset immediately,
-- and start the first cycle. Nothing to warm up: instruments are built on demand,
-- so there is no catalogue step that could stall the UI.
publish()
refresh_market_data(false)

-- Command channel. Clients (panel, settings panel, widget) publish a table and
-- this service clears it once handled, so the next identical command still
-- registers as a change. world_clock/recorder_service use the same pattern; the
-- nil guard here also means the clear itself cannot bounce back into a loop.
noctalia.state.watch("market.cmd", function(command)
  if type(command) ~= "table" then
    return
  end
  handle_command(command)
  noctalia.state.set("market.cmd", nil)
end)
