# State And I/O

## Settings And Shared State

`Main.qml` reads plugin settings with the manifest fallback and owns derived
runtime state. `Settings.qml` edits local copies and persists once through
`pluginApi.saveSettings()`. When a setting changes the provider, market, proxy,
or bridge mode, invalidate dependent state before starting new work.

The market plugin uses a generation counter (`dataGeneration`) and per-request
provider/market fields. Hermes uses `mainInstance` state plus bridge polling.
Keep these invalidation boundaries explicit instead of relying on timing.

## Quickshell I/O

Use `Process` with argument arrays and `StdioCollector` for curl, import/export,
directory creation, and bridge commands. `market-watch/Main.qml` passes proxy
arguments as separate array elements and parses JSON only after `onExited`.
Check the exit code before parsing stdout and include stderr in the failure
state. Use `FileView` for cached JSON and translation files, then validate
provider/market keys before applying cached content.

Never interpolate a user setting into a shell command string. Never parse a
partial response or update QML state from a callback whose generation no longer
matches the active provider configuration.

## Network And Cache Failures

External requests are best-effort. A catalog failure should keep the last
successful catalog when available; a quote failure should keep the last quote
and mark it stale. Cache keys must include the provider and market type, and
logo keys must include the stable instrument identity. A cache is not proof
that an instrument is currently tradable.

Proxy support is part of the plugin contract. Preserve the configured proxy
for catalog, quote, and logo requests, and test both empty and configured proxy
values.

## Logging

Use `Logger.d`, `Logger.i`, `Logger.w`, and `Logger.e`, not `console.log`.
Include the provider, market type, instrument ID or exchange symbol, and a
failure category in external-data warnings. `market-watch/Main.qml` logs
obsolete catalog responses and quote failures this way. Avoid logging tokens,
full prompts, or other bridge secrets.

## UI State Rules

Represent loading, ready, stale, unavailable, and error states explicitly so a
single failed row does not blank successful rows. Disable or deduplicate work
where a request is already in flight. Use `Timer` for bounded polling or retry
only; prefer signals and completion callbacks for state changes.
