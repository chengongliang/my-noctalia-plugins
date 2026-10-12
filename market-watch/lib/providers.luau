--!nonstrict
-- Market providers - the v4 MarketProviders.js adapters, reworked for v5's
-- execution budget, plus the price/change formatting helpers v4 kept in Main.qml.
--
-- ── Why there is no bulk catalogue here ─────────────────────────────────────
-- v4 discovered every tradable instrument from the provider's catalogue endpoint
-- and resolved the watch list against it. That cannot work in v5:
--   * subprocess stdout captured through noctalia.runAsync is truncated at 1 MiB
--     (CommandResult.stdoutTruncated), and the Huobi spot catalogue is ~1.4 MB;
--   * a single callback is capped by a CPU budget, so json.decode of a ~1.4 MB
--     body fails even when the bytes arrive intact through noctalia.http.
-- So instruments are now built on demand from the bare symbol instead:
--
--   huobi  spot btc  -> btcusdt        perpetual BTC -> BTC-USDT
--   binance        btc -> BTCUSDT      (same symbol shape on spot and futures)
--   okx    spot BTC -> BTC-USDT        perpetual BTC -> BTC-USDT-SWAP
--   coingecko      -> the coin id, resolved through the small /search endpoint
--
-- These are exactly the shapes the v4 quote URLs already used. Availability is
-- discovered lazily: Binance and OKX expose a per-symbol instrument endpoint that
-- is small enough to decode, and for every provider the first quote is the final
-- word (an explicit provider error payload marks the instrument unavailable).
--
-- Everything here is pure: no host API, no clock, no I/O. The same file runs in
-- the shell's Luau VM and under `lua5.4 tests/providers_test.luau`, so it sticks
-- to Lua 5.4 syntax (no `+=`, no string interpolation, no if-then-else
-- expressions) and returns a table instead of defining globals.

local Providers = {}

-- ── Small coercions ─────────────────────────────────────────────────────────
-- JS String(value) semantics, minus the "[object Object]" case: a table is not a
-- usable string here, so it becomes "". Integers print without a trailing ".0".
local function to_string(value)
  if value == nil then
    return ""
  end
  local kind = type(value)
  if kind == "string" then
    return value
  end
  if kind == "number" then
    if value == math.floor(value) and math.abs(value) < 1e15 then
      return string.format("%d", value)
    end
    return tostring(value)
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  return ""
end
Providers.to_string = to_string

local function trim(value)
  return (to_string(value):gsub("^%s+", ""):gsub("%s+$", ""))
end
Providers.trim = trim

-- JS Number(value) restricted to numbers and numeric strings; NaN and the
-- infinities are rejected the way Number.isFinite does in the original.
local function to_number(value)
  local kind = type(value)
  if kind ~= "number" and kind ~= "string" then
    return nil
  end
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return number
end
Providers.to_number = to_number

