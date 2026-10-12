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

## Market Watch File And Log Names

### 1. Scope / Trigger

Plugin naming changes affect import/export files, cache readers/writers, logs,
translations, and documentation together.

### 2. Signatures

`Main.qml` owns `configPath`, `catalogCacheDir`, `catalogCachePath`, and `logoDir`.
Use `Logger.<level>("MarketWatch", message)` for this plugin.

### 3. Contracts

- `configPath`: `$HOME/Downloads/market-watch-config.json`.
- `catalogCachePath`: `$HOME/.cache/noctalia/market-watch/catalogs/<provider>-<marketType>.json`; CoinGecko uses `spot`.
- `logoDir`: `$HOME/.cache/noctalia/market-watch/logos`.
- Locale files, embedded translations, and both READMEs must describe the same paths.

### 4. Validation & Error Matrix

A missing or empty import file uses `settings.configImportMissing`. Unusable
catalog caches follow the existing discovery/failure flow. A directory rename
rebuilds caches; it must not change saved plugin settings.

### 5. Good / Base / Bad Cases

Good: an earlier export renamed to `market-watch-config.json` imports normally.
Base: a fresh install creates caches in the current plugin directory.
Bad: documentation names a different export file from `configPath`.

### 6. Tests Required

For naming-only edits, validate JSON and locale/embedded path consistency, scan
repository content and filenames for previous identifiers, and run existing
provider/alert tests plus `git diff --check`. No new unit test is needed for a
literal rename. Report whether shell import/export was manually exercised.

### 7. Wrong vs Correct

Wrong: independently rename the UI path while leaving the I/O path unchanged.
Correct: keep `configPath`, both translation sources, and both README examples
aligned with `~/Downloads/market-watch-config.json` in the same change.
