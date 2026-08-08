function normalizeSymbol(value) {
  let text = String(value || "").trim().toLowerCase();
  if (text === "") return "";

  return text
    .replace(/_/g, "-")
    .replace(/\.perp$/i, "")
    .replace(/-swap$/i, "")
    .replace(/-usdt$/i, "")
    .replace(/\/usdt$/i, "")
    .replace(/usdt$/i, "")
    .replace(/-+$/g, "");
}

function instrumentId(provider, marketType, exchangeSymbol) {
  return String(provider) + ":" + String(marketType) + ":" + String(exchangeSymbol);
}

function createInstrument(provider, marketType, exchangeSymbol, symbol, name, base, quote, status, logoUrl) {
  const normalizedSymbol = normalizeSymbol(symbol || base || exchangeSymbol);
  const exactSymbol = String(exchangeSymbol || "");
  if (normalizedSymbol === "" || exactSymbol === "") return null;

  return {
    id: instrumentId(provider, marketType, exactSymbol),
    provider: provider,
    marketType: marketType,
    exchangeSymbol: exactSymbol,
    symbol: normalizedSymbol,
    displaySymbol: String(symbol || base || normalizedSymbol).toUpperCase(),
    name: String(name || ""),
    base: String(base || symbol || normalizedSymbol).toUpperCase(),
    quote: String(quote || "USDT").toUpperCase(),
    status: String(status || "online"),
    logoUrl: String(logoUrl || "")
  };
}

function instrumentsUrl(provider, marketType) {
  if (provider === "huobi") {
    return marketType === "perpetual"
      ? "https://api.hbdm.com/linear-swap-api/v1/swap_contract_info"
      : "https://api.huobi.pro/v1/common/symbols";
  }
  if (provider === "binance") {
    return marketType === "perpetual"
      ? "https://fapi.binance.com/fapi/v1/exchangeInfo"
      : "https://api.binance.com/api/v3/exchangeInfo";
  }
  if (provider === "okx") {
    return marketType === "perpetual"
      ? "https://www.okx.com/api/v5/public/instruments?instType=SWAP"
      : "https://www.okx.com/api/v5/public/instruments?instType=SPOT";
  }
  if (provider === "coingecko") {
    return "https://api.coingecko.com/api/v3/coins/list?include_platform=false";
  }
  return "";
}

function parseInstruments(provider, marketType, response) {
  const result = [];
  const seen = {};
  const append = function(instrument) {
    if (!instrument || seen[instrument.id]) return;
    seen[instrument.id] = true;
    result.push(instrument);
  };

  if (provider === "huobi" && marketType === "perpetual" && response.status === "ok" && Array.isArray(response.data)) {
    response.data
      .filter(item => item.contract_status === 1 || item.contract_status === "1" || item.contract_status === undefined)
      .forEach(item => append(createInstrument(
        provider,
        marketType,
        item.contract_code,
        item.symbol,
        item.contract_name || item.symbol,
        item.symbol,
        item.contract_code && String(item.contract_code).split("-").pop(),
        "online",
        ""
      )));
  } else if (provider === "huobi" && response.status === "ok" && Array.isArray(response.data)) {
    response.data
      .filter(item => item["quote-currency"] === "usdt" && item.state === "online")
      .forEach(item => append(createInstrument(
        provider,
        marketType,
        item.symbol,
        item["base-currency"],
        item["base-currency"],
        item["base-currency"],
        item["quote-currency"],
        item.state,
        ""
      )));
  } else if (provider === "binance" && Array.isArray(response.symbols)) {
    response.symbols
      .filter(item => item.quoteAsset === "USDT" && item.status === "TRADING")
      .forEach(item => append(createInstrument(
        provider,
        marketType,
        item.symbol,
        item.baseAsset,
        item.baseAsset,
        item.baseAsset,
        item.quoteAsset,
        item.status,
        ""
      )));
  } else if (provider === "okx" && response.code === "0" && Array.isArray(response.data)) {
    response.data
      .filter(item => item.quoteCcy === "USDT" || item.settleCcy === "USDT" || String(item.instId || "").indexOf("-USDT") !== -1)
      .filter(item => item.state === "live" || item.state === undefined)
      .forEach(item => append(createInstrument(
        provider,
        marketType,
        item.instId,
        item.baseCcy || String(item.instId || "").split("-")[0],
        item.instId,
        item.baseCcy || String(item.instId || "").split("-")[0],
        item.quoteCcy || item.settleCcy,
        item.state,
        ""
      )));
  } else if (provider === "coingecko" && Array.isArray(response)) {
    response.forEach(item => append(createInstrument(
      provider,
      "spot",
      item.id,
      item.symbol,
      item.name,
      item.symbol,
      "USD",
      "online",
      ""
    )));
  }

  return result;
}

