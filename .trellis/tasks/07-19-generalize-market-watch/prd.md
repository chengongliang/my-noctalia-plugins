# Generalize Market Watch instrument and provider model

## Goal

Make `market-watch` a provider-driven monitoring tool that can discover and monitor any instrument exposed by the selected data source, without adding symbol-specific aliases or hard-coded URL rules for each new asset.

## Background

The current plugin stores bare symbols such as `btc` and `aapl`. It discovers exchange symbols but reduces the response to strings, then reconstructs provider identifiers by appending a guessed suffix. This caused the invalid `APPL-USDT` request even though Huobi exposes `AAPL-USDT`. Logo lookup is also keyed only by bare symbol and is independent of the selected provider and market type.

The existing configuration and installed users must remain usable during migration. The current supported providers are Huobi, Binance, OKX, and CoinGecko; current spot/perpetual modes remain in scope.

## Requirements

- **Instrument identity**: Represent a monitored asset with a stable provider/market/instrument identity and retain the exact exchange identifier returned by the provider, including fields such as display symbol, name, quote currency, and market type.
- **Provider adapters**: Give each provider a consistent contract for instrument discovery, quote URL/request construction, and response parsing. Shared code must not guess provider-specific identifiers.
- **Provider scope**: Complete the adapter migration for Huobi, Binance, OKX, and CoinGecko in this task. Implement and verify them incrementally in that order so each provider remains an independently reviewable checkpoint.
- **Discovery-driven search**: Populate the settings search from the selected provider and market catalog. Do not add arbitrary input as an apparently valid instrument; unavailable symbols must be clearly rejected or marked unavailable.
- **Configuration migration**: Read existing string watchlists, resolve them against the current catalog, preserve unresolved entries with an explicit unavailable state, and write the new identity format on the next settings save.
- **Quote reliability**: Track loading, ready, stale, and error state per instrument; prevent duplicate in-flight requests; discard responses from an obsolete provider/market configuration; and retain the last successful quote when a refresh fails.
- **Catalog resilience**: Cache the last successful provider catalog and use it when discovery temporarily fails. A transient network failure must not silently replace a valid catalog with a small hard-coded list.
- **Generic logos**: Resolve logos independently from quote data using instrument metadata first, then provider/asset metadata, cache, and a text/emoji fallback. Cache keys must include provider/market/instrument identity.
- **Compatibility**: Preserve existing provider choices, settings controls, panel/bar workflows, proxy support, and language support without symbol-specific compatibility branches.
- **Observability**: Log provider, market type, instrument identity, and failure category with `Logger`; avoid generic errors that cannot identify the affected instrument.
- **Per-instrument price alerts**: Let users configure a price alert for each monitored instrument. Alert configuration must be keyed by the stable provider/market/instrument ID, must not run for unresolved instruments, and must avoid repeated notifications while the price remains on the triggered side of the threshold.
- **Rapid-move alerts**: Provide one global rapid-rise/fall rule with configurable percentage, observation window, and cooldown. Users can explicitly select which watch-list instruments participate; a newly added instrument is not monitored by this rule until selected.
- **Notification delivery**: Deliver localized alerts through the Noctalia notification/toast service from the long-lived `Main.qml` instance. A first successful quote establishes a baseline and must not trigger an alert by itself; stale/error quotes must not trigger alerts.
- **Alert compatibility**: Preserve alert settings through configuration export/import, provider/market changes, and watch-list reordering. Rules that no longer match the active provider catalog remain stored but inactive instead of being rebound by bare symbol.

## Acceptance Criteria

- [ ] Adding a newly listed instrument from a provider catalog requires no QML code or per-symbol alias change.
- [ ] Huobi, Binance, OKX, and CoinGecko all implement and pass the same normalized discovery/quote adapter contract.
- [ ] Huobi instruments such as `AAPL-USDT` are discovered and quoted using exact provider identifiers, without adding per-symbol aliases.
- [ ] An invalid manual value such as `APPL` cannot create an apparently valid watchlist row or repeated invalid quote requests.
- [ ] Switching provider or market type re-resolves instruments and never displays a quote from the previous configuration.
- [ ] Existing string-based settings load without data loss; unresolved entries are visible and can be removed or replaced.
- [ ] One failed instrument does not blank or block successful rows, and the last successful value remains visible as stale data.
- [ ] Repeated refreshes do not create duplicate requests for the same instrument, and stale responses cannot overwrite newer configuration state.
- [ ] Catalog and quote behavior works with the configured proxy and with temporary provider/network failures using cached state and retry behavior.
- [ ] Logos remain independent of quote availability and newly discovered instruments use metadata, exact external matching, identity-keyed cache, and text fallback resolution.
- [ ] Manifest/registry versions, translations, README behavior notes, and local plugin synchronization remain consistent.
- [ ] Each available watch-list instrument can be given a price alert, and a notification is emitted only when a fresh quote crosses/reaches its configured boundary.
- [ ] Remaining at or beyond a price boundary does not emit a notification on every refresh; the rule must be re-armed before another notification is possible.
- [ ] The global rapid-move rule evaluates only explicitly selected instruments over its configured rolling time window and observes its per-instrument cooldown.
- [ ] Loading the plugin, changing provider/market, restoring cached/stale data, or receiving an obsolete quote response cannot produce a notification.
- [ ] Alert settings round-trip through normal settings save plus configuration export/import, and all alert UI/messages exist in English and Simplified Chinese.

## Out of Scope

- Adding new external market-data providers beyond the four currently supported.
- Building a server-side aggregation service or websocket streaming backend.
- Replacing the Noctalia panel/bar UI design.
- Guaranteeing a logo for every provider instrument when the provider exposes no metadata.

## Planning Status

The requirements are ready for technical design. Implementation must wait until the design and execution plan are reviewed and this task is explicitly started.
