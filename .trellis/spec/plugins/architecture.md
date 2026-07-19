# Plugin Architecture

## Repository Layout

The repository has two independently installable plugin directories:

```text
market-watch/
  Main.qml BarWidget.qml Panel.qml Settings.qml MarketProviders.js
  i18n/ assets/ tests/ manifest.json README.md
hermes-agent/
  Main.qml BarWidget.qml Panel.qml LauncherProvider.qml Settings.qml
  components/ scripts/ i18n/ assets/ manifest.json README.md
registry.json
```

Do not add a root build system or cross-plugin runtime dependency. Shared
conventions belong in these specs; code belongs in the plugin that owns the
behavior.

## Entry Points And Shared State

`manifest.json` lists only the entry points a plugin implements. `Main.qml` is
the long-lived state owner when the plugin declares `main`; widgets and panels
read it through `pluginApi?.mainInstance`. This is the pattern used by
`market-watch/Main.qml`, `hermes-agent/Main.qml`, and the official `timer`
plugin.

Use the injected API instead of importing another plugin's internals:

```qml
property var pluginApi: null
readonly property var cfg: pluginApi?.pluginSettings || ({})
readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})
readonly property var mainInstance: pluginApi?.mainInstance
```

IPC handlers live in `Main.qml` and use a `plugin:<id>` target. Screen-aware
panel operations go through `withCurrentScreen`, `openPanel`, or `togglePanel`
so the widget does not guess a screen.

## Manifest And Registry

The folder name, manifest `id`, and registry `id` must match. Keep these fields
aligned with the existing manifests:

- `version`, `minNoctaliaVersion`, `repository`, `tags`, and `entryPoints`
- `metadata.defaultSettings` for every setting read by QML
- registry `version` and `lastUpdated` whenever the manifest version changes

Use only tags documented in the root README and keep the repository URL as
`https://github.com/noctalia-dev/noctalia-plugins`.

## Naming And Ownership

QML component files use PascalCase (`BarWidget.qml`, `LauncherProvider.qml`),
JavaScript helpers use descriptive camelCase functions, and Python bridge
modules use snake_case. Keep provider parsing in `MarketProviders.js` rather
than duplicating response-field extraction in `Main.qml`, `Panel.qml`, or
`Settings.qml`.
