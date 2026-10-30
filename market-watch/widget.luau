--!nonstrict
-- Market Watch bar widget - the v4 BarWidget.qml, ported to the declarative API.
--
-- v4 read everything from `pluginApi.mainInstance` and used a refreshNonce "tick"
-- to force its bindings to re-evaluate. Here the data comes from the service through
-- noctalia.state, and this entry only draws.
--
-- State is POLLED in update(), not subscribed. `noctalia.state.watch` looked like the
-- natural fit, but a hot reload of this file - which the file watcher does on every save,
-- and which happens on every plugin update too - can leave the runtime's subscriptions
-- dead: the callbacks simply never fire again while the service keeps publishing normally,
-- and the bar then freezes on its last drawing with nothing in the log. Only
-- `noctalia msg plugins disable/enable` restores them. Polling is immune to that, and it
-- costs one `state.get` per tick: update() runs every 250 ms by default and these payloads
-- are a dozen small entries, so the get is microseconds next to the redraw it may trigger.
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
local quotes = {}
local statuses = {}
local health = nil
local busy = true

-- The last drawing, so a tick that changes nothing visible does not rebuild the bar tree.
local rendered_signature = nil
-- Last `market.heartbeat` seen; nil means "nothing published yet".
local last_heartbeat = nil
-- The last distinct redraw failure, so a broken render() is reported once, not four times
-- a second.
local render_failure = nil

-- Watchdog state. The functions live below render() because they run inside update();
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
  -- No draw here: `watchdog_stalled` is part of the display signature, so the next
  -- maybe_render() in this same tick repaints through the normal path.
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

-- ── State polling ───────────────────────────────────────────────────────────

-- Read everything render() needs. `market.heartbeat` is the liveness signal: the service
-- writes it on every update() tick, so a heartbeat that stops moving means the entry is no
-- longer running its loop - the one failure this widget exists to repair.
local function poll_state()
  config = noctalia.state.get("market.config") or config
  bar = noctalia.state.get("market.bar") or bar
  quotes = noctalia.state.get("market.quotes") or {}
  statuses = noctalia.state.get("market.status") or {}
  health = noctalia.state.get("market.health") or health
  busy = noctalia.state.get("market.busy") ~= false

  local heartbeat = noctalia.state.get("market.heartbeat")
  if type(heartbeat) == "number" and heartbeat ~= last_heartbeat then
    last_heartbeat = heartbeat
    mark_alive()
  end
end

-- Everything render() actually draws, folded into one string: a redraw happens only when
-- this changes, so a quiet market costs one poll and one compare per tick instead of a
-- rebuilt bar tree. The theme is folded in because it changes the price colour, and
-- `watchdog_stalled` because it switches the drawing between "..." and "--".
local function display_signature()
  local info = bar or {}
  local id = info.id or ((config and config.bar_coin) or "btc")
  local quote = quotes[id]
  local quote_status = statuses[id]
  local parts = {
    tostring(health and health.error or ""),
    tostring(busy),
    tostring(watchdog_stalled),
    tostring(noctalia.isDarkMode()),
    id,
    tostring(info.symbol),
    tostring((config and config.display_mode) or ""),
    tostring((config and config.red_rises) == true),
    tostring(quote_status and quote_status.status or ""),
  }
  if quote ~= nil then
    parts[#parts + 1] = providers.format_price(quote.close)
    parts[#parts + 1] = providers.format_change(quote.change)
    parts[#parts + 1] = quote.is_rising and "up" or "down"
  end
  return table.concat(parts, "|")
end

local function maybe_render()
  local signature = display_signature()
  if signature == rendered_signature then
    return
  end
  -- A redraw is the most expensive thing this entry does (a fresh bar tree plus the
  -- tooltip), and the host's per-callback CPU budget can abort it. The signature is
  -- committed only after a draw finished, so an aborted tick retries on the next one
  -- instead of leaving the bar on stale content for good.
  local ok, failure = pcall(render)
  if ok then
    rendered_signature = signature
    return
  end
  -- Surfaced once per distinct failure instead of every tick: a redraw that keeps failing
  -- is a bug in this file, and swallowing it would leave the bar frozen with no trace.
  if render_failure ~= tostring(failure) then
    render_failure = tostring(failure)
    noctalia.log("market-watch: redraw failed: " .. render_failure)
  end
end

-- ── Entry loop ──────────────────────────────────────────────────────────────

-- Gated to once a second: the poll and the repaint run every tick, this does not.
local function run_watchdog(now)
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
    noctalia.log("market-watch: no heartbeat from the service for " .. math.floor(silent / 1000) .. "s")
  end
  revive_service(silent)
end

-- The host ticks this entry every 250 ms (PluginWidget's default), so the widget is its
-- own clock. Everything here is either idempotent or gated, so a tick the host aborts
-- mid-way costs at most one frame.
function update()
  poll_state()
  run_watchdog(noctalia.nowMs())
  maybe_render()
end

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
  -- Read the list here rather than keeping a copy: it only matters while the wheel turns,
  -- and polling it every tick would be one more state get for nothing.
  local watch = noctalia.state.get("market.watch") or {}
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

-- Restart accounting restored from a previous instance: the disable this widget asks for
-- destroys it, so the counter and the cooldown cannot live in locals alone. Read once -
-- nothing else writes this key.
local stored_watchdog = noctalia.state.get("market.watchdog")
if type(stored_watchdog) == "table" then
  revive_attempts = math.max(revive_attempts, tonumber(stored_watchdog.attempts) or 0)
  local at = tonumber(stored_watchdog.at) or 0
  if at > revive_at then
    revive_at = at
  end
end

-- First paint, before the service has published anything: the widget shows "..." while it
-- starts up, matching v4's isLoading default.
poll_state()
clear_tooltip()
maybe_render()
