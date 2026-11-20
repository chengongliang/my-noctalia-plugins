--!nonstrict
-- Execute the real panel against a controlled clock/state, without a shell or network.
-- Run from market-watch/: lua5.4 tests/history_panel_test.luau
local now = 1770000000000
local state = {
  ["market.config"] = { source = "huobi", market_type = "spot", proxy_url = "", history_epoch = 1, refresh_interval = 5, red_rises = false },
  ["market.watch"] = {
    { id = "huobi:spot:btcusdt", symbol = "BTC", available = true },
    { id = "huobi:spot:ethusdt", symbol = "ETH", available = true },
  },
  ["market.busy"] = false,
}
local commands, renders, tree = {}, 0, nil
local dark, show_close, closed = true, true, false
local format_calls = {}
local labels = {
  ["history.sample"] = "{time} · {price} {currency}",
  ["history.interval"] = "Sampling: {minutes} min",
  ["history.coverage"] = "Available: {first} – {last}",
  ["history.updated"] = "Last updated: {time}",
  ["history.high"] = "High {price}",
  ["history.low"] = "Low {price}",
  ["history.ohlc"] = "O {open} H {high} L {low} C {close}",
  ["history.timeframes.5m"] = "Intraday",
  ["history.timeframes.4h"] = "4h",
  ["history.timeframes.1d"] = "Daily",
  ["history.timeframes.1w"] = "Weekly",
}
local env = setmetatable({}, { __index = _G })
env.require = function(path) return dofile(path) end
env.ui = setmetatable({}, { __index = function(_, kind)
  return function(props, children) return { type = kind, props = props or {}, children = children or {} } end
end })
env.noctalia = {
  nowMs = function() return now end,
  isDarkMode = function() return dark end,
  getSetting = function(key) assert(key == "shell.show_close_buttons"); return show_close end,
  formatTime = function(pattern, seconds, timezone)
    assert(timezone == nil, "panel must use the system local timezone")
    format_calls[#format_calls + 1] = { pattern = pattern, seconds = seconds }
    if pattern == "%Z %z" then return "CST +0800" end
    return tostring(seconds) .. " CST +0800"
  end,
  tr = function(key, subst)
    local text = labels[key] or key
    for name, value in pairs(subst or {}) do text = text:gsub("{" .. name .. "}", function() return tostring(value) end) end
    return text
  end,
  state = {
    get = function(key) return state[key] end,
    set = function(key, value)
      assert(key == "market.cmd")
      commands[#commands + 1] = value
    end,
  },
  togglePanel = function(id) assert(id == "chengongliang/market-watch:settings") end,
}
env.panel = {
  setWantsSecondTicks = function(value) assert(value) end,
  render = function(value) tree, renders = value, renders + 1 end,
  close = function() closed = true end,
}
assert(loadfile("panel.luau", "t", env))()

local function find(predicate, node)
  node = node or tree
  if predicate(node) then return node end
  for _, child in ipairs(node.children) do
    local found = find(predicate, child)
    if found ~= nil then return found end
  end
end
local function key(name) return find(function(node) return node.props.key == name end) end
local function text(value) return find(function(node) return node.props.text and node.props.text:find(value, 1, true) ~= nil end) end
local function invoke(callback, ...)
  if type(callback) == "string" then return env[callback](...) end
  return callback(...)
end
local function click(name) invoke(assert(key(name), name).props.onClick) end
local function assert_readout(timestamp_ms, price)
  local props = key("history-readout").props
  assert(props.text == tostring(math.floor(timestamp_ms / 1000)) .. " CST +0800 · " .. price .. " USDT",
    "latest and hovered readouts must use the same prefix-free format with the correct time and price")
  assert(props.baseline == "textFixedHeight", "readouts must retain a font-metric height")
end
local function snapshot(id, status, revision, options)
  local value = {
    id = id, source = "huobi", market_type = "spot", epoch = state["market.config"].history_epoch,
    status = status, revision = revision, basis = "candle", interval_ms = 300000,
    updated_at = now,
    points = {
      { timestamp_ms = now - 600000, price = 100.25 },
      { timestamp_ms = now - 300000, price = 110 },
      { timestamp_ms = now, price = 105 },
    },
  }
  for name, item in pairs(options or {}) do value[name] = item end
  state["market.history:" .. id .. ((value.timeframe == nil or value.timeframe == "5m") and "" or ":" .. value.timeframe)] = value
  return value
end
local btc, eth = "huobi:spot:btcusdt", "huobi:spot:ethusdt"

env.onOpen()
assert(key("table") ~= nil and key("history-back") == nil)
assert(#commands == 0, "opening the list must not load histories")
local quiet_renders = renders
env.update()
assert(renders == quiet_renders, "quiet polls must not render")
click(btc)
assert(commands[1].op == "history_request" and commands[1].id == btc)
assert(key("history-back") ~= nil and key("table") == nil and text("panel.loading"))
env.onRefreshClicked()
assert(#commands == 1, "repeat clicks before service acknowledgement are deduplicated")

snapshot(btc, "loading", 1, { points = {}, updated_at = 0 })
env.update()
assert(not text("Last updated:"), "initial loading has no successful update time")
snapshot(btc, "ready", 2)
env.update()
assert_readout(now, "105")
assert(text("CST +0800") and text("5 min"))
assert(key("history-" .. btc .. "-1") ~= nil)
local graph = key("history-" .. btc .. "-1")
local stable_move = graph.props.onPointerMove
invoke(stable_move, "0.0000", "0.5000")
assert(text(tostring(math.floor((now - 600000) / 1000))) and text("100.25"))
assert(key("history-" .. btc .. "-1").props.onPointerMove == stable_move, "hover redraw must retain the pointer handler")
quiet_renders = renders
invoke(stable_move, "0.0000", "0.4000")
assert(renders == quiet_renders, "movement inside one sample must not redraw")
invoke(stable_move, "1.0000", "0.5000")
assert(text("105"))
invoke(stable_move, "0.2500", "0.0000")
assert(text("105.28125"), "price must follow the curve at x")
quiet_renders = renders
invoke(stable_move, "0.2500", "1.0000")
assert(renders == quiet_renders and text("105.28125"), "changing pointer y cannot change the price")
assert(not text("history.coverage") and not text("history.candle_basis") and not text("Last updated:"),
  "the three bottom information rows must be removed")
invoke(graph.props.onPointerLeave)
assert_readout(now, "105")
quiet_renders = renders
env.update()
assert(renders == quiet_renders)

now = now + 29999
env.update()
assert(#commands == 1)
now = now + 1
env.update()
assert(#commands == 2 and commands[2].op == "history_request")
local last_good = state["market.history:" .. btc]
snapshot(btc, "stale", 3, { updated_at = last_good.updated_at, points = last_good.points, error_code = "network-error" })
env.update()
assert(key("history-" .. btc .. "-1") and text("history.update_failed") and not text("Last updated:"))
env.onRefreshClicked()
assert(#commands == 3)

env.onBackClicked()
assert(key("table") and not key("history-back"))
now = now + 90000
env.update()
assert(#commands == 3, "the list must not poll histories")
click(eth)
assert(commands[4].id == eth and not key("history-" .. btc .. "-1"))
snapshot(btc, "ready", 4)
env.update()
assert(text("panel.loading"), "another asset's late result must not appear")
snapshot(eth, "error", 1, { points = {}, error_code = "no-data" })
state["market.history:" .. eth].updated_at = nil
env.update()
assert(text("history.no_data") and text("history.retry"))
env.onRefreshClicked()
assert(#commands == 5)

snapshot(eth, "ready", 2)
env.update()
state["market.config"].proxy_url = "http://localhost:1080"
state["market.config"].history_epoch = 2
env.update()
assert(#commands == 6 and not key("history-" .. eth .. "-1"), "old-proxy snapshots must be rejected")
snapshot(eth, "ready", 3)
env.update()
assert(key("history-" .. eth .. "-1"))
state["market.watch"] = { state["market.watch"][1] }
env.update()
assert(key("table") and not key("history-back"), "removing the selected asset returns to the list")

click(btc)
snapshot(btc, "ready", 5)
env.update()
state["market.config"].market_type = "perpetual"
state["market.config"].history_epoch = 3
env.update()
assert(key("table"), "market switches must exit the old detail")
state["market.config"].market_type = "spot"
click(btc)
local before_close = #commands
env.onClose()
now = now + 90000
env.update()
env.onRefreshClicked()
assert(#commands == before_close, "closed panels cannot request more history")
env.onOpen()
assert(key("table") and not key("history-back"))
click(btc)
env.onCloseClicked()
assert(closed)
local after_close = #commands
now = now + 90000
env.update()
assert(#commands == after_close)

show_close, dark = false, false
env.onOpen()
assert(not key("close"))
click("refresh")
assert(commands[#commands].op == "refresh_all", "list refresh must keep its old command")
click("settings")
click(btc)
snapshot(btc, "ready", 6, { points = {
  { timestamp_ms = now - 1800000, price = 100 },
  { timestamp_ms = now - 1500000, price = 110 },
  { timestamp_ms = now - 300000, price = 105 },
  { timestamp_ms = now, price = 108 },
} })
env.update()
assert(key("history-" .. btc .. "-1") and key("history-" .. btc .. "-2"))
quiet_renders = renders
state["market.quotes"] = { [btc] = { close = 99999.123456 } }
env.update()
assert(renders == quiet_renders, "unrelated quote ticks must not redraw a detail")
snapshot(btc, "ready", 7, { points = {
  { timestamp_ms = now - 300000, price = 59999.123456 },
  { timestamp_ms = now, price = 1.234567e-9 },
} })
env.update()
graph = key("history-" .. btc .. "-1")
invoke(graph.props.onPointerMove, "0", "0")
assert(text("59999.123456"), "hover prices must keep source decimal precision")
invoke(graph.props.onPointerMove, "1", "0")
assert(text("1.234567e-09"), "small source prices must not round to zero")
invoke(graph.props.onPointerLeave)
assert_readout(now, "1.234567e-09")
for _ = 1, 3 do
  invoke(graph.props.onPointerMove, "0", "0")
  assert_readout(now - 300000, "59999.123456")
  invoke(graph.props.onPointerLeave)
  assert_readout(now, "1.234567e-09")
end
snapshot(btc, "ready", 8, { points = {
  { timestamp_ms = now - 300000, price = 1000.1 },
  { timestamp_ms = now, price = 1000.9 },
} })
env.update()
local axis = key("history-bounds").children
assert(axis[1].props.text == "High 1000.9" and axis[2].props.text == "Low 1000.1",
  "non-flat chart bounds must retain their source precision")
assert(key("history-plot").props.gap == 0 and key("history-plot").children[1].type ~= "column",
  "plot has no reserved left-axis column")
local candles = {}
for index = 1, 288 do
  candles[index] = { timestamp_ms = now - (289 - index) * 300000, price = 101,
    open = 100, high = 105, low = 95, close = 101 }
end
snapshot(btc, "ready", 9, { points = candles })
env.update()
local before_mode = #commands
state["market.config"].chart_type = "candle"
env.update()
assert(#commands == before_mode, "switching chart type reuses the loaded history")
assert(key("history-candle-" .. btc .. "-1") and key("history-candle-" .. btc .. "-288"), "full day of real candles renders")
assert(text("O 100 H 105 L 95 C 101"), "candles expose full OHLC")
assert(key("history-bounds") == nil, "candle mode removes redundant bounds row since OHLC already displays high and low")
local function check_tree(node)
  assert(#node.children <= 256, "UI nodes must respect the host child limit")
  for _, child in ipairs(node.children) do check_tree(child) end
end
check_tree(tree)
local cell = key("history-candle-" .. btc .. "-1")
assert_readout(candles[#candles].timestamp_ms, "101")
for _ = 1, 3 do
  invoke(cell.props.onHover, "true", cell.props.key)
  assert_readout(candles[1].timestamp_ms, "101")
  invoke(cell.props.onHover, "false", cell.props.key)
  assert_readout(candles[#candles].timestamp_ms, "101")
end
assert(text("O 100 H 105 L 95 C 101").props.baseline == "textFixedHeight",
  "changing OHLC values must retain a font-metric height")

local diverse_candles = {}
for index = 1, 288 do
  diverse_candles[index] = {
    timestamp_ms = now - (289 - index) * 300000,
    price = 100, open = 100, high = 101, low = 99, close = 100,
  }
end
diverse_candles[1] = { timestamp_ms = now - 288 * 300000, price = 98, open = 97, high = 99, low = 96, close = 98 }
diverse_candles[50] = { timestamp_ms = now - 239 * 300000, price = 115, open = 105, high = 120, low = 104, close = 115 }
diverse_candles[150] = { timestamp_ms = now - 139 * 300000, price = 85, open = 90, high = 91, low = 80, close = 85 }
diverse_candles[288] = { timestamp_ms = now - 300000, price = 105, open = 104, high = 106, low = 103, close = 105 }
snapshot(btc, "ready", 99, { points = diverse_candles })
env.update()
assert(text("O 97 H 120 L 80 C 105"), "default unhovered OHLC readout must show 24h open, high, low, and current close")
local last_cell = key("history-candle-" .. btc .. "-288")
invoke(last_cell.props.onHover, "true", last_cell.props.key)
assert(text("O 104 H 106 L 103 C 105"), "hovering candle must show that candle's individual OHLC")
invoke(last_cell.props.onHover, "false", last_cell.props.key)
assert(text("O 97 H 120 L 80 C 105"), "unhovering must revert to 24h extrema")

local normal_color = cell.children[2].props.fill
state["market.config"].red_rises = true
env.update()
assert(key("history-candle-" .. btc .. "-1").children[2].props.fill ~= normal_color, "candles honor rise/fall palette settings")
for index, candle in ipairs(candles) do candle.timestamp_ms = now - (289 - index) * 600000 end
snapshot(btc, "ready", 10, { points = candles })
env.update()
check_tree(tree)
snapshot(btc, "ready", 11)
env.update()
assert(key("history-" .. btc .. "-1") and text("history.line_fallback"), "price-only data must not invent candles")
local before_reload = #commands
state["market.config"].history_epoch = state["market.config"].history_epoch + 1
env.update()
assert(#commands == before_reload + 1 and not key("history-" .. btc .. "-1"), "service reload must replace the old epoch and request fresh history")

snapshot(btc, "ready", 12)
env.update()
assert(key("history-timeframes") and key("history-timeframe-5m").props.variant == "secondary",
  "the existing intraday view remains the default and exposes interval buttons")
local before_timeframe = #commands
click("history-timeframe-4h")
assert(#commands == before_timeframe + 1 and commands[#commands].timeframe == "4h" and commands[#commands].id == btc,
  "4h button immediately requests actual four-hour history")
assert(key("history-timeframe-4h").props.variant == "secondary" and not key("history-" .. btc .. "-1") and text("panel.loading"),
  "selection feedback is immediate and old interval data is removed")
click("history-timeframe-4h")
env.onRefreshClicked()
env.onHistoryTimeframeChanged("2h")
assert(#commands == before_timeframe + 1, "repeat and invalid interval clicks cannot duplicate pending requests")
click("history-timeframe-1d")
assert(#commands == before_timeframe + 2 and commands[#commands].timeframe == "1d", "daily can be selected while 4h is loading")

local function interval_snapshot(timeframe, interval, revision)
  local points = {}
  for index = 1, 3 do
    points[index] = { timestamp_ms = now - (4 - index) * interval, price = 100 + index,
      open = 90, high = 110, low = 80, close = 100 + index }
  end
  return snapshot(btc, "ready", revision, {
    timeframe = timeframe, interval_ms = interval, window_ms = interval * 300, points = points,
  })
end
interval_snapshot("4h", 14400000, 13)
snapshot(btc, "ready", 14)
env.update()
assert(text("panel.loading") and not key("history-candle-" .. btc .. "-4h-1"),
  "late intraday and 4h responses cannot appear in a daily view")
local daily = interval_snapshot("1d", 86400000, 15)
env.update()
assert(key("history-candle-" .. btc .. "-1d-1") and key("history-candle-" .. btc .. "-1d-3"),
  "daily candles older than 24 hours remain drawable")
assert(text("O 90 H 110 L 80 C 103") and not text("24H"), "daily default OHLC describes the selected window")
assert_readout(daily.points[3].timestamp_ms, "103")
invoke(stable_move, "0", "1")
assert_readout(daily.points[3].timestamp_ms, "103")
local daily_cell = key("history-candle-" .. btc .. "-1d-1")
invoke(daily_cell.props.onHover, "true", daily_cell.props.key)
assert_readout(daily.points[1].timestamp_ms, "101")
invoke(cell.props.onHover, "true", cell.props.key)
assert_readout(daily.points[1].timestamp_ms, "101")
check_tree(tree)

click("history-timeframe-1w")
assert(commands[#commands].timeframe == "1w" and text("panel.loading"), "weekly selection clears daily hover and requests weekly candles")
snapshot(btc, "error", 16, { timeframe = "1w", points = {}, updated_at = 0, error_code = "network-error" })
env.update()
assert(text("history.load_failed") and text("history.retry") and not key("history-candle-" .. btc .. "-1d-1"),
  "weekly first-load failure does not borrow daily data")
env.onRefreshClicked()
local weekly = interval_snapshot("1w", 604800000, 17)
env.update()
assert(key("history-candle-" .. btc .. "-1w-1") and key("history-timeframe-1w").props.variant == "secondary",
  "weekly history has its own chart and active button")
assert_readout(weekly.points[3].timestamp_ms, "103")
snapshot(btc, "stale", 18, {
  timeframe = "1w", interval_ms = 604800000, window_ms = 604800000 * 300,
  points = weekly.points, updated_at = weekly.updated_at, error_code = "network-error",
})
env.update()
assert(key("history-candle-" .. btc .. "-1w-1") and text("history.update_failed"), "failed weekly refresh retains only the weekly chart")
click("history-timeframe-4h")
assert(key("history-candle-" .. btc .. "-4h-1") and not key("history-candle-" .. btc .. "-1w-1"),
  "returning to a cached interval immediately shows that interval's candles")
env.onBackClicked()
local after_period_back = #commands
now = now + 90000
env.update()
assert(#commands == after_period_back, "returning to the list stops requests for all intervals")
state["market.watch"][2] = { id = eth, symbol = "ETH", available = true }
env.update()
click(eth)
assert(commands[#commands].timeframe == "4h", "asset navigation retains the current interval while the panel is open")
env.onClose()
local after_period_close = #commands
now = now + 90000
env.update()
env.onHistoryTimeframeChanged("1w")
assert(#commands == after_period_close, "closed panel callbacks cannot request new intervals")
env.onOpen()
click(btc)
assert(commands[#commands].timeframe == "5m", "reopening the panel resets the transient interval to intraday")

state["market.config"].source = "coingecko"
state["market.config"].history_epoch = state["market.config"].history_epoch + 1
state["market.watch"] = { { id = "coingecko:spot:bitcoin", symbol = "BTC", available = true } }
env.update()
click("coingecko:spot:bitcoin")
local before_unsupported = #commands
for _, timeframe in ipairs({ "4h", "1d", "1w" }) do
  local button = key("history-timeframe-" .. timeframe)
  assert(button.props.enabled == false and button.props.tooltip == "history.timeframe_unavailable",
    "price-only source explains unsupported candle intervals")
  invoke(button.props.onClick)
end
assert(#commands == before_unsupported and commands[#commands].timeframe == "5m", "unsupported intervals cannot issue misleading requests")
local has_year = false
for _, call in ipairs(format_calls) do
  if call.pattern == "%Y-%m-%d %H:%M %Z" then has_year = true end
end
assert(has_year, "long-period chart times include the year")
assert(#format_calls > 0)
print("history_panel_test: navigation, intervals, hover, refresh, stale states and context isolation passed")
