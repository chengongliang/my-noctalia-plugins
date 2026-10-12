--!nonstrict
-- Provider adapter tests - the v4 tests/MarketProviders.test.js assertions, moved
-- onto the on-demand resolution model, driven from the unchanged
-- tests/fixtures/*.json corpus.
--
-- Run from the plugin directory:
--   lua5.4 tests/providers_test.luau
--
-- lib/providers.luau is host-free, so this harness only needs a tiny `noctalia`
-- stub: the plugin's own JSON decoder is the one piece of host behaviour these
-- assertions depend on, so it is implemented here in miniature.
--
-- Every fixture in the corpus is still load-bearing:
--   huobi-quote / binance-quote / okx-quote / coingecko-quote -> parse_quote
--   binance-spot / okx-perpetual      -> the per-symbol verification parser
--   huobi-perpetual                   -> exchange-symbol round trips for the
--                                        tokenized-stock perpetuals v4 read from
--                                        its catalogue
--   coingecko-spot                    -> coin-id/symbol resolution from /search
--   tradingview-search                -> search candidates + logo logoids

-- ── noctalia stub ───────────────────────────────────────────────────────────

local function json_decode(text)
  local pos = 1
  local length = #text

  local function fail(message)
    error("json: " .. message .. " at byte " .. pos, 0)
  end

  local function skip_space()
    while pos <= length do
      local char = text:sub(pos, pos)
      if char == " " or char == "\n" or char == "\r" or char == "\t" then
        pos = pos + 1
      else
        return
      end
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- opening quote
    local out = {}
    while true do
      local char = text:sub(pos, pos)
      if char == "" then
        fail("unterminated string")
      end
      if char == '"' then
        pos = pos + 1
        break
      end
      if char == "\\" then
        local escape = text:sub(pos + 1, pos + 1)
        if escape == "n" then
          table.insert(out, "\n")
        elseif escape == "t" then
          table.insert(out, "\t")
        elseif escape == "r" then
          table.insert(out, "\r")
        elseif escape == "b" then
          table.insert(out, "\b")
        elseif escape == "f" then
          table.insert(out, "\f")
        elseif escape == "u" then
          local code = tonumber(text:sub(pos + 2, pos + 5), 16) or 63
          -- Every fixture is ASCII, so a single-byte fallback is enough.
          table.insert(out, code < 128 and string.char(code) or "?")
          pos = pos + 4
        else
          table.insert(out, escape)
        end
        pos = pos + 2
      else
        table.insert(out, char)
        pos = pos + 1
      end
    end
    return table.concat(out)
  end

  local function parse_number()
    local start = pos
    local char = text:sub(pos, pos)
    if char == "-" then
      pos = pos + 1
    end
    while true do
      char = text:sub(pos, pos)
      if char:match("[%d%.eE%+%-]") then
        pos = pos + 1
      else
        break
      end
    end
    local number = tonumber(text:sub(start, pos - 1))
    if number == nil then
      fail("bad number")
    end
    return number
  end

  local function parse_array()
    pos = pos + 1 -- [
    local out = {}
    skip_space()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return out
    end
    while true do
      skip_space()
      table.insert(out, parse_value())
      skip_space()
      local char = text:sub(pos, pos)
      if char == "," then
        pos = pos + 1
      elseif char == "]" then
        pos = pos + 1
        return out
      else
        fail("expected , or ]")
      end
    end
  end

  local function parse_object()
    pos = pos + 1 -- {
    local out = {}
    skip_space()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return out
    end
    while true do
      skip_space()
      if text:sub(pos, pos) ~= '"' then
        fail("expected object key")
      end
      local key = parse_string()
      skip_space()
      if text:sub(pos, pos) ~= ":" then
        fail("expected :")
      end
      pos = pos + 1
      skip_space()
      out[key] = parse_value()
      skip_space()
      local char = text:sub(pos, pos)
      if char == "," then
        pos = pos + 1
      elseif char == "}" then
        pos = pos + 1
        return out
      else
        fail("expected , or }")
      end
    end
  end

  parse_value = function()
    skip_space()
    local char = text:sub(pos, pos)
    if char == "{" then
      return parse_object()
    end
    if char == "[" then
      return parse_array()
    end
    if char == '"' then
      return parse_string()
    end
    if text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    end
    if text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    end
    if text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    return parse_number()
  end

  local value = parse_value()
  skip_space()
  return value
end

local noctalia = {
  json = { decode = json_decode },
  log = function(message)
    print(message)
  end,
}

-- ── Harness ─────────────────────────────────────────────────────────────────

local function script_dir()
  local script = arg and arg[0] or "tests/providers_test.luau"
  local dir = script:match("^(.*)[/\\][^/\\]*$")
  return dir or "."
end

local dir = script_dir()
local providers = dofile(dir .. "/../lib/providers.luau")

local failures = 0

local function check(condition, label)
  if condition then
    return
  end
  failures = failures + 1
  print("FAIL: " .. label)
end

local function check_equal(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print("FAIL: " .. label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
end

local function fixture(name)
  local handle = assert(io.open(dir .. "/fixtures/" .. name, "r"), "missing fixture " .. name)
  local text = handle:read("*a")
  handle:close()
  return noctalia.json.decode(text)
end

local function find_by_id(instruments, id)
  for _, instrument in ipairs(instruments) do
    if instrument.id == id then
      return instrument
    end
  end
  return nil
end

-- ── Exchange-symbol construction (replaces the bulk catalogue) ───────────────

check_equal(providers.exchange_symbol("huobi", "spot", "btc"), "btcusdt", "huobi spot symbol shape")
check_equal(providers.exchange_symbol("huobi", "perpetual", "btc"), "BTC-USDT", "huobi perpetual symbol shape")
check_equal(providers.exchange_symbol("binance", "spot", "btc"), "BTCUSDT", "binance spot symbol shape")
check_equal(providers.exchange_symbol("binance", "perpetual", "btc"), "BTCUSDT", "binance perpetual symbol shape")
check_equal(providers.exchange_symbol("okx", "spot", "btc"), "BTC-USDT", "okx spot symbol shape")
check_equal(providers.exchange_symbol("okx", "perpetual", "btc"), "BTC-USDT-SWAP", "okx perpetual symbol shape")
check_equal(providers.exchange_symbol("coingecko", "spot", "btc"), "", "coingecko has no exchange symbol")

local constructed = providers.construct_instrument("huobi", "perpetual", "aapl")
check_equal(constructed.id, "huobi:perpetual:AAPL-USDT", "constructed instrument id")
check_equal(constructed.symbol, "aapl", "constructed instrument bare symbol")
check_equal(constructed.display_symbol, "AAPL", "constructed instrument display symbol")
check_equal(constructed.status, "constructed", "a constructed instrument is unverified")
check_equal(constructed.quote, "USDT", "constructed instrument quote currency")

-- ── huobi-perpetual fixture: symbol round trips ─────────────────────────────
-- v4 read these contract codes out of its catalogue; the port rebuilds them from
-- the base asset, and the fixture is the proof that the shapes match (including
-- the tokenized-stock perpetuals the catalogue was the only source of).

local huobi_perpetual = fixture("huobi-perpetual.json")
for _, item in ipairs(huobi_perpetual.data) do
  local base = providers.base_from_exchange_symbol(item.contract_code)
  check_equal(
    providers.exchange_symbol("huobi", "perpetual", base),
    item.contract_code,
    "huobi perpetual round trip for " .. tostring(item.contract_code)
  )
end
local aapl = providers.construct_instrument("huobi", "perpetual", "aapl")
check_equal(aapl.exchange_symbol, "AAPL-USDT", "AAPL-USDT is rebuilt from the fixture-backed shape")
check(
  providers.quote_url("huobi", "perpetual", aapl):find("contract_code=AAPL-USDT", 1, true) ~= nil,
  "huobi perpetual quote URL carries the constructed contract code"
)

local huobi_quote = providers.parse_quote("huobi", fixture("huobi-quote.json"), aapl)
check_equal(huobi_quote.open, 100, "huobi quote open field mapping")
check_equal(huobi_quote.close, 105, "huobi quote close")
check_equal(huobi_quote.high, 110, "huobi quote high")
check_equal(huobi_quote.low, 98, "huobi quote low")
check_equal(huobi_quote.volume, 1234, "huobi quote volume")

-- ── Per-symbol verification: Binance ────────────────────────────────────────

check(
  providers.verification_url("binance", "spot", "BTCUSDT"):find("exchangeInfo?symbol=BTCUSDT", 1, true) ~= nil,
  "binance verification URL filters by symbol"
)
check_equal(
  providers.verification_url("huobi", "spot", "btcusdt"),
  "",
  "huobi has no per-symbol endpoint (the redesign lives behind its bulk catalogue)"
)

local verified = providers.parse_verification("binance", "spot", fixture("binance-spot.json"))
check_equal(#verified, 1, "binance verification keeps only TRADING USDT symbols")
check_equal(verified[1].id, "binance:spot:BTCUSDT", "binance instrument id")
check_equal(verified[1].symbol, "btc", "binance bare symbol comes from the base asset")
check_equal(verified[1].status, "TRADING", "binance status is carried through")
check_equal(
  providers.parse_quote("binance", fixture("binance-quote.json"), verified[1]).close,
  105,
  "binance quote close"
)

-- ── Per-symbol verification: OKX ────────────────────────────────────────────

check(
  providers.verification_url("okx", "perpetual", "BTC-USDT-SWAP"):find("instId=BTC-USDT-SWAP", 1, true) ~= nil,
  "okx verification URL filters by instId"
)
check(
  providers.verification_url("okx", "perpetual", "BTC-USDT-SWAP"):find("instType=SWAP", 1, true) ~= nil,
  "okx verification URL requests the right instrument type"
)

local okx = providers.parse_verification("okx", "perpetual", fixture("okx-perpetual.json"))
check_equal(#okx, 1, "okx verification keeps only USDT-settled live swaps")
check_equal(okx[1].id, "okx:perpetual:BTC-USDT-SWAP", "okx instrument id")
check(
  providers.quote_url("okx", "perpetual", okx[1]):find("instId=BTC-USDT-SWAP", 1, true) ~= nil,
  "okx quote URL carries the instId"
)
check_equal(providers.parse_quote("okx", fixture("okx-quote.json"), okx[1]).close, 105, "okx quote close")

-- ── Error payloads ─────────────────────────────────────────────────────────

check_equal(#providers.parse_verification("binance", "spot", { code = -1121, msg = "Invalid symbol." }), 0, "an unknown binance symbol verifies to nothing")
check_equal(providers.parse_error("binance", { code = -1121, msg = "Invalid symbol." }), true, "binance reports an explicit error")
check_equal(providers.parse_error("binance", { code = 0 }), false, "a binance code of 0 is not an error")
check_equal(providers.parse_error("okx", { code = "51001", msg = "Instrument ID does not exist" }), true, "okx reports an explicit error")
check_equal(providers.parse_error("okx", { code = "0", data = {} }), false, "okx code 0 is not an error")
check_equal(providers.parse_error("huobi", { status = "error", ["err-code"] = "invalid-symbol" }), true, "huobi reports an explicit error")
check_equal(providers.parse_error("huobi", { status = "ok", data = {} }), false, "a huobi ok payload is not an error")
check_equal(providers.parse_error("binance", { code = -1121 }), true, "an error payload is detected before parsing")
check_equal(providers.parse_quote("binance", { code = -1121 }, verified[1]), nil, "an error payload yields no quote")

-- ── CoinGecko: /search resolution ───────────────────────────────────────────
-- The coingecko-spot fixture is the bulk catalogue v4 used; its coin id and symbol
-- pairs are the ground truth for the /search-based resolver.

local coingecko_catalog = fixture("coingecko-spot.json")
check_equal(#coingecko_catalog, 2, "the coingecko fixture still describes two coins")

local coingecko_search = { coins = {} }
for _, coin in ipairs(coingecko_catalog) do
  table.insert(coingecko_search.coins, { id = coin.id, symbol = coin.symbol, name = coin.name })
end

local coingecko_candidates = providers.parse_coingecko_candidates(coingecko_search)
check_equal(#coingecko_candidates, 2, "every /search coin becomes a candidate")
check_equal(coingecko_candidates[1].id, "coingecko:spot:bitcoin", "the coingecko instrument id is the coin id")
check_equal(coingecko_candidates[1].symbol, "btc", "the coingecko bare symbol comes from the coin symbol")
check_equal(coingecko_candidates[1].name, "Bitcoin", "the coingecko name is carried through")
check(
  providers.quote_url("coingecko", "spot", coingecko_candidates[1]):find("ids=bitcoin", 1, true) ~= nil,
  "the coingecko quote URL carries the coin id"
)
check_equal(
  providers.pick_coingecko_candidate(coingecko_candidates, "btc").id,
  "coingecko:spot:bitcoin",
  "a bare symbol resolves to its coin id"
)
check_equal(
  providers.pick_coingecko_candidate(coingecko_candidates, "bitcoin").id,
  "coingecko:spot:bitcoin",
  "a pasted coin id resolves exactly"
)
check_equal(providers.pick_coingecko_candidate(coingecko_candidates, "nope"), nil, "an unknown symbol resolves to nothing")
check_equal(providers.parse_quote("coingecko", fixture("coingecko-quote.json"), coingecko_candidates[1]).close, 105, "coingecko close")
check_equal(providers.parse_coingecko_candidates(nil) ~= nil, true, "a nil /search payload is tolerated")
check_equal(#providers.parse_coingecko_candidates(nil), 0, "a nil /search payload yields no candidates")

-- ── TradingView search: candidates and logos ───────────────────────────────
-- The search is deliberately unfiltered (no search_type): tokenized-stock
-- perpetuals only appear unfiltered, and stock-exchange tickers such as HKEX "100"
-- must never be mistaken for our instruments.

local tv_fixture = fixture("tradingview-search.json")
local tv_url = providers.trading_view_search_url("ZHIPU")
check(tv_url:find("symbol-search.tradingview.com/symbol_search/v3/", 1, true) ~= nil, "tradingview search URL host")
check(tv_url:find("text=ZHIPU", 1, true) ~= nil, "tradingview search URL text")
check(tv_url:find("lang=en", 1, true) ~= nil, "tradingview search URL language")
check(tv_url:find("domain=production", 1, true) ~= nil, "tradingview search URL domain")
check(tv_url:find("search_type", 1, true) == nil, "tradingview search must stay unfiltered")

local tv_perpetuals = providers.parse_trading_view_candidates(tv_fixture, "huobi", "perpetual")
check_equal(#tv_perpetuals, 1, "only the HTX swap row becomes a huobi perpetual candidate")
check_equal(tv_perpetuals[1].id, "huobi:perpetual:ZHIPU-USDT", "the HTX swap row maps onto the huobi contract code")
check_equal(tv_perpetuals[1].name, "ZHIPUUSDT Perpetual Contract", "the TradingView description becomes the name")

local tv_okx = providers.parse_trading_view_candidates(tv_fixture, "okx", "perpetual")
check_equal(#tv_okx, 1, "only the OKX swap row becomes an okx perpetual candidate")
-- The TradingView row supplies the base asset; the provider-native shape (an OKX
-- swap is "<BASE>-USDT-SWAP") comes from exchange_symbol, not from TradingView.
check_equal(tv_okx[1].id, "okx:perpetual:MINIMAX-USDT-SWAP", "the OKX swap row maps onto the okx contract code")

check_equal(
  #providers.parse_trading_view_candidates(tv_fixture, "binance", "spot"),
  0,
  "no binance spot rows are invented from an unrelated exchange"
)

local zhipu = tv_perpetuals[1]
check_equal(
  providers.parse_trading_view_logo_id(tv_fixture, zhipu),
  "knowledge-atlas-technology-joint-stock-company-limited-class-h",
  "tradingview logoid for a tokenized-stock perpetual"
)
check_equal(
  providers.parse_trading_view_logo_id(tv_fixture, { symbol = "minimax", base = "MINIMAX" }),
  "minimax",
  "tradingview logoid ignores the HKEX ticker row"
)
check_equal(
  providers.parse_trading_view_logo_id(tv_fixture, { base = "APPL", display_symbol = "APPL", symbol = "appl" }),
  "",
  "tradingview lookup does not fall back to a fuzzy match"
)
check_equal(providers.parse_trading_view_logo_id({ symbols = {} }, zhipu), "", "empty tradingview result yields no logoid")
check_equal(providers.parse_trading_view_logo_id(nil, zhipu), "", "nil tradingview result yields no logoid")
check_equal(
  providers.trading_view_logo_url("minimax"),
  "https://s3-symbol-logo.tradingview.com/minimax--big.svg",
  "tradingview logo URL"
)
check_equal(providers.trading_view_logo_url(""), "", "empty logoid yields no logo URL")

-- ── Symbol normalisation and formatting ────────────────────────────────────

check_equal(providers.normalize_symbol("BTC_USDT.PERP"), "btc", "normalize_symbol strips the perpetual marker")
check_equal(providers.normalize_symbol("BTC-USDT-SWAP"), "btc", "normalize_symbol strips the swap marker")
check_equal(providers.normalize_symbol("ZHIPU"), "zhipu", "normalize_symbol keeps a bare base asset")
-- Preserved v4 quirk: normalize_symbol only strips ".perp", never ".p". The
-- TradingView helpers strip ".p" before calling in, which is why "ZHIPUUSDT.P"
-- still matches the "zhipu" instrument there.
check_equal(providers.normalize_symbol("BTC_USDT.P"), "btc-usdt.p", "normalize_symbol leaves a bare .p suffix alone")
check_equal(providers.clean_result_symbol("<em>ZHIPU</em>USDT.P"), "zhipuusdt", "TradingView markup and .P are stripped")
check_equal(providers.format_price(45230), "45,230", "format_price groups thousands")
check_equal(providers.format_price(45230.4), "45,230", "format_price rounds above 1000")
check_equal(providers.format_price(12.5), "12.50", "format_price uses two decimals")
check_equal(providers.format_price(0.1234), "0.1234", "format_price uses four decimals below 1")
check_equal(providers.format_price(0.0000123), "0.000012", "format_price uses six decimals just above the scientific cut-off")
check_equal(providers.format_price(0.000000123), "1.23e-7", "format_price uses scientific notation below 1e-6")
check_equal(providers.format_price(0), "--", "format_price rejects a zero price")
check_equal(providers.format_change(5.5), "+5.50%", "format_change signs a rise")
check_equal(providers.format_change(-5.5), "-5.50%", "format_change keeps a fall negative")
check_equal(providers.price_color(true, false, true), "#39c38c", "green rises by default")
check_equal(providers.price_color(true, true, true), "#ff704b", "red rises when configured")
check_equal(providers.price_color(true, false, false), "#888888", "missing data uses the neutral colour")
-- An explicit dark flag must not change the v4 behaviour.
check_equal(providers.price_color(true, false, true, true), "#39c38c", "dark mode keeps the v4 green")
check_equal(providers.price_color(false, false, true, true), "#ff704b", "dark mode keeps the v4 red")
-- A light palette needs darker shades: the v4 pastels sit at ~1.1:1 on a light surface.
check_equal(providers.price_color(true, false, true, false), "#0a5c39", "light mode darkens the green")
check_equal(providers.price_color(false, false, true, false), "#9c2318", "light mode darkens the red")
check_equal(providers.price_color(true, true, true, false), "#9c2318", "light mode still honours red-rises")
check_equal(providers.price_color(false, true, true, false), "#0a5c39", "light mode still honours red-rises")
check_equal(providers.price_color(true, false, false, false), "#6a6a6a", "light mode darkens the neutral colour")
check(providers.price_color(true, false, true, false) ~= providers.price_color(true, false, true, true),
  "the two modes really do differ")

if failures > 0 then
  print("providers: " .. failures .. " check(s) failed")
  os.exit(1)
end

print("providers: on-demand symbol construction + verification + CoinGecko/TradingView search + formatting passed")
