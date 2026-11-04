--!nonstrict
local dir = (arg[0]:match("^(.*)[/\\][^/\\]*$") or ".")
local providers = dofile(dir .. "/../lib/providers.luau")
local history = dofile(dir .. "/../lib/history.luau")
local fixtures = dofile(dir .. "/fixtures/history.luau")
local now = 1700001000000
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local okx = providers.parse_history("okx", fixtures.okx)
check(okx.points[1].confirmed == true and okx.points[3].confirmed == false, "OKX unfinished candle stays distinguishable")

for _, source in ipairs({ "huobi", "binance", "okx", "coingecko" }) do
  local parsed = providers.parse_history(source, fixtures[source])
  check(parsed ~= nil and #parsed.points == 3, source .. " parses historical shape")
  check(parsed.points[1].timestamp_ms == 1700000100000, source .. " retains real time and sorts")
  check(parsed.points[3].price == 103 and parsed.interval_ms == 300000, source .. " reads close/price and cadence")
  check(parsed.basis == (source == "coingecko" and "price" or "candle"), source .. " timestamp semantics")
  check(providers.parse_history(source, { error = "bad" }) == nil, source .. " malformed history rejected")
end
local pairs_to_check = {
  { "huobi", "spot", "btcusdt", "symbol=btcusdt", "period=5min" },
  { "huobi", "perpetual", "AAPL-USDT", "contract_code=AAPL-USDT", "period=5min" },
  { "binance", "spot", "BTCUSDT", "api.binance.com/api/v3", "interval=5m" },
  { "binance", "perpetual", "BTCUSDT", "fapi.binance.com/fapi/v1", "interval=5m" },
  { "okx", "spot", "BTC-USDT", "instId=BTC-USDT", "limit=300" },
  { "okx", "perpetual", "AAPL-USDT-SWAP", "instId=AAPL-USDT-SWAP", "bar=5m" },
  { "coingecko", "spot", "bitcoin", "/coins/bitcoin/market_chart", "days=1" },
}
for _, case in ipairs(pairs_to_check) do
  local url = providers.history_url(case[1], case[2], { exchange_symbol = case[3] })
  check(url:find(case[4], 1, true) ~= nil and url:find(case[5], 1, true) ~= nil, case[1] .. " exact history request")
end
check(providers.history_url("coingecko", "spot", { exchange_symbol = "bitcoin" }):find("interval", 1, true) == nil,
  "CoinGecko automatic granularity avoids Enterprise interval")
check(providers.history_url("coingecko", "perpetual", { exchange_symbol = "bitcoin" }) == "", "no fabricated CG perpetual")
check(providers.history_url("huobi", "spot", nil) == "", "missing instrument")
check(providers.parse_history("huobi", { status = "error", data = {} }) == nil, "HTX error rejected")
check(providers.parse_history("binance", { code = -1003 }) == nil, "Binance rate limit rejected")
check(providers.parse_history("okx", { code = "50011", data = {} }) == nil, "OKX error rejected")
check(providers.parse_history("coingecko", { status = { error_code = 429 } }) == nil, "CG rate limit rejected")

local dirty = providers.parse_history("coingecko", { prices = {
  { now - 600000, 5 }, { now - 300000, "6" }, { now - 600000, 7 },
  { now, "nan" }, { now, math.huge }, { now, 0 }, { "bad", 1 }, false,
} })
check(#dirty.points == 2 and dirty.points[1].price == 7, "dedupe and finite positive price filtering")

local points = {
  { timestamp_ms = now - 900000, price = 100 },
  { timestamp_ms = now - 600000, price = 110 },
  { timestamp_ms = now - 300000, price = 105 },
}
local prepared = history.prepare(points, now, 300000)
check(#prepared.segments == 1 and prepared.low == 100 and prepared.high == 110, "shared bounds")
check(prepared.segments[1].values[1] == 0 and prepared.segments[1].values[2] == 1, "graph normalization")
check(history.point_at(prepared.segments[1], "0").timestamp_ms == points[1].timestamp_ms, "hover first timestamp")
check(history.point_at(prepared.segments[1], "0.5").price == 110, "hover middle")
check(history.point_at(prepared.segments[1], 10).price == 105, "hover clamped to last")
check(history.point_at(prepared.segments[1], "nan") == nil, "invalid pointer rejected")

local bounded = history.prepare({
  { timestamp_ms = now - 86400001, price = 1 },
  { timestamp_ms = now - 86400000, price = 2 },
  { timestamp_ms = now + 1, price = 3 },
  { timestamp_ms = now, price = 0 / 0 },
  { timestamp_ms = now, price = math.huge },
}, now, 300000)
check(#bounded.points == 1 and bounded.first_at == now - 86400000, "exact24h cutoff and future/nonfinite rejection")
local flat = history.prepare({ { timestamp_ms = now - 300000, price = 4 }, { timestamp_ms = now, price = 4 } }, now)
check(flat.segments[1].values[1] == 0.5 and flat.segments[1].values[2] == 0.5, "constant price no divide by zero")
check(#history.prepare({}, now).segments == 0, "empty history")
local gapped = history.prepare({
  { timestamp_ms = now - 7200000, price = 4 }, { timestamp_ms = now - 6900000, price = 5 },
  { timestamp_ms = now - 300000, price = 6 }, { timestamp_ms = now, price = 7 },
}, now, 300000)
check(gapped.has_gaps and #gapped.segments == 2, "long missing time stays disconnected")
check(gapped.segments[2].start_at == now - 300000 and gapped.segments[2].values[1] == 2 / 3, "segments retain actual time and common scale")
local odd = providers.parse_history("coingecko", { prices = { { now - 7200000, 1 }, { now - 3600000, 2 }, { now, 3 } } })
check(odd.interval_ms == 3600000, "actual source hourly granularity retained")
for _, source in ipairs({ "huobi", "binance", "okx" }) do
  local parsed = providers.parse_history(source, fixtures[source])
  local p = parsed.points[1]
  check(p.open == 99 and p.high == 102 and p.low == 98 and p.close == 100, source .. " preserves actual OHLC")
  local candles = history.prepare(parsed.points, now, parsed.interval_ms, "candle")
  check(candles.chart_type == "candle" and candles.low == 98 and candles.high == 104, source .. " wicks define scale")
  check(history.prepare(parsed.points, now).low == 100, source .. " line keeps close-only scale")
end
local invalid = providers.parse_history("huobi", { status = "ok", data = {
  { id = now / 1000 - 300, open = 10, high = 9, low = 1, close = 5 },
  { id = now / 1000, open = math.huge, high = 9, low = 1, close = 5 },
} })
check(#invalid.points == 2 and invalid.points[1].open == nil and invalid.points[2].open == nil,
  "invalid OHLC cannot become candles; valid prices remain usable")
check(history.prepare(invalid.points, now, 300000, "candle").chart_type == "line", "bad OHLC falls back to line")
check(history.prepare(odd.points, now, odd.interval_ms, "candle").chart_type == "line", "price-only source falls back to line")
local interpolated = history.price_at(prepared.segments[1], "0.25")
check(interpolated.price == 105.15625 and interpolated.timestamp_ms == now - 750000, "line readout follows host Hermite interpolation along x")
local values = history.graph_values(prepared.segments[1])
check(#values == 5 and values[1] == 0 and values[2] == 0 and values[3] == 0 and values[5] == 0.5,
  "two prefix samples align the host graph x domain with real points")
check(history.price_at(prepared.segments[1], "1").price == 105, "line right edge")
check(history.price_at(prepared.segments[1], "nan") == nil, "invalid line x rejected")
print("History tests passed: " .. tostring(checks))
