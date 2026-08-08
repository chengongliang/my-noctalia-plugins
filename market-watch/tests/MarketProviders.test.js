const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const sourcePath = path.join(__dirname, "..", "MarketProviders.js");
const source = fs.readFileSync(sourcePath, "utf8") + `
this.api = { normalizeSymbol, instrumentId, createInstrument, instrumentsUrl, parseInstruments, quoteUrl, parseQuote, tradingViewSearchUrl, parseTradingViewLogoId, tradingViewLogoUrl };
`;
const context = {};
vm.runInNewContext(source, context, { filename: sourcePath });
const api = context.api;

function fixture(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8"));
}

function findById(instruments, id) {
  return instruments.find(instrument => instrument.id === id);
}

const huobi = api.parseInstruments("huobi", "perpetual", fixture("huobi-perpetual.json"));
assert(findById(huobi, "huobi:perpetual:AAPL-USDT"));
assert(findById(huobi, "huobi:perpetual:ACME-USDT"));
assert(findById(huobi, "huobi:perpetual:NEWMK-USDT"));
assert(!huobi.some(instrument => instrument.id.includes("APPL-USDT")));
const aapl = findById(huobi, "huobi:perpetual:AAPL-USDT");
assert.strictEqual(api.quoteUrl("huobi", "perpetual", aapl).includes("contract_code=AAPL-USDT"), true);
assert.deepStrictEqual(JSON.parse(JSON.stringify(api.parseQuote("huobi", fixture("huobi-quote.json"), aapl))), {
  open: 100,
  close: 105,
  high: 110,
  low: 98,
  volume: 1234
});

const binance = api.parseInstruments("binance", "spot", fixture("binance-spot.json"));
assert.strictEqual(binance.length, 1);
assert.strictEqual(binance[0].id, "binance:spot:BTCUSDT");
assert.strictEqual(api.quoteUrl("binance", "spot", binance[0]).includes("symbol=BTCUSDT"), true);
assert.strictEqual(api.parseQuote("binance", fixture("binance-quote.json"), binance[0]).close, 105);

const okx = api.parseInstruments("okx", "perpetual", fixture("okx-perpetual.json"));
assert.strictEqual(okx.length, 1);
assert.strictEqual(okx[0].id, "okx:perpetual:BTC-USDT-SWAP");
assert.strictEqual(api.quoteUrl("okx", "perpetual", okx[0]).includes("instId=BTC-USDT-SWAP"), true);
assert.strictEqual(api.parseQuote("okx", fixture("okx-quote.json"), okx[0]).close, 105);

const coingecko = api.parseInstruments("coingecko", "spot", fixture("coingecko-spot.json"));
assert.strictEqual(coingecko.length, 2);
assert.strictEqual(coingecko[0].id, "coingecko:spot:bitcoin");
assert.strictEqual(api.quoteUrl("coingecko", "spot", coingecko[0]).includes("ids=bitcoin"), true);
assert.strictEqual(api.parseQuote("coingecko", fixture("coingecko-quote.json"), coingecko[0]).close, 105);

assert.strictEqual(api.parseQuote("binance", { code: -1121 }, binance[0]), null);

// TradingView logo fallback helpers (unfiltered symbol search; HTX/OKX list
// tokenized-stock perpetuals as "<BASE>USDT.P", stock exchanges list tickers
// such as HKEX "100" that must never match the base symbol).
const tvFixture = fixture("tradingview-search.json");
const zhipu = { id: "huobi:perpetual:ZHIPU-USDT", base: "ZHIPU", displaySymbol: "ZHIPU", symbol: "zhipu" };
const minimax = { id: "huobi:perpetual:MINIMAX-USDT", base: "MINIMAX", displaySymbol: "MINIMAX", symbol: "minimax" };
const tvUrl = api.tradingViewSearchUrl(zhipu);
assert(tvUrl.includes("symbol-search.tradingview.com/symbol_search/v3/"));
assert(tvUrl.includes("text=ZHIPU"));
assert(tvUrl.includes("lang=en"));
assert(tvUrl.includes("domain=production"));
assert(!tvUrl.includes("search_type"));
assert.strictEqual(api.parseTradingViewLogoId(tvFixture, zhipu), "knowledge-atlas-technology-joint-stock-company-limited-class-h");
assert.strictEqual(api.parseTradingViewLogoId(tvFixture, minimax), "minimax");
assert.strictEqual(api.parseTradingViewLogoId(tvFixture, { base: "APPL", displaySymbol: "APPL", symbol: "appl" }), "");
assert.strictEqual(api.parseTradingViewLogoId({ symbols: [] }, zhipu), "");
assert.strictEqual(api.parseTradingViewLogoId(null, zhipu), "");
assert.strictEqual(api.tradingViewLogoUrl("minimax"), "https://s3-symbol-logo.tradingview.com/minimax--big.svg");
assert.strictEqual(api.tradingViewLogoUrl(""), "");
console.log("MarketProviders fixtures: 4 providers + TradingView logo fallback passed");
