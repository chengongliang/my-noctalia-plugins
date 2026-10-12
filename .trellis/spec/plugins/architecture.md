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

In Noctalia v5, `market-watch/lib/store.luau` owns `Store.config_path()`,
`Store.runtime_path()`, `Store.instruments_path()`, and `Store.subdir(name)`.
Logging uses `noctalia.log`; the host identifies the plugin.

### 3. Contracts

- `Store.config_path()`: `noctalia.expandPath("~/Downloads/market-watch-config.json")`.
- `Store.runtime_path()`: `noctalia.pluginDataDir()` plus `/market.json`.
- `Store.instruments_path()`: `noctalia.pluginDataDir()` plus `/instruments.json`.
- Logo files use `Store.subdir("logos")`, under the host-owned plugin data directory.
- Both translation files and both READMEs must describe the same export path.

### 4. Validation & Error Matrix

A missing or empty import file uses `settings.config_import_missing`. Oversized
or malformed files use `settings.config_import_failed`. Renaming the export file
must not relocate runtime state, instrument metadata, or logo files.

### 5. Good / Base / Bad Cases

Good: an earlier export renamed to `market-watch-config.json` imports normally.
Base: a fresh install persists state in the host-owned plugin data directory.
Bad: documentation names a different export file from `Store.config_path()`.

### 6. Tests Required

For naming-only edits, validate translation/path consistency, scan repository
content and filenames for previous identifiers, run existing Luau provider/alert
tests, `noctalia plugins lint .`, the CI validator, and `git diff --check`.
Regenerate `catalog.toml` when `plugin.toml` changes version. No new unit test is
needed for a literal rename. Report whether import/export was manually exercised.

### 7. Wrong vs Correct

Wrong: independently rename the UI path while leaving the I/O path unchanged.
Correct: keep `Store.config_path()`, both translation sources, and both README examples
aligned with `~/Downloads/market-watch-config.json` in the same change.
