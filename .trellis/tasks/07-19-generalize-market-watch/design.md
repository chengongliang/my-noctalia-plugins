# Technical Design: Provider-Driven Market Watch

## Boundaries

`Main.qml` currently owns settings normalization, provider URLs/parsers, catalog discovery, quote polling, logo lookup, and shared state. The refactor should keep `pluginApi.mainInstance` as the shared-state boundary while moving provider-specific rules behind a small adapter contract. UI components should consume normalized instruments and quote/logo state, not provider response fields.

Suggested modules:

- `MarketProvider.js`: provider registry and common adapter contract.
- `InstrumentCatalog.js`: normalized instrument records, lookup indexes, migration, and catalog cache serialization.
- `QuoteScheduler.js`: per-instrument request lifecycle, deduplication, generation checks, retry/backoff, and stale state.
- `LogoResolver.js`: provider/asset metadata resolution and cache handling.
- `Main.qml`: plugin settings, lifecycle wiring, shared properties, IPC, and calls into the modules.

Do not split modules solely for file size. Each module must own one cross-layer contract so Panel.qml and Settings.qml do not reparse untyped provider payloads.

## Normalized Instrument Contract

```js
{
  id: "huobi:perpetual:ACME-USDT",
  provider: "huobi",
  marketType: "perpetual",
  exchangeSymbol: "ACME-USDT",
  symbol: "acme",
  displaySymbol: "ACME",
  name: "ACME",
  base: "ACME",
  quote: "USDT",
  status: "online",
  logoUrl: ""
}
```

The `id` is the persisted watchlist identity. `exchangeSymbol` is never reconstructed by shared code. Optional metadata remains nullable and must not prevent quote display.

## Provider Contract

Each adapter exposes:

```js
{
  key,
  supportsMarketType(type),
  instrumentsUrl(type),
  parseInstruments(response, type),
  quoteRequest(instrument, type),
  parseQuote(response, instrument, type)
}
```

`parseInstruments` returns normalized records and preserves provider-specific identifiers. Huobi perpetual records should use `contract_code`; Binance records should use the exact symbol; OKX records should use `instId`; CoinGecko remains an ID-based spot provider.

The migration order is Huobi, Binance, OKX, then CoinGecko. Each adapter is switched only after its discovery and quote fixtures pass; shared interfaces must not contain branches that exist solely for the provider currently being migrated.

## Data Flow

```text
provider response
  -> adapter parser
  -> normalized InstrumentCatalog
  -> persisted watchlist IDs / Settings search
  -> QuoteScheduler request(instrument)
  -> normalized QuoteState
  -> Panel and BarWidget rendering

instrument metadata + logo overrides
  -> LogoResolver
  -> cached local path or fallback glyph
  -> Panel rendering
```

Provider and market changes increment a catalog/request generation. Every asynchronous catalog, quote, and logo callback checks that generation before updating shared state.

## Migration and Persistence

Accept both legacy strings and new instrument IDs while reading settings. Resolve a legacy string by normalized symbol against the current catalog, preferring an exact provider instrument. If multiple instruments match, mark the entry ambiguous and require selection in Settings. Save only IDs after the user saves settings. Store a schema version alongside the new watchlist format.

Persist the latest successful catalog per `provider + marketType` with a timestamp under the existing Noctalia cache area. Use it only as an offline discovery fallback and never treat a stale catalog as proof that an instrument is currently tradable.

## Quote Scheduling

Maintain one state per instrument: `loading`, `ready`, `stale`, or `error`, with `updatedAt`, `lastQuote`, `errorCode`, and `requestGeneration`. Deduplicate requests by instrument ID, cap concurrent requests, and use bounded exponential retry for transient failures. A failed refresh keeps the last quote and marks it stale. Provider or market changes clear active states and invalidate old callbacks.

## Logo Resolution

Resolve in this order:

1. `instrument.logoUrl` from provider metadata.
2. Exact-match external metadata lookup appropriate to the asset category.
3. Cached local file keyed by stable instrument/provider identity.
4. Text fallback derived from the normalized symbol.

Download to a temporary path, validate a non-empty supported image, then atomically move it into a cache key based on the instrument ID. Logo resolution must not contain symbol-specific URLs, names, glyphs, or bundled-file branches.

## Trade-offs

- Persisting stable IDs prevents invalid symbols but requires migration and unavailable-state UI.
- Catalog caching improves offline behavior but must expose staleness to avoid implying live availability.
- A bounded scheduler is more complex than one Timer loop, but avoids request storms and stale response races.
- Provider metadata is preferred for logos; external lookup remains best-effort because many contracts have no logo API.

## Rollback

Keep legacy string parsing and the existing settings shape readable until the new identity format has survived at least one save/restart cycle. Provider adapters can be switched back to the existing URL/parser implementation behind the same contract if a provider fixture fails. Do not delete old cache files during migration.
