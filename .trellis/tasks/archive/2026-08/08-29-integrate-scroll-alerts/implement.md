# Implementation Plan: Integrate Bar Scrolling and Alerts

## Status

Completed on 2026-08-29.

- Merged `main` into the feature branch and resolved all four predicted conflicts.
- Preserved both settings schemas and released their union as `1.3.0`.
- Automated checks passed: provider fixtures, AlertEngine unit tests, JSON,
  translation/default audits, `qmllint` syntax, and `git diff --check`.
- Live Noctalia validation passed: BTC/ETH/ZHIPU rotated across captured frames,
  the list and five-second interval survived a shell restart, and the merged
  plugin loaded without QML errors.
- Temporary installed-only IPC fixtures exercised the real
  `setQuoteSuccess -> AlertEngine -> ToastService` path for upper, lower, rapid
  rise, and rapid fall notifications. A simulated stale/error quote emitted a
  failure log and no toast. The fixtures were removed, the repository copy was
  restored, and the shell was restarted again.

## 1. Establish the merge

- Confirm the worktree contains only this task's planning artifacts before merging.
- Merge `main` into `chengongliang/状态栏多币种滚动支持` without discarding either parent history.
- Record every conflicted path and resolve only after comparing base/current/main versions.

Rollback: before completing the merge, `git merge --abort` returns to the pre-merge state.

## 2. Resolve cross-feature settings and documentation

- Resolve `Settings.qml` by merging edit copies, UI sections, helper functions, validation, synchronization, import/export, and `saveSettings()` for both feature schemas.
- Resolve English and Chinese README files with both behavior descriptions and the combined default configuration.
- Resolve `registry.json`; set plugin/registry versions to `1.3.0` and update `lastUpdated` once the integrated code is final.

Review gate: search for conflict markers and compare all four feature fields across manifest, Main, Settings, and docs.

## 3. Semantic review of automatic merges

- Trace bar settings from manifest defaults through Main normalization/import/export and Settings save into BarWidget rendering.
- Trace alert settings from manifest defaults through Settings save/import/export into fresh quote evaluation and `ToastService.showNotice`.
- Verify translation key parity across `i18n/en.json`, `i18n/zh-CN.json`, and embedded fallback maps.
- Verify stale/error/obsolete-generation quote paths cannot evaluate alerts.

## 4. Automated validation

Run:

```bash
jq empty market-watch/manifest.json market-watch/i18n/en.json market-watch/i18n/zh-CN.json registry.json
node market-watch/tests/MarketProviders.test.js
node market-watch/tests/AlertEngine.test.js
git diff --check
```

Also run the available QML syntax check and a focused script/static audit for:

- bar watch-list subset, legacy `barCoin`, import/export, and interval clamping;
- combined settings/default key coverage;
- translation key parity;
- no conflict markers or unmerged paths.

## 5. Live integration validation

In Noctalia Shell, verify:

- one status-bar asset stays static and multiple selected assets scroll;
- switch interval changes persist after save/restart;
- upper/lower crossings notify once, re-arm correctly, and rapid rise/fall respects selection/cooldown;
- stale/error quotes do not notify;
- light/dark and horizontal/vertical bar layouts remain usable.

If the live desktop environment is unavailable or starting/reloading the shell would disrupt the user's session, report this item explicitly instead of claiming it passed.

## 6. Finish

- Run the Trellis quality check and review whether the integration revealed a reusable spec update.
- Commit the merge and task artifacts only after all available checks pass.
- Record any remaining live-only validation as a clearly scoped follow-up rather than hiding it.
