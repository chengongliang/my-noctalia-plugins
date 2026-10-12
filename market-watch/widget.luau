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

  if busy == true then
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
    set_tooltip(noctalia.tr("panel.no_data"))
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

-- ── State ───────────────────────────────────────────────────────────────────

noctalia.state.watch("market.config", function(value)
  config = value
  render()
end)

noctalia.state.watch("market.bar", function(value)
  bar = value
  render()
end)

noctalia.state.watch("market.watch", function(value)
  -- Kept only so the wheel can walk the list in the order the panel shows. No render:
  -- the service republishes market.bar whenever a change moves the bar asset.
  watch = value or {}
end)

noctalia.state.watch("market.quotes", function(value)
  quotes = value or {}
  render()
end)

noctalia.state.watch("market.status", function(value)
  statuses = value or {}
  render()
end)

noctalia.state.watch("market.health", function(value)
  health = value
  render()
end)

noctalia.state.watch("market.busy", function(value)
  busy = value ~= false
  render()
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
