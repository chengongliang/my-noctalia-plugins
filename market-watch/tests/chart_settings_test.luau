--!nonstrict
-- Run the real store and settings panel against a reversible in-memory host.
-- Run from market-watch/: lua5.4 tests/chart_settings_test.luau
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local encoded, serial, files = {}, 0, {}
local function encode(value)
  serial = serial + 1
  local token = "json-" .. serial
  encoded[token] = value
  return token
end
local host = {
  pluginDataDir = function() return "/mock-data" end,
  mkdirAll = function() return true end,
  expandPath = function(path) return path end,
  readFile = function(path) return files[path] end,
  writeFile = function(path, value) files[path] = value; return true end,
  json = { encode = encode, decode = function(token) return encoded[token] end },
}
local env = setmetatable({ noctalia = host }, { __index = _G })
local store = assert(loadfile("lib/store.luau", "t", env))()
store.configure(dofile("lib/providers.luau"), dofile("lib/alerts.luau"))
local runtime = store.default_runtime()
check(runtime.chart_type == "line", "default chart is a line")
check(store.apply_persisted(runtime, {}).chart_type == "line", "old configuration keeps the default")
check(store.apply_persisted(runtime, { chart_type = "invalid" }).chart_type == "line", "invalid saved type ignored")
runtime.chart_type = "candle"
check(store.save_runtime(runtime) and store.load_runtime().chart_type == "candle", "saved chart survives restart")
check(store.export_config(runtime, {}), "export succeeds")
local exported = encoded[files[store.config_path()]]
check(exported.chart_type == "candle", "export includes chart choice")
local payload = store.parse_imported(files[store.config_path()])
check(store.apply_imported(store.default_runtime(), payload).chart_type == "candle", "export/import roundtrip")
payload = store.parse_imported(encode({ chart_type = "line" }))
check(store.apply_imported(runtime, payload).chart_type == "line", "import switches back to line")
payload = store.parse_imported(encode({ chart_type = "not-a-chart" }))
check(payload.chart_type == nil and store.apply_imported(runtime, payload).chart_type == "candle", "invalid import keeps choice")
check(store.apply_imported(runtime, { chart_type = {} }).chart_type == "candle", "unvalidated import cannot inject a chart type")

local tree, commands = nil, {}
local state = { ["market.config"] = store.default_runtime(), ["market.watch"] = {} }
host.nowMs = function() return 1700000000000 end
host.tr = function(key) return key end
host.getSetting = function() return true end
host.state = {
  get = function(key) return state[key] end,
  set = function(key, value)
    assert(key == "market.cmd")
    commands[#commands + 1] = value
  end,
}
env.require = function(path) return dofile(path) end
env.ui = setmetatable({}, { __index = function(_, kind)
  return function(props, children) return { type = kind, props = props or {}, children = children or {} } end
end })
env.panel = { setWantsSecondTicks = function() end, render = function(value) tree = value end }
assert(loadfile("settings_panel.luau", "t", env))()
local function find(key, node)
  node = node or tree
  if node.props.key == key then return node end
  for _, child in ipairs(node.children) do
    local found = find(key, child)
    if found then return found end
  end
end
env.onOpen()
local select = assert(find("chart_type"))
check(select.type == "select" and select.props.selectedIndex == 0
  and select.props.options[1] == "chart.line" and select.props.options[2] == "chart.candle", "settings expose both translated chart choices")
select.props.onChange("1", "chart.candle")
check(commands[#commands].op == "set_chart_type" and commands[#commands].value == "candle", "selection sends service-owned mutation")
local count = #commands
state["market.config"].chart_type = "candle"
env.update()
select = assert(find("chart_type"))
check(select.props.selectedIndex == 1, "published choice updates selection")
select.props.onChange("1", "chart.candle")
select.props.onChange("9", "invalid")
check(#commands == count, "unchanged and invalid selections send no command")
select.props.onChange("0", "chart.line")
check(commands[#commands].op == "set_chart_type" and commands[#commands].value == "line", "can switch back to a line")
print("Chart settings tests passed: " .. checks)
