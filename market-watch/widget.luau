--!nonstrict
-- Market Watch bar widget - the v4 BarWidget.qml, ported to the declarative API.
--
-- v4 read everything from `pluginApi.mainInstance` and used a refreshNonce "tick"
-- to force its bindings to re-evaluate. Here the same data arrives through
-- noctalia.state.watch: this entry is a thin client of the service and only draws.
--
-- The render tree is used instead of setText/setGlyph for two reasons:
--   * barWidget.setColor takes a palette ROLE, while the rise/fall palette is two
--     fixed hex colours (#39c38c / #ff704b) that must stay identical to the panel;
--   * the ↑/↓ suffix is a second, separately coloured run of text.
-- Once a tree is rendered, setText/setGlyph have no visible effect, so everything
-- (including the loading and error states) is expressed in the tree.
--
-- Deliberate divergence: v4's bar text was uncoloured and only the panel used the
-- rise/fall palette. The price and suffix are coloured here to match the panel, so
-- `red_rises` becomes meaningful in the bar too.

local providers = require("./lib/providers.luau")

local PLUGIN_ID = "chengongliang/market-watch"
local PANEL_WATCH = PLUGIN_ID .. ":watch"

-- The v4 error state painted the pill #3a3a3a with #888888 text/icons.
local ERROR_FILL = "#3a3a3a"
local ERROR_TEXT = "#888888"

local config = nil
local bar = nil
local watch = {}
local quotes = {}
local statuses = {}
local health = nil
local busy = true

-- Watchdog state. The functions live below render() because they redraw on recovery;
-- only the fields render() reads are declared up here.
local watchdog_alive_at = 0
local watchdog_stalled = false
local watchdog_ticked_at = 0
local revive_attempts = 0
local revive_at = 0

-- v4 kept a flag before clearing a tooltip: clearTooltip() on a widget that never
-- had one is documented to crash, so only clear what was set.
local has_tooltip = false

local function set_tooltip(value)
  barWidget.setTooltip(value)
  has_tooltip = true
end

local function clear_tooltip()
  if has_tooltip then
    barWidget.clearTooltip()
    has_tooltip = false
  end
end

local function container()
  -- A horizontal bar stacks left-to-right, a vertical one top-to-bottom.
  return barWidget.isVertical() and ui.column or ui.row
end

local function render()
  local info = bar or {}
  local bar_coin = (config and config.bar_coin) or "btc"
  local id = info.id or bar_coin
  local symbol = info.symbol or string.upper(tostring(bar_coin))
  local health_error = (health and health.error) or ""
  local quote = quotes[id]
  local display_mode = (config and config.display_mode) or "text"
  local red_rises = (config and config.red_rises) == true

  if health_error ~= "" then
    -- Hard failure: v4 showed "⚠" on a grey pill and put the message in the tooltip.
    barWidget.render(container()({
      gap = 4,
      align = "center",
      fill = ERROR_FILL,
      radius = 6,
      paddingH = 6,
    }, {
      ui.label({ text = "⚠", color = ERROR_TEXT }),
    }))
    set_tooltip(noctalia.tr("panel.error") .. ": " .. health_error)
    return
  end

  -- "..." only while the service is genuinely starting. Once the watchdog has declared
  -- it dead, sitting on the loading text forever is a lie: fall through to "--".
  if busy == true and not watchdog_stalled then
    barWidget.render(container()({ gap = 4, align = "center" }, {
      ui.label({ text = "..." }),
    }))
    set_tooltip(noctalia.tr("panel.loading"))
    return
  end

  if quote == nil then
    barWidget.render(container()({ gap = 4, align = "center" }, {
      ui.label({ text = "--" }),
    }))
    set_tooltip(noctalia.tr(watchdog_stalled and "panel.service_stalled" or "panel.no_data"))
    return
  end

  local price_text = providers.format_price(quote.close)
  local change_text = providers.format_change(quote.change)
  -- A stale quote (the last poll failed) is dimmed exactly like the panel row,
  -- instead of claiming a live rise/fall colour.
  local quote_status = statuses[id]
  local stale = quote_status ~= nil and quote_status.status == "stale"
  local color = stale and "on_surface_variant"
    or providers.price_color(quote.is_rising, red_rises, true, noctalia.isDarkMode())
  local text = display_mode == "text" and (symbol .. " " .. price_text) or price_text

  barWidget.render(container()({ gap = 4, align = "center" }, {
    ui.label({ text = text, color = color }),
    ui.label({ text = quote.is_rising and "↑" or "↓", color = color }),
  }))

  -- TooltipRow rows (a bare string list is not valid here): the asset names the
  -- first row, then its price and change.
  set_tooltip({
    { key = symbol, value = price_text },
    { key = noctalia.tr("panel.change"), value = change_text },
  })
end

-- ── Service watchdog ────────────────────────────────────────────────────────
-- A host reload can leave the service half-alive: its callbacks still answer IPC, but
-- the entry's top-level startup never ran, so nothing is published and `busy` sits on
-- true forever while the bar shows "...". Nothing inside that VM can fix it - it has no
-- heartbeat to run a check on - so the fix has to come from another entry, which is
-- this widget.
--
-- Liveness is measured as "how long since any market.* state arrived", not by `busy`:
-- a service that died right after publishing busy=false must still be spotted. The
-- service republishes at least once per refresh cycle, so silence across several cycles
-- is the signal.
--
-- Restarting it takes disable + enable (the failure was an in-place reconfigure, and a
-- second in-place reconfigure does not revive it). Enable also recreates this widget, so
-- the two commands are handed to a detached shell: `setsid -f` returns immediately and
-- the restart survives this widget being torn down by its own disable.
local WATCHDOG_MIN_MS = 3000
local WATCHDOG_MAX_MS = 240000
local WATCHDOG_COOLDOWN_MS = 300000
local WATCHDOG_MAX_ATTEMPTS = 3
local WATCHDOG_CHECK_MS = 1000
local NOCTALIA_BIN = "/usr/bin/noctalia"

watchdog_alive_at = noctalia.nowMs()

-- The attempt count and timestamp have to outlive the widget the disable destroys, so
-- they ride on host state. Nothing else reads this key.
local function save_watchdog()
  noctalia.state.set("market.watchdog", { attempts = revive_attempts, at = revive_at })
end

local function mark_alive()
  watchdog_alive_at = noctalia.nowMs()
  if not watchdog_stalled then
    return
  end
  watchdog_stalled = false
  revive_attempts = 0
  save_watchdog()
  noctalia.log("market-watch: the service is publishing again")
  render()
end

local function watchdog_timeout()
  -- Three refresh cycles: floor keeps a 1 s interval from becoming a tripwire, cap keeps
  -- a 60 s interval from waiting ten minutes.
  local refresh = tonumber(config and config.refresh_interval) or 10
  local timeout = math.floor(refresh * 3000 + 0.5)
  if timeout < WATCHDOG_MIN_MS then
    timeout = WATCHDOG_MIN_MS
  elseif timeout > WATCHDOG_MAX_MS then
    timeout = WATCHDOG_MAX_MS
  end
  return timeout
end

local function revive_service(silent_ms)
  local now = noctalia.nowMs()
  if revive_attempts >= WATCHDOG_MAX_ATTEMPTS then
    return
  end
  if revive_at ~= 0 and now - revive_at < WATCHDOG_COOLDOWN_MS then
    return
  end

  revive_attempts = revive_attempts + 1
  revive_at = now
  save_watchdog()

  -- `|| true`: disabling an already-disabled plugin is not worth aborting the restart
  -- over, and the enable below is the step that actually matters.
  local script = "sleep 0.5; "
    .. NOCTALIA_BIN .. " msg plugins disable " .. PLUGIN_ID .. " >/dev/null 2>&1 || true; "
    .. "sleep 2; "
    .. NOCTALIA_BIN .. " msg plugins enable " .. PLUGIN_ID .. " >/dev/null 2>&1 || true"
  local ok, started = pcall(function()
    return noctalia.runAsync({ "setsid", "-f", "/bin/sh", "-c", script }, function() end, 10000)
  end)

  local seconds = math.floor(silent_ms / 1000)
  if ok and started then
    noctalia.log(
      "market-watch: no state for " .. seconds .. "s; asked the host to restart the service (attempt "
        .. revive_attempts .. "/" .. WATCHDOG_MAX_ATTEMPTS .. ")"
    )
    return
  end

  -- No subprocess from this entry: at least make the failure visible instead of leaving
  -- the bar on "--" with no explanation.
  noctalia.notifyError(
    noctalia.tr("panel.title"),
    noctalia.tr("panel.service_stalled")
      .. "\n" .. NOCTALIA_BIN .. " msg plugins disable " .. PLUGIN_ID
      .. " && " .. NOCTALIA_BIN .. " msg plugins enable " .. PLUGIN_ID
  )
end

-- The host ticks widgets at ~250 ms; the 1 s gate below is what keeps this cheap.
function update()
  local now = noctalia.nowMs()
  if now - watchdog_ticked_at < WATCHDOG_CHECK_MS then
    return
  end
  watchdog_ticked_at = now

  local silent = now - watchdog_alive_at
  if silent < watchdog_timeout() then
    return
  end

  if not watchdog_stalled then
    watchdog_stalled = true
    noctalia.log("market-watch: no state from the service for " .. math.floor(silent / 1000) .. "s")
    render()
  end
  revive_service(silent)
end

-- ── State ───────────────────────────────────────────────────────────────────
-- Every one of these callbacks is a liveness signal: they only fire when the service
-- publishes, which is exactly what stops happening when it is half-alive.

noctalia.state.watch("market.config", function(value)
  config = value
  mark_alive()
  render()
end)

noctalia.state.watch("market.bar", function(value)
  bar = value
  mark_alive()
  render()
end)

noctalia.state.watch("market.watch", function(value)
  -- Kept only so the wheel can walk the list in the order the panel shows. No render:
  -- the service republishes market.bar whenever a change moves the bar asset.
  watch = value or {}
  mark_alive()
end)

noctalia.state.watch("market.quotes", function(value)
  quotes = value or {}
  mark_alive()
  render()
end)

noctalia.state.watch("market.status", function(value)
  statuses = value or {}
  mark_alive()
  render()
end)

noctalia.state.watch("market.health", function(value)
  health = value
  mark_alive()
  render()
end)

noctalia.state.watch("market.busy", function(value)
  busy = value ~= false
  mark_alive()
  render()
end)

-- Restart accounting restored from a previous instance: the disable this widget asks for
-- destroys it, so the counter and the cooldown cannot live in locals alone.
noctalia.state.watch("market.watchdog", function(value)
  if type(value) ~= "table" then
    return
  end
  revive_attempts = math.max(revive_attempts, tonumber(value.attempts) or 0)
  local at = tonumber(value.at) or 0
  if at > revive_at then
    revive_at = at
  end
end)

-- ── Events ──────────────────────────────────────────────────────────────────

function onClick()
  noctalia.togglePanel(PANEL_WATCH)
end

-- Scrolling the bar over the pill walks the displayed asset along the watch list, in the
-- order the settings panel lists it, wrapping at both ends. v4's BarWidget.qml had no
-- wheel handler and its manifest declared no scroll binding, so the pill could only ever
-- show the single asset picked in the settings panel; the manifest now binds
-- scroll_up/scroll_down to "none" so the host hands the wheel here instead of consuming it.
function onScroll(_axis, steps, _startsGesture)
  local count = #watch
  if count < 2 then
    return
  end
  -- Callback arguments arrive as strings.
  local direction = tonumber(steps)
  if direction == nil or direction == 0 then
    return
  end

  local id = (bar and bar.id) or (config and config.bar_coin)
  local index = nil
  for position, entry in ipairs(watch) do
    if entry.id == id then
      index = position
      break
    end
  end

  -- One asset per notch: a coalesced flick should not sail through half the list.
  local target = (((index or 1) - 1 + (direction > 0 and 1 or -1)) % count) + 1
  local entry = watch[target]
  if entry == nil or entry.id == nil then
    return
  end

  -- The service owns the list and persists the choice, so the wheel goes through the same
  -- command channel as the settings panel. The nonce matters: wrapping back round to the
  -- asset already on show would otherwise publish an equal command and be coalesced away.
  noctalia.state.set("market.cmd", {
    op = "set_bar_coin",
    id = entry.id,
    nonce = tostring(noctalia.nowMs()) .. "-" .. tostring(target),
  })
end

-- Right-click is user configuration now: the manifest binds
-- `right = "settings-open-widget"` (the legacy ⚙️ entry). The other three v4 menu
-- entries live in the panel and in this plugin's IPC events (see the README).

-- First paint, before any state has been published: the widget shows "..." while
-- the service starts up, matching v4's isLoading default.
clear_tooltip()
render()
