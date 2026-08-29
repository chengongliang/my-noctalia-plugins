# Technical Design: Integrate Bar Scrolling and Alerts

## Integration Boundary

The merge target is the current feature branch. Merge `main` into it so Git preserves both histories. The common base is `ad7bfdac`; the current side owns multi-asset bar scrolling, while the `main` side owns alert evaluation and delivery.

No new alert or scrolling architecture is introduced. The integration boundary is the existing `market-watch` plugin:

- `BarWidget.qml` remains the scrolling renderer and continues to consume per-instrument quote state.
- `Main.qml` remains shared state and combines bar configuration normalization with alert evaluation from fresh quote success.
- `AlertEngine.js` remains the pure alert evaluator.
- `Settings.qml` combines both settings surfaces and persists both schemas.
- manifest, i18n, README, and registry describe the union of the two features.

## Merge Strategy

Run a normal non-fast-forward merge of `main` into the current branch. Resolve the four predicted content conflicts intentionally:

| File | Resolution |
| --- | --- |
| `Settings.qml` | Reconstruct the union: keep bar asset pinning and interval controls, then retain price and rapid alert controls; merge edit-copy initialization, sync, validation, import/export, and save paths field-by-field. |
| `README.md` / `README_CN.md` | Keep both feature descriptions and the full default configuration. |
| `registry.json` | Keep the union metadata and set the final release version/timestamp once. |

Auto-merged files require semantic review:

- `Main.qml`: verify `barWatchList` migration/import/export is intact; verify alerts are evaluated only from `setQuoteSuccess`; verify provider/market generation reset clears transient alert state without rebinding persisted IDs.
- `manifest.json`: union all default keys.
- `i18n/*.json` and embedded translations: union keys and keep English/Chinese parity.
- `BarWidget.qml`: keep the current branch implementation unchanged unless integration checks expose a direct issue.

## Settings and Persistence Contract

The resulting settings object contains both schemas:

```text
watchList
barWatchList
barCoin
barScrollInterval
priceAlerts
rapidAlert
other existing provider/display settings
```

`barWatchList` stays a normalized subset of `watchList`; `barCoin` stays a compatibility projection of its first item. Alert rules remain keyed by exact instrument ID and are never rebound by bare symbol. Importing a configuration that omits one feature's keys preserves the existing values according to each feature's current compatibility behavior.

## Versioning

Both divergent branches independently used `1.2.0`. Their union is a new backward-compatible feature release, so the integrated plugin becomes `1.3.0`. `manifest.json` and the matching `registry.json` entry must agree, and registry `lastUpdated` uses the actual integration timestamp in `+08:00`.

## Verification and Rollback

Automated verification covers alert engine behavior, provider adapters, JSON, translations, QML syntax where tooling allows, and whitespace/conflict markers. A live shell pass covers behavior that unit tests cannot prove.

If conflict resolution is incorrect before commit, abort the merge to return to the pre-merge branch. After commit, the merge can be reverted with a merge revert; additive persisted keys remain readable by the corresponding prior implementation, and `barCoin` retains scrolling downgrade compatibility.
