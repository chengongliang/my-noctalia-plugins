--!nonstrict
-- Run the real service with controlled I/O and time; quote callbacks deliberately stay pending.
local dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = dir .. "/.."
local fixture = dofile(dir .. "/fixtures/history.luau").huobi
local clock = 1700001000000
local config = { data_source = "huobi", market_type = "spot", proxy_url = "", refresh_interval = 60, red_rises = false }
local state, watchers, jobs, writes = {}, {}, {}, {}
local start_mode = "ok"
local imported = nil
local fail_publication = false
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end
local host = {
  getConfig = function(key) return config[key] end,
  nowMs = function() return clock end,
  setUpdateInterval = function() end,
  commandExists = function() return true end,
  pluginDataDir = function() return "/mock-data" end,
  mkdirAll = function() return true end,
  readFile = function(path)
    if path == "/mock-data/market.json" then return "runtime" end
    if path:find("market-watch-config.json", 1, true) then return imported and "import" or nil end
  end,
  writeFile = function(path) writes[path] = (writes[path] or 0) + 1; return true end,
  expandPath = function(path) return path end,
  fileExists = function() return false end,
  fileInfo = function() return nil end,
  log = function() end,
  tr = function(key) return key end,
  notify = function() error("history must never emit quote alerts") end,
  json = {
    encode = function() return "{}" end,
    decode = function(body)
      if body == "runtime" then return { watch_list = { "btc", "eth", "bnb", "sol", "xrp" } } end
      if body == "history" then return fixture end
      local intervals = { ["history-4h"] = 14400000, ["history-1d"] = 86400000, ["history-1w"] = 604800000 }
      if intervals[body] then
        local value = copy(fixture)
        for index, row in ipairs(value.data) do row.id = (clock - (4 - index) * intervals[body]) / 1000 end
        return value
      end
      if body == "single-week" then
        local row = copy(fixture.data[1])
        row.id = (clock - 86400000) / 1000
        return { status = "ok", data = { row } }
      end
      if body == "empty" then return { status = "ok", data = {} } end
      if body == "rate-limit" then return { status = "error", ["err-code"] = "rate-limit" } end
      if body == "import" then return imported end
      error("invalid JSON")
    end,
  },
  state = {
    get = function(key) return copy(state[key]) end,
    set = function(key, value)
      if fail_publication and key:find("market.history:", 1, true) == 1 and value and value.status == "ready" then
        fail_publication = false
        error("mock publication budget interrupt")
      end
      state[key] = copy(value)
      if watchers[key] then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  runAsync = function(argv, callback)
    local url = argv[#argv]
    local is_history = url:find("size=300", 1, true) ~= nil or url:find("limit=300", 1, true) ~= nil
    if is_history and start_mode == "false" then return false end
    if is_history and start_mode == "throw" then error("mock host budget interrupt") end
    jobs[#jobs + 1] = { argv = argv, callback = callback, history = is_history }
    return true
  end,
}
local env = setmetatable({ noctalia = host }, { __index = _G })
local modules = {}
env.require = function(path)
  if modules[path] == nil then modules[path] = assert(loadfile(root .. "/" .. path, "t", env))() end
  return modules[path]
end
assert(loadfile(root .. "/service.luau", "t", env))()
local btc, eth = "huobi:spot:btcusdt", "huobi:spot:ethusdt"
local function snapshot(id, timeframe)
  return state["market.history:" .. (id or btc) .. ((timeframe == nil or timeframe == "5m") and "" or ":" .. timeframe)]
end
local function request(id, timeframe)
  watchers["market.cmd"]({ op = "history_request", id = id or btc, timeframe = timeframe })
end
local function latest_history()
  for index = #jobs, 1, -1 do if jobs[index].history then return jobs[index] end end
end
local function count_history()
  local count = 0
  for _, job in ipairs(jobs) do if job.history then count = count + 1 end end
  return count
end
local function result(body, extra)
  local value = { exitCode = 0, stdout = body }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

check(count_history() == 0, "startup does not prefetch history")
local persisted = writes["/mock-data/market.json"] or 0
request()
local first = latest_history()
check(snapshot().status == "loading" and snapshot().updated_at == 0, "first request loading")
check(snapshot().epoch == state["market.config"].history_epoch, "published context epoch")
request()
check(count_history() == 1, "duplicate click does not spawn a request")
first.callback(result("history"))
check(snapshot().status == "ready" and #snapshot().points == 3 and snapshot().basis == "candle", "successful real adapter response")
check(snapshot().updated_at == clock, "successful update time")
check((writes["/mock-data/market.json"] or 0) == persisted, "history never persists configuration")
local before_chart_jobs, before_chart_history = #jobs, count_history()
local chart_epoch, chart_revision = snapshot().epoch, snapshot().revision
check(state["market.config"].chart_type == "line", "old runtime defaults to a line chart")
watchers["market.cmd"]({ op = "set_chart_type", value = "candle" })
check(state["market.config"].chart_type == "candle" and writes["/mock-data/market.json"] == persisted + 1,
  "chart choice is persisted and published")
watchers["market.cmd"]({ op = "set_chart_type", value = "candle" })
watchers["market.cmd"]({ op = "set_chart_type", value = "invalid" })
check(state["market.config"].chart_type == "candle" and writes["/mock-data/market.json"] == persisted + 1,
  "invalid and repeated chart choices do not write")
check(#jobs == before_chart_jobs and count_history() == before_chart_history
  and snapshot().epoch == chart_epoch and snapshot().revision == chart_revision,
  "chart choice reuses history without any process, request or invalidation")

local period_jobs = {}
for _, timeframe in ipairs({ "4h", "1d", "1w" }) do
  request(btc, timeframe)
  period_jobs[timeframe] = latest_history()
  check(snapshot(btc, timeframe).status == "loading" and #snapshot(btc, timeframe).points == 0,
    "new interval cannot show another interval's cached candles")
  local count = count_history()
  request(btc, timeframe)
  check(count_history() == count, "duplicate interval requests share their in-flight slot")
end
period_jobs["1w"].callback(result("history-1w"))
local week_revision = snapshot(btc, "1w").revision
period_jobs["4h"].callback(result("history-4h"))
period_jobs["1d"].callback(result("history-1d"))
for timeframe, interval in pairs({ ["4h"] = 14400000, ["1d"] = 86400000, ["1w"] = 604800000 }) do
  local value = snapshot(btc, timeframe)
  check(value.status == "ready" and value.timeframe == timeframe and value.interval_ms == interval
    and value.window_ms == interval * 300 and #value.points == 3 and value.first_at == clock - 3 * interval,
    "requested interval retains history beyond the intraday window")
end
check(snapshot(btc, "1w").revision == week_revision and snapshot().revision == chart_revision,
  "late interval results cannot overwrite other interval snapshots")
request(btc, "1w")
latest_history().callback(result("single-week"))
check(snapshot(btc, "1w").status == "ready" and #snapshot(btc, "1w").points == 1,
  "a newly listed asset can render its only real weekly candle")
request(btc, "1w")
latest_history().callback(result("", { exitCode = 28 }))
check(snapshot(btc, "1w").status == "stale" and #snapshot(btc, "1w").points == 1,
  "a failed weekly refresh preserves a single valid candle")
local before_bad_timeframe = count_history()
for _, invalid in ipairs({ "3h", true, false, {} }) do request(btc, invalid) end
check(count_history() == before_bad_timeframe and snapshot().revision == chart_revision,
  "invalid interval commands cannot start processes or modify valid history")

local ready_revision = snapshot().revision
clock = clock + 1000
request()
check(snapshot().status == "loading" and #snapshot().points == 3 and snapshot().revision > ready_revision, "refresh retains old points with new loading revision")
latest_history().callback(result("", { exitCode = 28 }))
check(snapshot().status == "stale" and snapshot().updated_at == clock - 1000, "network error retains previous success timestamp")

for _, response in ipairs({ result("{bad"), result("empty"), result("rate-limit"), result("history", { stdoutTruncated = true }), result(string.rep("x", 102401)) }) do
  request()
  latest_history().callback(response)
  check(snapshot().status == "stale" and #snapshot().points == 3, "invalid/empty/error/truncated/oversized cannot replace curve")
end
request(eth)
latest_history().callback(result("empty"))
check(snapshot(eth).status == "error" and snapshot(eth).error_code == "no-data", "first empty response has explicit retryable state")
request(eth)
latest_history().callback(result("history"))
check(snapshot(eth).status == "ready", "failed first load can retry")

fail_publication = true
request()
latest_history().callback(result("history"))
check(snapshot().status == "stale", "publication interruption remains retryable")
request()
latest_history().callback(result("history"))
check(snapshot().status == "ready", "callback interruption cannot strand slot")

request()
local obsolete = latest_history()
local old_epoch = snapshot().epoch
config.proxy_url = "socks5://127.0.0.1:1080"
env.onConfigChanged()
check(snapshot() == nil, "proxy switch clears old curve")
for _, timeframe in ipairs({ "4h", "1d", "1w" }) do
  check(snapshot(btc, timeframe) == nil, "proxy switch clears every interval cache")
end
env.update()
check(state["market.config"].history_epoch > old_epoch, "proxy epoch reaches panel configuration")
request()
local proxied = latest_history()
local proxy_found = false
for index, value in ipairs(proxied.argv) do
  if value == "-x" and proxied.argv[index + 1] == config.proxy_url then proxy_found = true end
end
check(proxy_found, "history preserves curl proxy argv")
obsolete.callback(result("history"))
check(snapshot().status == "loading", "old callback cannot overwrite or release new request")
proxied.callback(result("history"))
check(snapshot().status == "ready" and snapshot().epoch > old_epoch, "new context succeeds")

request()
local timed_out = latest_history()
clock = clock + 61000
env.update()
check(snapshot().status == "stale" and snapshot().error_code == "timeout", "lost callback timeout releases slot")
request()
local retry = latest_history()
timed_out.callback(result("history"))
check(snapshot().status == "loading", "timed-out request cannot release newer slot")
retry.callback(result("history"))
check(snapshot().status == "ready", "request recovers after lost callback")

for _, mode in ipairs({ "false", "throw" }) do
  start_mode = mode
  request()
  check(snapshot().status == "stale", "failed/throwing launch recovers slot")
  start_mode = "ok"
  request()
  latest_history().callback(result("history"))
  check(snapshot().status == "ready", "retry after launch failure succeeds")
end

request()
local removed = latest_history()
request(btc, "4h")
local removed_period = latest_history()
watchers["market.cmd"]({ op = "remove_watch", id = btc })
check(snapshot() == nil and snapshot(btc, "4h") == nil, "removed watch clears all interval history states")
removed.callback(result("history"))
removed_period.callback(result("history-4h"))
check(snapshot() == nil and snapshot(btc, "4h") == nil, "removed asset cannot be resurrected by late interval responses")
local before_invalid = count_history()
request("huobi:spot:notwatchedusdt")
check(count_history() == before_invalid and state["market.history:huobi:spot:notwatchedusdt"] == nil, "foreign id does not grow cache")

local parallel_ids = { eth, "huobi:spot:bnbusdt", "huobi:spot:solusdt", "huobi:spot:xrpusdt" }
for _, id in ipairs(parallel_ids) do request(id) end
watchers["market.cmd"]({ op = "add_watch", ref = "huobi:spot:adausdt" })
local busy_count = count_history()
request("huobi:spot:adausdt")
check(count_history() == busy_count and snapshot("huobi:spot:adausdt").error_code == "busy", "rapid asset clicks have bounded curl concurrency")

request(eth)
local before_source_change = latest_history()
config.data_source = "binance"
env.onConfigChanged()
check(snapshot(eth) == nil, "source change clears history")
before_source_change.callback(result("history"))
check(snapshot(eth) == nil, "old source callback discarded")
local inactive_count = count_history()
clock = clock + 30000
env.update()
check(count_history() == inactive_count, "service never schedules hidden chart requests")

local binance_eth = "binance:spot:ETHUSDT"
request(binance_eth)
local imported_away = latest_history()
imported = { watch_list = { "sol" } }
watchers["market.cmd"]({ op = "import_config" })
check(snapshot(binance_eth) == nil, "import prunes removed cached and in-flight histories")
imported_away.callback(result("history"))
check(snapshot(binance_eth) == nil, "imported-away response does not restore history")

local sol = "binance:spot:SOLUSDT"
request(sol)
check(snapshot(sol) ~= nil, "current history exists before hot reload")
request(sol, "1w")
check(snapshot(sol, "1w") ~= nil, "weekly history exists before hot reload")
local reload_epoch = state["market.config"].history_epoch
clock = clock + 1
assert(loadfile(root .. "/service.luau", "t", env))()
check(snapshot(sol) == nil and snapshot(sol, "1w") == nil and state["market.config"].history_epoch > reload_epoch,
  "service reload clears every interval's transient keys and changes epoch")
local before_parallel_periods = count_history()
for _, timeframe in ipairs({ "5m", "4h", "1d", "1w" }) do request(sol, timeframe) end
check(count_history() == before_parallel_periods + 4, "four different intervals use four bounded process slots")
watchers["market.cmd"]({ op = "add_watch", ref = "binance:spot:BTCUSDT" })
request("binance:spot:BTCUSDT", "4h")
check(count_history() == before_parallel_periods + 4 and snapshot("binance:spot:BTCUSDT", "4h").error_code == "busy",
  "rapid timeframe switches cannot bypass global history concurrency")
print("History service tests passed: " .. tostring(checks))
