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

### 1. Scope / Trigger

Apply this contract whenever catalog metadata, logo lookup, cache behavior, or
the panel fallback changes. Logo lookup is independent of quote success and
must work for any normalized instrument without a code change.

### 2. Signatures

- `requestLogo(reference)` starts best-effort resolution for a normalized ID.
- `getLogoCacheKey(reference)` derives a filesystem-safe key from the full ID.
- `getLogoPath(reference)` returns a validated cached path or an empty string.
- `getCoinIcon(reference)` returns a short label derived from `symbol`.

### 3. Contracts

Resolution order is `instrument.logoUrl`, exact external metadata, validated
cache keyed by stable instrument identity, then text fallback. External matches
must use an exact provider ID or one unique normalized symbol match. Downloads
go to a temporary file and are accepted only when non-empty with an `image/*`
MIME type. Do not add symbol-specific URLs, names, glyphs, or bundled-file
branches.

### 4. Validation & Error Matrix

| Condition | Result |
| --- | --- |
| Provider logo succeeds | Cache by full instrument ID and render it |
| Provider logo fails | Continue to exact external lookup |
| External match is missing or ambiguous | Record retry time and render text |
| Download is empty or not an image | Reject it and render text |
| Quote request fails | Leave logo resolution unchanged |

### 5. Good / Base / Bad Cases

- Good: a catalog record has `logoUrl`; the validated file is cached under its
  provider, market, and exact exchange identity.
- Base: metadata has no logo; one exact external symbol match is cached.
- Bad: several external results share a symbol; none is guessed and the panel
  renders the normalized symbol abbreviation.

### 6. Tests Required

- Assert cache keys differ for the same symbol across provider or market IDs.
- Exercise metadata success, exact external success, ambiguous miss, invalid
  MIME, cached hit, and quote failure while the logo remains available.
- Search runtime code and docs for symbol-specific logo maps before release.

### 7. Wrong vs Correct

```js
// Wrong: every newly listed instrument requires another branch.
const logoUrl = symbol === "example" ? "https://vendor/logo.png" : "";

// Correct: consume normalized metadata and fall back generically.
const logoUrl = instrument.logoUrl || exactExternalMatch(instrument);
const fallback = instrument.symbol.slice(0, 2).toUpperCase();
```
