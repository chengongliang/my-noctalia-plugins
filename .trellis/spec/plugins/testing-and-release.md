# Testing And Release

## Offline Provider Tests

`market-watch/tests/MarketProviders.test.js` loads `MarketProviders.js` in a
Node VM and uses JSON fixtures under `market-watch/tests/fixtures/`. Extend
this style when changing adapters. Every provider fixture should assert:

- the normalized ID and exact exchange identifier;
- the quote URL parameter or query shape;
- normalized numeric quote fields; and
- malformed or provider-error responses returning `null`.

The existing regression proves Huobi keeps `AAPL-USDT` and rejects the guessed
`APPL-USDT`, and covers Binance, OKX, and CoinGecko.

## QML And Manual Checks

There is no repository-wide QML test runner. For entry-point, layout, settings,
or lifecycle changes, launch `qs -c noctalia-shell` and verify the affected
bar, panel, settings, and launcher surfaces. Exercise empty, loading, stale,
error, proxy, and provider-switch paths. Save settings, restart Noctalia, and
confirm the same values and schema are restored.

For Hermes client-only mode, run `hermes-agent/scripts/hermes-bridge-serve.sh`
on the bridge host, connect through the documented SSH tunnel, and check
`/health` and authenticated `/state` before testing the panel.

## Static Checks

```bash
jq empty market-watch/manifest.json hermes-agent/manifest.json registry.json
node market-watch/tests/MarketProviders.test.js
node market-watch/tests/AlertEngine.test.js
git diff --check
```

Also check that every `pluginApi?.tr` key exists in the plugin locale files,
that every manifest entry point exists, and that preview images and README files
remain present.

## Version And Documentation Synchronization

When a plugin version changes, update the corresponding registry entry's
`version` and `lastUpdated`. Keep manifest defaults, README configuration
tables, translations, bundled assets, and registry metadata in the same change.
Do not claim a provider or setting is supported in documentation until its
adapter, UI, and fixture/manual checks exist.
