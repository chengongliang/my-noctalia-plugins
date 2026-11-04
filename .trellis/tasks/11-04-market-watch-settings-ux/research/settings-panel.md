# Verified Settings Panel Contracts

- Follow root `AGENTS.md` for v5, not the legacy QML instructions still present in some specs.
- The real panel and mock-host tests use stock Lua 5.4-compatible Luau. All files start `--!nonstrict`.
- Official API: `/tmp/official-plugins/noctalia.d.luau`. Study `example/panel.luau` and `timer/panel.luau` before changing UI. No new dependencies or API version increase.
- `ui.button`: `selected`, `variant`, `flexGrow`, `onClick`, `tooltip` are supported. Use four ordinary buttons rather than an invented tabs API.
- `ui.scroll`: supports `key`, `height`, `flexGrow`, `gap`, `align`; no CSS, maxHeight, flexShrink or overflow props. Keep every growing scroll container bounded by the root's available space. Avoid unbounded nested lists.
- `ui.select` uses numeric 0-based selectedIndex and string index callback. Capture the option ID list from its render, not a mutable watch-array index, so reordered state cannot route an old callback to another asset.
- `ui.input` is uncontrolled. Key inputs by asset ID; retained controls must not be rebuilt on unchanged polls. Inactive page input text must be seeded from the local text value when revisited.
- `noctalia.tr(key, subst)` supports interpolation. `ui.toggle` callback values are `"true"`/`"false"`.
- Keep existing service commands exactly: set_price_alert(id, enabled/upper/lower), set_rapid_alert(toggle_instrument/parameters), set_carousel, add_watch, remove_watch, move_watch, set_bar_coin, toggle_display_mode, set_chart_type, export_config, import_config, search.
- Existing deterministic-state tests live in `market-watch/tests`; `chart_settings_test.luau` currently finds chart_type on first open and needs to enter the new display page first.
- Task change boundary: panel, two translations, tests, README. Do not edit manifest/catalog, service/store, other workspace changes, or user data. Do not commit.

## Shared Test Keys

Use stable keys so the parent-owned tests can invoke the real tree:

- Four navigation buttons: `settings_tab_assets`, `settings_tab_display`, `settings_tab_alerts`, `settings_tab_config`.
- Bounded scroll areas: `watch_scroll`, `rapid_assets_scroll`; search input remains `watch_search_<generation>`.
- Reminder mode buttons: `alert_mode_price`, `alert_mode_rapid`.
- Price asset selector: `price_alert_asset`; keep `pa_enabled_<id>`, `pa_upper_<id>`, `pa_lower_<id>` for per-asset controls.
- Rapid local search input: `rapid_filter`; selected count label: `rapid_selected_count`.
- Keep the existing control keys for watch actions, chart, bar, carousel, export/import and rapid toggles.
