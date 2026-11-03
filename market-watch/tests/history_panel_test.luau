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
  ["history.latest_sample"] = "Latest sample: {time} · {price} {currency}",
  ["history.interval"] = "Sampling: {minutes} min",
  ["history.coverage"] = "Available: {first} – {last}",
  ["history.updated"] = "Last updated: {time}",
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
  state["market.history:" .. id] = value
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
assert(text("Latest sample:") and text("CST +0800") and text("5 min"))
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
invoke(graph.props.onPointerLeave)
assert(text("Latest sample:"))
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
assert(key("history-" .. btc .. "-1") and text("history.update_failed") and text("Last updated:"))
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
assert(key("history-" .. btc .. "-1") and key("history-" .. btc .. "-2") and text("history.gaps"))
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
snapshot(btc, "ready", 8, { points = {
  { timestamp_ms = now - 300000, price = 1000.1 },
  { timestamp_ms = now, price = 1000.9 },
} })
env.update()
local axis = key("history-plot").children[1].children
assert(axis[1].props.text == "1000.9" and axis[2].props.text == "1000.1",
  "non-flat chart bounds must retain their source precision")
local before_reload = #commands
state["market.config"].history_epoch = state["market.config"].history_epoch + 1
env.update()
assert(#commands == before_reload + 1 and not key("history-" .. btc .. "-1"), "service reload must replace the old epoch and request fresh history")
assert(#format_calls > 0)
print("history_panel_test: navigation, hover, refresh, stale states and context isolation passed")