// TradingView symbol search is used as a stock-logo fallback when neither
// provider metadata nor the crypto (CoinGecko) lookup yields a logo.
// The search is deliberately unfiltered (no search_type): tokenized-stock
// perpetuals such as HTX "ZHIPUUSDT.P" only appear in unfiltered results,
// while "search_type=stocks" either drops them or returns exchange tickers
// (e.g. HKEX "100") that never equal the instrument base symbol.
// The endpoint requires an "Origin: https://www.tradingview.com" header.
function tradingViewSearchUrl(instrument) {
  const text = String((instrument && (instrument.base || instrument.displaySymbol || instrument.symbol)) || "").trim();
  if (text === "") return "";
  return "https://symbol-search.tradingview.com/symbol_search/v3/?text=" + encodeURIComponent(text)
    + "&lang=en&domain=production";
}

function parseTradingViewLogoId(response, instrument) {
  if (!response || !Array.isArray(response.symbols) || !instrument) return "";
  // instrument.symbol is already normalized (e.g. "zhipu"); fall back to
  // normalizing base/displaySymbol for partially populated objects.
  const target = String(instrument.symbol || "").trim().toLowerCase()
    || normalizeSymbol(instrument.base || instrument.displaySymbol || "");
  if (target === "") return "";
  // Result symbols can contain <em> highlight markup and exchange suffixes
  // such as "ZHIPUUSDT.P" (perpetual). Strip the markup and the ".p"/".perp"
  // suffix, then reuse normalizeSymbol so quote-currency suffixes match the
  // same rules as instrument symbols. Rows without a logoid (for example
  // "*.P_PREMIUM" indexes, which also normalize differently) never win.
  const match = response.symbols.find(function(item) {
    const cleaned = String(item.symbol || "")
      .replace(/<\/?em>/g, "")
      .toLowerCase()
      .replace(/\.perp$/, "")
      .replace(/\.p$/, "");
    return normalizeSymbol(cleaned) === target && item.logoid;
  });
  return match ? String(match.logoid) : "";
}

function tradingViewLogoUrl(logoid) {
  const id = String(logoid || "").trim();
  if (id === "") return "";
  return "https://s3-symbol-logo.tradingview.com/" + encodeURIComponent(id) + "--big.svg";
}

function quoteUrl(provider, marketType, instrument) {
  if (!instrument) return "";
  const symbol = encodeURIComponent(instrument.exchangeSymbol);

  if (provider === "huobi") {
    return marketType === "perpetual"
      ? "https://api.hbdm.com/linear-swap-ex/market/history/kline?period=1day&size=1&contract_code=" + symbol
      : "https://api.huobi.pro/market/history/kline?period=1day&size=1&symbol=" + symbol;
  }
  if (provider === "binance") {
    return marketType === "perpetual"
      ? "https://fapi.binance.com/fapi/v1/klines?symbol=" + symbol + "&interval=1d&limit=1"
      : "https://api.binance.com/api/v3/klines?symbol=" + symbol + "&interval=1d&limit=1";
  }
  if (provider === "okx") {
    return "https://www.okx.com/api/v5/market/candles?instId=" + symbol + "&bar=1D&limit=1";
  }
  if (provider === "coingecko") {
    return "https://api.coingecko.com/api/v3/simple/price?ids=" + symbol
      + "&vs_currencies=usd&include_24hr_change=true&include_24hr_vol=true&include_24hr_high_low=true";
  }
  return "";
}

function parseQuote(provider, response, instrument) {
  if (provider === "huobi") {
    if (response.status !== "ok" || !Array.isArray(response.data) || response.data.length === 0) return null;
    const kline = response.data[0];
    return {
      open: Number(kline.open),
      close: Number(kline.close),
      high: Number(kline.high),
      low: Number(kline.low),
      volume: Number(kline.vol)
    };
  }

  if (provider === "binance") {
    if (!Array.isArray(response) || response.length === 0) return null;
    const kline = response[0];
    return {
      open: Number(kline[1]),
      close: Number(kline[4]),
      high: Number(kline[2]),
      low: Number(kline[3]),
      volume: Number(kline[5])
    };
  }

  if (provider === "okx") {
    if (response.code !== "0" || !Array.isArray(response.data) || response.data.length === 0) return null;
    const kline = response.data[0];
    return {
      open: Number(kline[1]),
      close: Number(kline[4]),
      high: Number(kline[2]),
      low: Number(kline[3]),
      volume: Number(kline[5])
    };
  }

  if (provider === "coingecko" && instrument) {
    const data = response[instrument.exchangeSymbol];
    if (!data || !data.usd) return null;
    const currentPrice = Number(data.usd);
    const change = Number(data.usd_24h_change || 0);
    return {
      open: currentPrice / (1 + change / 100),
      close: currentPrice,
      high: Number(data.usd_24h_high || currentPrice),
      low: Number(data.usd_24h_low || currentPrice),
      volume: Number(data.usd_24h_vol || 0)
    };
  }

  return null;
}
