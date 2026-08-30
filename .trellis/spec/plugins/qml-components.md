# QML Components

## Imports And Widgets

Use the imports and Noctalia widgets established by the official plugins:
`qs.Commons` for `Style`, `Color`, `Settings`, and `Logger`, `qs.Widgets` for
`NText`, `NLabel`, `NButton`, `NBox`, `NComboBox`, `NToggle`, and related
controls, and `qs.Services.UI` for panel, bar, tooltip, and context-menu
services. Prefer themed `N*` controls over new raw Qt controls. Existing
`Rectangle` containers in the panels are structural and should not become a
second styling system.

## Bar Widgets

Bar widgets receive `pluginApi`, `screen`, `widgetId`, `section`,
`sectionWidgetIndex`, and `sectionWidgetsCount`. They must provide stable
implicit dimensions for horizontal and vertical bars. Follow
`market-watch/BarWidget.qml` and the official `hello-world/BarWidget.qml` for
screen-aware sizing, tooltip direction, context menus, and settings access.

Left click opens or toggles the plugin panel. Right click closes the context
menu after dispatching its action and uses `BarService.openPluginSettings` for
settings. Do not put provider requests or persistent settings writes directly
in a click handler.

### Rotating Bar Content

When one bar widget rotates through several records, keep one interactive pill
inside a clipped item and swap its bound record only after the pill has moved
outside the clip. This preserves one owner for click, context-menu, tooltip,
and sizing behavior while preventing differently sized labels from flashing
during the swap.

```qml
Item {
  readonly property var records: mainInstance?.barWatchList ?? []

  Timer {
    running: root.records.length > 1
    interval: Math.max(2, root.mainInstance?.barScrollInterval ?? 5) * 1000
    repeat: true
    onTriggered: if (!scrollAnimation.running) scrollAnimation.restart()
  }
}
```

Forward stable `implicitWidth` and `implicitHeight` from the pill through the
clip for both horizontal and vertical bars. Use `Style.animationFast` so the
transition becomes instantaneous when shell animations are disabled. Stop the
animation, restore position/opacity, and clamp the current index whenever the
record list changes. A single record must remain static and must not run a
polling timer.

Validate one record, three records, list mutation during rotation, horizontal
and vertical bars, and differing label widths. A duplicate-pills design is a
bad fit because it duplicates interaction bindings and creates two competing
implicit-size owners.

## Panels

Panels fill their slot, expose `geometryPlaceholder`, and scale preferred
dimensions with `Style.uiScaleRatio`:

```qml
readonly property var geometryPlaceholder: panelContainer
property real contentPreferredWidth: 400 * Style.uiScaleRatio
property real contentPreferredHeight: 500 * Style.uiScaleRatio
readonly property bool allowAttach: true
```

Use `pluginApi?.mainInstance` for shared data. `market-watch/Panel.qml` reads
normalized instruments and quote states; it does not reconstruct provider URLs.
`hermes-agent/Panel.qml` consumes the bridge-backed state and delegates actions
to `Main.qml`.

## Settings

Settings components keep editable values separate from `pluginSettings`:

```qml
property string editProxyUrl: cfg.proxyUrl ?? defaults.proxyUrl ?? ""

function saveSettings() {
  if (!pluginApi) return;
  pluginApi.pluginSettings.proxyUrl = root.editProxyUrl;
  pluginApi.saveSettings();
}
```

Use the same `cfg -> defaults -> hardcoded` fallback chain for every value.
`saveSettings()` is required because the shell calls it when the user saves.
Do not bind an input directly to a mutable settings object or persist every
keystroke.

## Launcher Providers

`hermes-agent/LauncherProvider.qml` is the local pattern: declare the prefix,
return launcher result objects with translated names and descriptions, and
delegate activation to `mainInstance`. Close the launcher after opening a
panel. Do not put HTTP or subprocess parsing in launcher result construction.

## Text And Translation

All user-facing plugin text belongs in `i18n/en.json` and the supported locale
files. Use `pluginApi?.tr("settings.key")` or another local key; do not append
fallback prose after a translation call. Keep translation trees aligned across
`market-watch/i18n/en.json`, `market-watch/i18n/zh-CN.json`, and
`hermes-agent/i18n/en.json`.
