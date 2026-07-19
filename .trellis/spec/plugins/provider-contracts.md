# Market Provider Contracts

This guide applies to `market-watch/MarketProviders.js` and its consumers in
`market-watch/Main.qml`, `Panel.qml`, and `Settings.qml`.

## Normalized Instrument

Provider adapters return records with a stable ID and the exact identifier
provided by the upstream service:

```js
{
  id: "huobi:perpetual:AAPL-USDT",
  provider: "huobi",
  marketType: "perpetual",
  exchangeSymbol: "AAPL-USDT",
  symbol: "aapl",
  displaySymbol: "AAPL",
  name: "AAPL",
  base: "AAPL",
  quote: "USDT",
  status: "online",
  logoUrl: ""
}
```

The ID format is `<provider>:<marketType>:<exact exchange identifier>`.
`exchangeSymbol` must never be rebuilt by appending a guessed suffix. Huobi
perpetual uses `contract_code`, Binance uses the exact `symbol`, OKX uses
`instId`, and CoinGecko uses its coin `id` in spot mode.

## Adapter Functions

Keep provider-specific branches inside the adapter module:

- `instrumentsUrl(provider, marketType)` returns the catalog endpoint.
- `parseInstruments(provider, marketType, response)` validates and normalizes
  upstream records, filters to supported USDT/live instruments, and de-duplicates IDs.
- `quoteUrl(provider, marketType, instrument)` constructs a request from
  `instrument.exchangeSymbol`.
- `parseQuote(provider, response, instrument)` returns normalized numeric
  `open`, `close`, `high`, `low`, and `volume`, or `null` for unusable data.

Consumers use the normalized return values. They must not read provider fields
such as `contract_code`, `instId`, or array indexes outside the adapter.

## Catalog And Watchlist Migration

Catalog indexes are keyed by ID and normalized symbol. Legacy string watchlists
may be read, but an exact catalog match is required before converting one to an
ID. Ambiguous or unavailable values remain visible as unavailable entries and
must not produce a quote URL. Saving after resolution writes schema version 2
IDs; provider changes temporarily retain unresolved strings until the new
catalog is ready.

The catalog cache records `provider`, `marketType`, `updatedAt`, and
`instruments`. Reject a cache for another provider or market. Do not replace a
valid cache with a short hard-coded list after a transient request failure.

## Quote Lifecycle

Quote state is keyed by instrument ID and uses `loading`, `ready`, `stale`, or
`error`. Deduplicate in-flight requests, bound concurrency, and attach a
generation to every callback. On failure, preserve the last successful value as
stale and record an error code/message. A provider or market change increments
the generation and discards old responses.

## Logos

Logo lookup is independent of quote success. Resolve instrument metadata first,
then stable data overrides, exact-match external metadata, a validated cached
file, and finally the text/emoji fallback. Keep bundled ZHIPU and MINIMAX files
in `market-watch/assets/` and key their overrides by
`huobi:perpetual:ZHIPU-USDT` and `huobi:perpetual:MINIMAX-USDT`, not by a bare
symbol.
