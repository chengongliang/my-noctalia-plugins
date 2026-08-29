# Implementation Plan

## 1. Baseline and fixtures

- Capture current settings and behavior for Huobi spot/perpetual, Binance, OKX, and CoinGecko.
- Add representative response fixtures for instrument discovery and one valid/invalid quote per provider.
- Record legacy string watchlist migration cases, including common crypto, an exact exchange-listed instrument, and an unavailable symbol.

Validation: JSON parsing of all fixtures; reproduce that Huobi returns `AAPL-USDT` while `APPL-USDT` is invalid.

## 2. Instrument and provider contracts

- Add the normalized instrument contract and catalog indexes.
- Extract provider-specific discovery and quote parsing into adapters.
- Preserve exact `contract_code`, `symbol`, and `instId` fields.
- Replace `formatExchangeSymbol` branches with adapter-owned request construction.
- Migrate and validate adapters in this order: Huobi, Binance, OKX, CoinGecko.

Rollback point: keep the old adapter object until each new provider fixture passes, then switch one provider at a time.

## 3. Settings migration and discovery search

- Read legacy strings and resolve them against the active catalog.
- Persist stable instrument IDs with a schema version on save.
- Make search results catalog-backed; reject or explicitly mark unknown/ambiguous input.
- Display provider/market availability and allow removal or replacement of unresolved entries.

Validation: load old settings, save, restart, and verify the watchlist round-trips without silently changing identity.

## 4. Catalog caching and quote scheduler

- Cache the last successful catalog per provider/market.
- Add per-instrument quote states, request deduplication, generation tokens, bounded concurrency, and retry/backoff.
- Keep last successful values as stale on refresh failure and expose per-row errors.
- Ensure switching provider or market invalidates all old callbacks and data.

Validation: simulate timeout, malformed response, duplicate timer ticks, provider switch during a request, and recovery after proxy/network restoration.

## 5. Generic logo resolver

- Resolve provider metadata before external search and cache by instrument ID.
- Validate downloads and derive the text fallback from normalized instrument metadata.
- Confirm newly discovered instruments resolve logos independently of quote success and without symbol-specific branches.

Validation: missing logo metadata, exact-match miss, corrupt download, cached hit, and provider/market collision.

## 6. UI, docs, and compatibility pass

- Update Panel.qml, BarWidget.qml, and Settings.qml to consume normalized records and quote states.
- Keep all user-facing messages translated through plugin translations.
- Update README files, manifest version, registry version/timestamp, and local plugin sync.
- Remove obsolete symbol aliases and static lists only after catalog/cache fallback is in place.

## 7. Price and rapid-move notifications

- Add `AlertEngine.js` with pure normalization, price-boundary crossing, and
  rolling rapid-move/cooldown evaluation functions.
- Add per-instrument `priceAlerts` and global `rapidAlert` defaults, preserving
  unknown IDs across provider changes without symbol rebinding.
- Wire fresh successful quotes in `Main.qml` to the alert engine and translated
  `ToastService` notifications; reset transient history on configuration
  generation changes and never evaluate stale/error quotes.
- Extend `Settings.qml` with upper/lower inputs per watch-list row and a global
  rapid-alert toggle, threshold/window/cooldown controls, and explicit asset
  checkboxes. Include both alert sections in save/import/export paths.
- Add English and Simplified Chinese settings/notification translations, README
  behavior notes, manifest defaults, and synchronized registry version.

Validation: unit-test initial baselines, upper/lower crossing and re-arming,
rapid rise/fall threshold and cooldown, selected-ID filtering, malformed rules,
and provider-generation reset. Manually save/restart settings and exercise
notifications with fresh versus stale/error quotes.

## Final checks

- `jq empty market-watch/manifest.json registry.json`
- `git diff --check`
- Run provider fixture/parser tests.
- Run `qs -c noctalia-shell` and verify the panel, bar widget, settings persistence, proxy mode, light/dark themes, and empty/error states.
- Compare repository and `~/.config/noctalia/plugins/<installed-market-watch>` contents after synchronization.

## Review gates

- Do not start implementation until `prd.md`, `design.md`, and this checklist are reviewed.
- After each provider migration, run the fixture and legacy-settings checks before moving to the scheduler.
- Before release, perform a full-scope check across Main.qml, Panel.qml, Settings.qml, manifest, registry, translations, assets, and README files.