-- encodeURIComponent: everything outside the unreserved set becomes %XX, one
-- escape per UTF-8 byte. `-` stays literal, which is what the quote URLs
-- (contract_code=AAPL-USDT) depend on.
local function url_encode(value)
  local text = to_string(value)
  local encoded = text:gsub("[^A-Za-z0-9%-%._~!*'()]", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
  return encoded
end
Providers.url_encode = url_encode

local function upper(value)
  return to_string(value):upper()
end

-- ── Symbols and instruments ─────────────────────────────────────────────────

-- Lower-cased bare base asset: "BTC_USDT.P" -> "btc-usdt", "BTC-USDT-SWAP" ->
-- "btc". Order matters, exactly as in v4: the perpetual markers are stripped
-- before the quote currency.
function Providers.normalize_symbol(value)
  local text = to_string(value):lower()
  text = trim(text)
  if text == "" then
    return ""
  end

  text = text:gsub("_", "-")
  text = text:gsub("%.perp$", "")
  text = text:gsub("%-swap$", "")
  text = text:gsub("%-usdt$", "")
  text = text:gsub("/usdt$", "")
  text = text:gsub("usdt$", "")
  text = text:gsub("%-+$", "")
  return text
end

function Providers.instrument_id(provider, market_type, exchange_symbol)
  return to_string(provider) .. ":" .. to_string(market_type) .. ":" .. to_string(exchange_symbol)
end

-- Returns nil when the instrument cannot be identified (empty symbol or no
-- exchange symbol), which callers use to skip the row.
function Providers.create_instrument(
  provider,
  market_type,
  exchange_symbol,
  symbol,
  name,
  base,
  quote,
  status,
  logo_url
)
  local normalized_symbol = Providers.normalize_symbol(symbol or base or exchange_symbol)
  local exact_symbol = to_string(exchange_symbol)
  if normalized_symbol == "" or exact_symbol == "" then
    return nil
  end

  return {
    id = Providers.instrument_id(provider, market_type, exact_symbol),
    provider = to_string(provider),
    market_type = to_string(market_type),
    exchange_symbol = exact_symbol,
    symbol = normalized_symbol,
    display_symbol = upper(symbol or base or normalized_symbol),
    name = to_string(name),
    base = upper(base or symbol or normalized_symbol),
    quote = upper(quote or "USDT"),
    status = to_string(status) ~= "" and to_string(status) or "online",
    logo_url = to_string(logo_url),
  }
end

-- The exchange symbol a provider expects for a bare base asset. v4 read these
-- straight out of the catalogue; v5 has to know them, which is what keeps the
-- quote URLs identical to the v4 ones.
function Providers.exchange_symbol(provider, market_type, base)
  local symbol = Providers.normalize_symbol(base)
  if symbol == "" then
    return ""
  end
  local bare = string.upper(symbol)
  if provider == "huobi" then
    if market_type == "perpetual" then
      return bare .. "-USDT"
    end
    return symbol .. "usdt"
  end
  if provider == "binance" then
    return bare .. "USDT"
  end
  if provider == "okx" then
    if market_type == "perpetual" then
      return bare .. "-USDT-SWAP"
    end
    return bare .. "-USDT"
  end
  return ""
end

-- Reverse of exchange_symbol for the providers whose shape is unambiguous.
function Providers.base_from_exchange_symbol(exchange_symbol)
  return Providers.normalize_symbol(exchange_symbol)
end

function Providers.quote_currency(provider)
  if provider == "coingecko" then
    return "USD"
  end
  return "USDT"
end

-- Build the on-demand instrument for a bare base asset. Status "constructed"
-- means "we built the symbol and have not confirmed it yet"; a provider error
-- payload or a missing per-symbol match flips it to "unresolved".
function Providers.construct_instrument(provider, market_type, base, name)
  local symbol = Providers.normalize_symbol(base)
  if symbol == "" then
    return nil
  end
  local exchange_symbol = Providers.exchange_symbol(provider, market_type, symbol)
  if exchange_symbol == "" then
    return nil
  end
  return Providers.create_instrument(
    provider,
    market_type,
    exchange_symbol,
    symbol,
    name or "",
    symbol,
    Providers.quote_currency(provider),
    "constructed",
    ""
  )
end

-- ── Per-symbol verification (Binance, OKX) ──────────────────────────────────
-- The only instrument endpoints small enough to decode on demand. Huobi has no
-- per-symbol filter (its spot catalogue is the 1.4 MB payload behind this
-- redesign) and CoinGecko resolves through /search, so both return "" here and
-- rely on the first quote instead.

function Providers.verification_url(provider, market_type, exchange_symbol)
  local symbol = url_encode(exchange_symbol)
  if symbol == "" then
    return ""
  end
  if provider == "binance" then
    if market_type == "perpetual" then
      return "https://fapi.binance.com/fapi/v1/exchangeInfo?symbol=" .. symbol
    end
    return "https://api.binance.com/api/v3/exchangeInfo?symbol=" .. symbol
  end
  if provider == "okx" then
    local inst_type = market_type == "perpetual" and "SWAP" or "SPOT"
    return "https://www.okx.com/api/v5/public/instruments?instType=" .. inst_type .. "&instId=" .. symbol
  end
  return ""
end

-- Parser for the two per-symbol endpoints above. Both answer with the same shape
-- as their bulk catalogue, so the v4 field mappings survive unchanged; a symbol
-- that does not exist comes back as a provider error payload and yields {}.
function Providers.parse_verification(provider, market_type, response)
  local result = {}
  if type(response) ~= "table" then
    return result
  end

  local function append(instrument)
    if instrument ~= nil then
      table.insert(result, instrument)
    end
  end

  if provider == "binance" and type(response.symbols) == "table" then
    for _, item in ipairs(response.symbols) do
      if type(item) == "table" and item.quoteAsset == "USDT" and item.status == "TRADING" then
        append(Providers.create_instrument(
          provider,
          market_type,
          item.symbol,
          item.baseAsset,
          item.baseAsset,
          item.baseAsset,
          item.quoteAsset,
          item.status,
          ""
        ))
      end
    end
  elseif provider == "okx" and response.code == "0" and type(response.data) == "table" then
    for _, item in ipairs(response.data) do
      if type(item) == "table" then
        local inst_id = to_string(item.instId)
        local quote_ok = item.quoteCcy == "USDT"
          or item.settleCcy == "USDT"
          or inst_id:find("-USDT", 1, true) ~= nil
        local state_ok = item.state == "live" or item.state == nil
        if quote_ok and state_ok then
          local base = item.baseCcy or (inst_id:match("^([^%-]+)") or inst_id)
          append(Providers.create_instrument(
            provider,
            market_type,
            item.instId,
            base,
            item.instId,
            base,
            item.quoteCcy or item.settleCcy,
            item.state,
            ""
          ))
        end
      end
    end
  end

  return result
end

-- True when the payload is an explicit provider error (unknown symbol, bad
-- parameter, rate limit). Distinguishing it from garbage lets the service mark an
-- instrument unavailable instead of retrying a symbol the exchange does not have.
function Providers.parse_error(provider, response)
  if type(response) ~= "table" then
    return false
  end
  if provider == "huobi" then
    return response.status == "error" or response["err-code"] ~= nil
  end
  if provider == "binance" then
    local code = response.code
    return type(code) == "number" and code < 0
  end
  if provider == "okx" then
    local code = response.code
    return code ~= nil and to_string(code) ~= "0"
  end
  if provider == "coingecko" then
    -- Two shapes: {"status": {"error_code": ..., "error_message": ...}} and the
    -- shorter {"error": "..."} some endpoints use.
    return response.error ~= nil
      or (type(response.status) == "table" and response.status.error_code ~= nil)
  end
  return false
end

-- ── Quotes ──────────────────────────────────────────────────────────────────
-- One 1-day candle per request: open is the 24h reference the change is computed
-- against, so a single call per instrument covers price, change and high/low.

function Providers.quote_url(provider, market_type, instrument)
  if instrument == nil then
    return ""
  end
  local symbol = url_encode(instrument.exchange_symbol)

  if provider == "huobi" then
    if market_type == "perpetual" then
      return "https://api.hbdm.com/linear-swap-ex/market/history/kline?period=1day&size=1&contract_code=" .. symbol
    end
    return "https://api.huobi.pro/market/history/kline?period=1day&size=1&symbol=" .. symbol
  end
  if provider == "binance" then
    if market_type == "perpetual" then
      return "https://fapi.binance.com/fapi/v1/klines?symbol=" .. symbol .. "&interval=1d&limit=1"
    end
    return "https://api.binance.com/api/v3/klines?symbol=" .. symbol .. "&interval=1d&limit=1"
  end
  if provider == "okx" then
    return "https://www.okx.com/api/v5/market/candles?instId=" .. symbol .. "&bar=1D&limit=1"
  end
  if provider == "coingecko" then
    return "https://api.coingecko.com/api/v3/simple/price?ids="
      .. symbol
      .. "&vs_currencies=usd&include_24hr_change=true&include_24hr_vol=true&include_24hr_high_low=true"
  end
  return ""
end

-- Returns { open, close, high, low, volume } or nil. A missing numeric field is
-- left out of the table (v4 carried NaN instead); the caller treats either as an
-- unusable quote.
function Providers.parse_quote(provider, response, instrument)
  if type(response) ~= "table" then
    return nil
  end

  if provider == "huobi" then
    if response.status ~= "ok" or type(response.data) ~= "table" or #response.data == 0 then
      return nil
    end
    local kline = response.data[1]
    if type(kline) ~= "table" then
      return nil
    end
    return {
      open = to_number(kline.open),
      close = to_number(kline.close),
      high = to_number(kline.high),
      low = to_number(kline.low),
      volume = to_number(kline.vol),
    }
  end

  if provider == "binance" then
    -- Raw kline arrays: [ openTime, open, high, low, close, volume, ... ].
    if type(response) ~= "table" or response[1] == nil then
      return nil
    end
    local kline = response[1]
    if type(kline) ~= "table" then
      return nil
    end
    return {
      open = to_number(kline[2]),
      close = to_number(kline[5]),
      high = to_number(kline[3]),
      low = to_number(kline[4]),
      volume = to_number(kline[6]),
    }
  end

  if provider == "okx" then
    if response.code ~= "0" or type(response.data) ~= "table" or #response.data == 0 then
      return nil
    end
    local kline = response.data[1]
    if type(kline) ~= "table" then
      return nil
    end
    return {
      open = to_number(kline[2]),
      close = to_number(kline[5]),
      high = to_number(kline[3]),
      low = to_number(kline[4]),
      volume = to_number(kline[6]),
    }
  end

  if provider == "coingecko" and instrument ~= nil then
    local data = response[instrument.exchange_symbol]
    if type(data) ~= "table" or data.usd == nil then
      return nil
    end
    local current_price = to_number(data.usd)
    if current_price == nil then
      return nil
    end
    local change = to_number(data.usd_24h_change) or 0
    -- CoinGecko has no candle: the 24h open is derived from the current price and
    -- the reported 24h change, so downstream change/high/low maths is unchanged.
    return {
      open = current_price / (1 + change / 100),
      close = current_price,
      high = to_number(data.usd_24h_high) or current_price,
      low = to_number(data.usd_24h_low) or current_price,
      volume = to_number(data.usd_24h_vol) or 0,
    }
  end

  return nil
end

-- ── Search candidates ───────────────────────────────────────────────────────
-- The add-symbol search is answered from two small endpoints instead of a bulk
-- catalogue: CoinGecko's /search for coin ids, and TradingView's symbol search for
-- exchange-listed symbols (which is also the only way to reach tokenized-stock
-- perpetuals such as HTX "ZHIPUUSDT.P"). The TradingView call is the same one the
-- logo fallback uses; the endpoint requires an
-- "Origin: https://www.tradingview.com" header.

function Providers.trading_view_search_url(query)
  local text = trim(query)
  if text == "" then
    return ""
  end
  return "https://symbol-search.tradingview.com/symbol_search/v3/?text="
    .. url_encode(text)
    .. "&lang=en&domain=production"
end

function Providers.coingecko_search_url(query)
  local text = trim(query)
  if text == "" then
    return ""
  end
  return "https://api.coingecko.com/api/v3/search?query=" .. url_encode(text)
end

-- Result symbols carry <em> highlight markup and exchange suffixes such as
-- "ZHIPUUSDT.P" (perpetual). Strip the markup and the ".p"/".perp" suffix, then
-- reuse normalize_symbol so quote-currency handling matches instrument symbols.
local function clean_result_symbol(value)
  local cleaned = to_string(value)
  cleaned = cleaned:gsub("</?em>", ""):lower()
  cleaned = cleaned:gsub("%.perp$", "")
  cleaned = cleaned:gsub("%.p$", "")
  return cleaned
end
Providers.clean_result_symbol = clean_result_symbol

local TV_EXCHANGES = { HTX = "huobi", HUOBI = "huobi", BINANCE = "binance", OKX = "okx" }
-- TradingView's instrument types that map onto this plugin's market types.
local TV_MARKET_TYPES = { swap = "perpetual", spot = "spot" }

-- Map TradingView search rows onto instruments for one provider and market type.
-- Rows for other exchanges (HKEX, NASDAQ spot tickers), other types (index, fund)
-- and the "*.P_PREMIUM" index are dropped: they are not tradable on our provider.
function Providers.parse_trading_view_candidates(response, provider, market_type)
  local results = {}
  local seen = {}
  if type(response) ~= "table" or type(response.symbols) ~= "table" then
    return results
  end

  for _, item in ipairs(response.symbols) do
    if type(item) == "table" then
      local mapped = TV_EXCHANGES[string.upper(to_string(item.exchange))]
      local wanted_market = TV_MARKET_TYPES[string.lower(to_string(item.type))]
      if mapped == provider and wanted_market == market_type then
        local base = Providers.normalize_symbol(clean_result_symbol(item.symbol))
        local instrument = Providers.construct_instrument(provider, market_type, base, to_string(item.description))
        if instrument ~= nil and not seen[instrument.id] then
          seen[instrument.id] = true
          table.insert(results, instrument)
        end
      end
    end
  end
  return results
end

function Providers.parse_coingecko_candidates(response)
  local results = {}
  if type(response) ~= "table" or type(response.coins) ~= "table" then
    return results
  end
  for _, item in ipairs(response.coins) do
    if type(item) == "table" then
      local instrument = Providers.create_instrument(
        "coingecko",
        "spot",
        item.id,
        item.symbol,
        item.name,
        item.symbol,
        "USD",
        "constructed",
        ""
      )
      if instrument ~= nil then
        table.insert(results, instrument)
      end
    end
  end
  return results
end

-- Pick the coin a bare symbol refers to. An exact coin id wins (a user can paste
-- "bitcoin"), otherwise the first exact-symbol match: /search is relevance ranked
-- by market cap, whereas v4 could afford the stricter "unique in the whole
-- catalogue" rule that on-demand search cannot reproduce.
function Providers.pick_coingecko_candidate(candidates, reference)
  if type(candidates) ~= "table" then
    return nil
  end
  local wanted = string.lower(trim(reference))
  if wanted == "" then
    return nil
  end

  for _, candidate in ipairs(candidates) do
    if string.lower(candidate.exchange_symbol) == wanted then
      return candidate
    end
  end

  local normalized = Providers.normalize_symbol(wanted)
  for _, candidate in ipairs(candidates) do
    if candidate.symbol == normalized then
      return candidate
    end
  end
  return nil
end

-- ── TradingView logo fallback ───────────────────────────────────────────────
-- Used only as a last resort for instruments the provider metadata and the
-- CoinGecko lookup cannot name (tokenized-stock perpetuals). Same unfiltered
-- search as above; the "*.P_PREMIUM" index rows never win because they have no
-- logoid and normalize differently.

function Providers.parse_trading_view_logo_id(response, instrument)
  if type(response) ~= "table" or type(response.symbols) ~= "table" or instrument == nil then
    return ""
  end

  -- instrument.symbol is already normalized (e.g. "zhipu"); fall back to
  -- normalizing base/display_symbol for partially populated objects.
  local target = to_string(instrument.symbol):lower()
  if target == "" then
    target = Providers.normalize_symbol(instrument.base or instrument.display_symbol or "")
  end
  if target == "" then
    return ""
  end

  for _, item in ipairs(response.symbols) do
    if type(item) == "table" then
      if Providers.normalize_symbol(clean_result_symbol(item.symbol)) == target then
        local logoid = to_string(item.logoid)
        if logoid ~= "" then
          return logoid
        end
      end
    end
  end
  return ""
end

function Providers.trading_view_logo_url(logoid)
  local id = trim(logoid)
  if id == "" then
    return ""
  end
  return "https://s3-symbol-logo.tradingview.com/" .. url_encode(id) .. "--big.svg"
end

-- ── Display formatting (v4 kept these in Main.qml) ──────────────────────────
-- They live here so the service, the bar widget and the panel can share one
-- implementation instead of three copies.

-- Region-aware thousands separator without relying on a locale.
local function group_thousands(text)
  local sign = ""
  local digits = text
  if digits:sub(1, 1) == "-" then
    sign = "-"
    digits = digits:sub(2)
  end
  local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  grouped = grouped:gsub("^,", "")
  return sign .. grouped
end

function Providers.format_price(price)
  local value = to_number(price)
  if value == nil or value <= 0 then
    return "--"
  end
  if value >= 1000 then
    return group_thousands(string.format("%.0f", value))
  end
  if value >= 1 then
    return string.format("%.2f", value)
  end
  if value >= 0.01 then
    return string.format("%.4f", value)
  end
  if value < 0.000001 then
    -- JS toExponential(2) writes "1.23e-7"; C's %e pads the exponent to two
    -- digits, so trim the padding to keep the display identical.
    local formatted = string.format("%.2e", value)
    return (formatted:gsub("e([+-])0*(%d+)", "e%1%2"))
  end
  return string.format("%.6f", value)
end

function Providers.format_change(change)
  local value = to_number(change)
  if value == nil then
    return "--"
  end
  local sign = value >= 0 and "+" or ""
  return sign .. string.format("%.2f", value) .. "%"
end

-- Rise/fall colours. ui colours accept plain hex, so the v4 palette survives even
-- though barWidget.setColor only takes a palette role.
--
-- v4 picked its two shades against a dark panel, and both are light pastels: on a light
-- surface #39c38c lands at barely 1.1:1, so the figures look washed out and the columns
-- become hard to read. The same two hues are kept, with a darker shade selected when the
-- palette Noctalia renders with is light. Callers pass noctalia.isDarkMode(); omitting it
-- keeps the v4 dark values, so existing callers and the unit tests are unaffected.
local RISE_DARK, RISE_LIGHT = "#39c38c", "#0a5c39"
local FALL_DARK, FALL_LIGHT = "#ff704b", "#9c2318"
local FLAT_DARK, FLAT_LIGHT = "#888888", "#6a6a6a"

function Providers.price_color(is_rising, red_rises, has_data, dark)
  local rise, fall, flat = RISE_LIGHT, FALL_LIGHT, FLAT_LIGHT
  if dark ~= false then
    rise, fall, flat = RISE_DARK, FALL_DARK, FLAT_DARK
  end
  if has_data ~= true then
    return flat
  end
  if red_rises == true then
    -- Chinese convention: red rises, green falls.
    return is_rising == true and fall or rise
  end
  return is_rising == true and rise or fall
end

return Providers
