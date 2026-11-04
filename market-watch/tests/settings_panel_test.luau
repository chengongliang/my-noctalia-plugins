--!nonstrict
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end

local function encode(value)
  if type(value) ~= "table" then return string.format("%q", tostring(value)) end
  local entries = {}
  for key, item in pairs(value) do
    entries[#entries + 1] = encode(key) .. ":" .. encode(item)
  end
  table.sort(entries)
  return "{" .. table.concat(entries, ",") .. "}"
end

local btc = "huobi:spot:btcusdt"
local eth = "huobi:spot:ethusdt"
local state, commands, tree, renders = {}, {}, nil, 0
local show_close, closed = true, false
local env = setmetatable({}, { __index = _G })
env.require = function(path) return dofile(path) end
env.ui = setmetatable({}, { __index = function(_, kind)
  return function(props, children)
    return { type = kind, props = props or {}, children = children or {} }
  end
end })
env.noctalia = {
  nowMs = function() return 1700000000000 end,
  getSetting = function(key)
    assert(key == "shell.show_close_buttons")
    return show_close
  end,
  tr = function(key, subst)
    return key .. (subst and encode(subst) or "")
  end,
  json = { encode = encode },
  state = {
    get = function(key) return state[key] end,
    set = function(key, value)
      assert(key == "market.cmd")
      commands[#commands + 1] = value
    end,
  },
}
env.panel = {
  setWantsSecondTicks = function(value) assert(value) end,
  render = function(value) tree, renders = value, renders + 1 end,
  close = function() closed = true end,
}
assert(loadfile("settings_panel.luau", "t", env))()

local function find(key, node)
  node = node or tree
  if node.props.key == key then return node end
  for _, child in ipairs(node.children) do
    local found = find(key, child)
    if found then return found end
  end
end

local function count_prefix(prefix, node)
  node = node or tree
  local key = node.props.key or ""
  local count = key:sub(1, #prefix) == prefix and 1 or 0
  for _, child in ipairs(node.children) do count = count + count_prefix(prefix, child) end
  return count
end

local function has_text(text, node)
  node = node or tree
  if (node.props.text or ""):find(text, 1, true) then return true end
  for _, child in ipairs(node.children) do
    if has_text(text, child) then return true end
  end
  return false
end

local function invoke(callback, ...)
  if type(callback) == "string" then return env[callback](...) end
  return callback(...)
end

local function click(key)
  invoke(assert(find(key), "missing button: " .. key).props.onClick)
end

local function change(key, ...)
  invoke(assert(find(key), "missing control: " .. key).props.onChange, ...)
end

local function expect_command(op, fields)
  local command = assert(commands[#commands])
  check(command.op == op, "expected command " .. op)
  for key, value in pairs(fields or {}) do
    check(command[key] == value, "command " .. op .. " preserves " .. key)
  end
end

local function seed(total)
  local watch = {}
  for index = 1, total do
    watch[index] = {
      id = index == 1 and btc or index == 2 and eth or "huobi:spot:asset" .. index,
      symbol = index == 1 and "BTC" or index == 2 and "ETH" or "ASSET" .. index,
      name = index == 1 and "Bitcoin" or index == 2 and "Ethereum" or "Asset " .. index,
      available = index ~= 3,
    }
  end
  state = {
    ["market.watch"] = watch,
    ["market.config"] = {
      bar_coin = btc, display_mode = "text", chart_type = "line",
      price_alerts = {
        [btc] = { enabled = true, upper_price = 70000, lower_price = 50000 },
        [eth] = { enabled = false, upper_price = 4000, lower_price = 2500 },
      },
      carousel = { enabled = true, interval = 5, ids = { btc }, index = 1, entry = "BTC" },
      rapid_alert = {
        enabled = true, threshold_percent = 5, window_minutes = 5,
        cooldown_minutes = 30, instrument_ids = { btc, eth },
      },
    },
  }
  commands = {}
  env.onOpen()
end

for _, total in ipairs({ 0, 1, 12, 50 }) do
  seed(total)
  for _, name in ipairs({ "assets", "display", "alerts", "config" }) do
    check(find("settings_tab_" .. name), "all tabs available with " .. total .. " assets")
  end
  local scroll = assert(find("watch_scroll"))
  check(scroll.type == "scroll" and scroll.props.flexGrow == 1, "asset list fills bounded remaining space")
  check(not find("watch_search_0", scroll) and not find("close", scroll), "search and close stay outside asset scrolling")
  check(count_prefix("follow_", scroll) == total, "watch list contains every asset")
  check(not find("chart_type") and count_prefix("pa_upper_") == 0, "inactive pages are not rendered")
  local sent = #commands
  click("settings_tab_alerts")
  click("alert_mode_price")
  check(count_prefix("pa_upper_") == math.min(total, 1), "at most one price editor, even with many assets")
  check((find("price_alert_asset") ~= nil) == (total > 0), "empty lists do not render an unusable selector")
  click("alert_mode_rapid")
  local rapid_scroll = assert(find("rapid_assets_scroll"))
  check(rapid_scroll.type == "scroll" and rapid_scroll.props.flexGrow == 1, "monitor list uses bounded scrolling")
  check(not find("rapid_filter", rapid_scroll) and not find("rapid_threshold", rapid_scroll), "monitor search and parameters stay pinned")
  check(count_prefix("rapid_toggle_", rapid_scroll) == total, "all monitor assets are reachable")
  check(count_prefix("pa_upper_") == 0, "rapid mode does not render price editors")
  click("settings_tab_display")
  check(find("chart_type") and find("carousel_enabled"), "display controls stay reachable")
  click("settings_tab_config")
  check(find("export") and find("import") and has_text("settings.static_note"), "config tools and host settings guidance remain accessible")
  check(#commands == sent, "navigation never mutates configuration")
  env.onOpen()
  check(find("watch_scroll") and not find("chart_type"), "reopening starts with Assets")
end

seed(12)
local before = renders
env.update()
check(renders == before, "unchanged polls preserve control instances and input focus")
check(find("up_" .. btc).props.enabled == false, "first row cannot move up")
check(find("down_huobi:spot:asset12").props.enabled == false, "last row cannot move down")
check(has_text("settings.unavailable"), "unavailable assets remain labelled")
change("follow_" .. btc, "false")
expect_command("set_carousel", { toggle_id = btc })
click("up_" .. eth)
expect_command("move_watch", { id = eth, delta = -1 })
click("down_" .. btc)
expect_command("move_watch", { id = btc, delta = 1 })
click("remove_" .. eth)
expect_command("remove_watch", { id = eth })
change("watch_search_0", "xau")
expect_command("search", { query = "xau" })
state["market.search"] = { pending = true, results = {} }
env.update()
check(has_text("settings.search_pending"), "asset search keeps its pending state")
state["market.search"] = { results = { { id = "huobi:spot:xauusdt", symbol = "XAU", name = "Gold" } } }
env.update()
click("result_huobi:spot:xauusdt")
check(commands[#commands - 1].op == "add_watch" and commands[#commands - 1].ref == "huobi:spot:xauusdt", "search adds the exact result ID")
expect_command("search", { query = "" })
env.update()
check(find("watch_search_1").props.value == "", "adding resets the uncontrolled search input")

click("settings_tab_alerts")
click("alert_mode_price")
check(find("pa_upper_" .. btc).props.value == "70000", "first price editor seeds the saved upper bound")
change("price_alert_asset", "1", "ETH")
check(not find("pa_upper_" .. btc) and find("pa_upper_" .. eth).props.value == "4000", "switching assets replaces rather than reuses price inputs")
change("pa_upper_" .. eth, "4200")
expect_command("set_price_alert", { id = eth, upper = "4200" })
change("pa_lower_" .. eth, "")
expect_command("set_price_alert", { id = eth, lower = "" })
change("pa_enabled_" .. eth, "true")
expect_command("set_price_alert", { id = eth, enabled = true })
local sent = #commands
local current_key = find("pa_upper_" .. eth).props.key
for _, invalid in ipairs({ "-1", "99", "bad", "0.5" }) do change("price_alert_asset", invalid, "bad") end
check(#commands == sent and find(current_key), "invalid selections neither mutate nor switch assets")
state["market.config"].price_alerts[eth] = { enabled = true, lower_price = 5000, upper_price = 4000 }
env.update()
check(has_text("settings.invalid_price_range"), "range validation survives the compact editor")
check(find("pa_upper_" .. eth).props.key == current_key, "polling retains the active editor key")

local old_selection = find("price_alert_asset").props.onChange
local watch = state["market.watch"]
watch[1], watch[2] = watch[2], watch[1]
env.update()
check(find("price_alert_asset").props.selectedIndex == 0 and find("pa_upper_" .. eth), "selected identity survives reordering")
invoke(old_selection, "0", "BTC")
check(find("pa_upper_" .. btc), "selector callback resolves its rendered IDs, not a reordered array")
table.remove(watch, 2)
env.update()
check(not find("pa_upper_" .. btc) and find("pa_upper_" .. eth), "removing selection falls back to a current asset")
state["market.watch"] = {}
env.update()
check(not find("price_alert_asset") and count_prefix("pa_upper_") == 0, "removing every asset clears stale price controls")
state["market.watch"] = { { id = "binance:spot:BTCUSDT", symbol = "BTC" } }
env.update()
check(find("pa_upper_binance:spot:BTCUSDT").props.value == "", "same symbol from another provider never inherits old rules")

seed(2)
click("settings_tab_alerts")
click("alert_mode_price")
change("pa_upper_" .. btc, "71000")
click("settings_tab_display")
local function replace_config(field, value)
  local published = {}
  for key, current in pairs(state["market.config"]) do published[key] = current end
  published[field] = value
  state["market.config"] = published
end
replace_config("price_alerts", {
  [btc] = { enabled = true, upper_price = 71000, lower_price = 50000 },
  [eth] = { enabled = false, upper_price = 4000, lower_price = 2500 },
})
sent = #commands
click("settings_tab_alerts")
check(find("pa_upper_" .. btc).props.value == "71000", "tab navigation seeds inputs from the published snapshot before the next timer tick")
replace_config("price_alerts", {
  [btc] = { enabled = true, upper_price = 71000, lower_price = 50000 },
  [eth] = { enabled = false, upper_price = 4300, lower_price = 2500 },
})
change("price_alert_asset", "1", "ETH")
check(find("pa_upper_" .. eth).props.value == "4300", "asset navigation reads a replaced configuration snapshot before seeding inputs")
replace_config("rapid_alert", {
  enabled = true, threshold_percent = 9, window_minutes = 5,
  cooldown_minutes = 30, instrument_ids = { btc, eth },
})
click("alert_mode_rapid")
check(find("rapid_threshold").props.value == "9", "reminder mode navigation uses newly published parameter values")
check(#commands == sent, "refreshing state during navigation does not send configuration mutations")

seed(50)
click("settings_tab_alerts")
click("alert_mode_rapid")
local rapid = state["market.config"].rapid_alert
local saved = encode(rapid)
sent = #commands
change("rapid_filter", "eThEr")
check(find("rapid_toggle_" .. eth) and count_prefix("rapid_toggle_") == 1, "rapid filter matches names case-insensitively")
check(#commands == sent and encode(rapid) == saved, "filtering does not mutate monitor selections")
check(find("rapid_selected_count").props.text:find('"count":"2"', 1, true), "selection count includes filtered-out assets")
change("rapid_filter", "[")
check(count_prefix("rapid_toggle_") == 0, "search treats pattern punctuation as literal text")
check(has_text("settings.search_empty"), "no-match state is visible")
change("rapid_filter", "asset3")
check(find("rapid_toggle_huobi:spot:asset3"), "symbol filter finds unavailable assets too")
change("rapid_toggle_huobi:spot:asset3", "true")
expect_command("set_rapid_alert", { toggle_instrument = "huobi:spot:asset3" })
rapid.instrument_ids[#rapid.instrument_ids + 1] = "huobi:spot:asset3"
env.update()
check(find("rapid_selected_count").props.text:find('"count":"3"', 1, true), "service echo updates the selected count")
change("rapid_filter", "")
check(count_prefix("rapid_toggle_") == 50 and find("rapid_toggle_" .. btc).props.checked, "clearing filter restores every row and hidden selections")
check(find("rapid_toggle_huobi:spot:asset3").props.checked, "new selection survives clearing search")
change("rapid_filter", "eth")
click("settings_tab_display")
click("settings_tab_alerts")
check(find("rapid_filter").props.value == "eth", "returning to rapid mode seeds its saved local search text")
change("rapid_enabled", "false")
expect_command("set_rapid_alert", { enabled = false })
for key, field in pairs({ rapid_threshold = "threshold_percent", rapid_window = "window_minutes", rapid_cooldown = "cooldown_minutes" }) do
  change(key, "8")
  expect_command("set_rapid_alert", { [field] = "8" })
end
before = renders
env.update()
check(renders == before, "unchanged filtered polls do not rebuild the input")

click("settings_tab_display")
change("bar_coin", "1", "ETH")
expect_command("set_bar_coin", { id = eth })
change("display_mode", "1", "Compact")
expect_command("toggle_display_mode")
change("chart_type", "1", "Candlestick")
expect_command("set_chart_type", { value = "candle" })
change("carousel_enabled", "false")
expect_command("set_carousel", { enabled = false })
change("carousel_interval", "10")
expect_command("set_carousel", { interval = "10" })
click("carousel_prev")
expect_command("set_carousel", { step = -1 })
click("carousel_next")
expect_command("set_carousel", { step = 1 })

click("settings_tab_config")
click("export")
expect_command("export_config")
click("import")
expect_command("import_config")
state["market.config_message"] = { nonce = "notice-1", key = "settings.config_imported" }
env.update()
check(has_text("settings.config_imported"), "import result stays visible in Configuration")
state["market.health"] = { error = "sample failure" }
click("settings_tab_assets")
env.update()
check(has_text("sample failure"), "health errors remain visible across categories")
show_close = false
env.onOpen()
check(not find("close"), "host close-button preference remains respected")
show_close = true
env.onOpen()
click("close")
check(closed, "close still delegates to the host")
click("settings_tab_config")
check(not has_text("settings.config_imported"), "reopening does not resurrect stale import notices")

print("Settings panel tests passed: " .. checks)
