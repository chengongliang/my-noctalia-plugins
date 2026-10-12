# AI-Assisted Development Guidelines

Guidelines for AI tools contributing to this Noctalia **v5** plugin repository. Adapted from the
official Noctalia plugin repositories: https://github.com/noctalia-dev/official-plugins and
https://github.com/noctalia-dev/community-plugins

**Study the official plugins before writing code.** The most useful references are cloned to
`/tmp/official-plugins` when available:

- [`example`](https://github.com/noctalia-dev/official-plugins/tree/main/example) — the reference
  plugin: bar widget (imperative *and* declarative), service, shortcut, launcher provider, panel.
- `timer`, `world_clock`, `notes`, `screen_recorder`, `wallhaven` — real-world patterns for shared
  state, persistence, panels, and background work.
- `noctalia.d.luau` in the official repo root — the authoritative, machine-readable API definition.
  **Always cross-check every `noctalia.*` / `ui.*` / `barWidget.*` / `panel.*` / `launcher.*` call
  against it.** Prop tables are exhaustive; an unlisted prop is logged and skipped.

## Platform

This repository targets **Noctalia v5+**. The v4 Quickshell/QML plugin format (`manifest.json`,
`Main.qml`, `BarWidget.qml`, `Settings.qml`, `i18n/`) is legacy and no longer loads. `registry.json`
is likewise replaced by `catalog.toml`.

A v5 plugin is:

```
my-plugin/
  plugin.toml           # static manifest: identity + entries + settings schema
  widget.luau           # entry scripts (Luau)
  translations/en.json  # nested keys; label_key paths resolve into this tree
  README.md
  thumbnail.webp        # exactly 960x540
  data.txt              # any files your scripts read at runtime
```

Plugin ids are `<author>/<plugin>` and the directory name matches the part after the slash.

## Entry points

| Table | Kind | Runs |
|---|---|---|
| `[[widget]]` | Bar widget | Placed on a bar; ticks + handles clicks/IPC |
| `[[shortcut]]` | Control-center tile | A toggle tile in the control center |
| `[[launcher_provider]]` | Launcher provider | Answers launcher queries behind a prefix |
| `[[desktop_widget]]` | Desktop widget | A tile on the desktop; declares a `ui.*` tree |
| `[[panel]]` | Panel | A pop-up surface; declares a `ui.*` tree, opened by id |
| `[[service]]` | Headless service | Background loop, no UI — feeds the plugin's other entries |

There is **no `main` entry**. Entries are isolated Luau VMs that do not share memory; use a
`[[service]]` plus `noctalia.state` for shared state.

Entry callbacks (define only the ones you need): `update()`, `onClick()`, `onRightClick()`,
`onMiddleClick()`, `onScroll(axis, steps, startsGesture)`, `onQuery(text)` / `onActivate(id)`,
`onOpen(context)` / `onClose()`, `onKey(chord, pressed)`, `onFrameTick(deltaMs)`, `onIpc(event, payload)`,
`onConfigChanged()`, `onEnable()`, `onOutputsChanged()`, `onExit(signal, reason)`.

## Manifest rules

The official CI validator (`.github/workflows/validate-plugins.py`) is strict. Two rules that are easy
to get wrong:

- **All of `id`, `name`, `version`, `author`, `license`, `icon`, `description` are required**, plus the
  `tags` and `dependencies` arrays. `description` must be at most **120 characters**. `tags` must come
  from the validator's allowed set. Unknown root or entry fields are **errors**.
- **`translations/en.json` must use nested objects, never flat dotted keys.** Each object key must be a
  single lowercase segment (`a-z 0-9 - _`, no leading underscore, no dots). A `label_key` is a dotted
  *path* into that tree.

Also: `placement` ∈ `attached`|`floating`; `position` from the validator's fixed list; `width`/`height`
are a positive number or `"fill"`, and `"fill"` requires `placement = "floating"`; `default` is
required on every setting; `layer` is not in the panel field allowlist.

`plugin_api` is a positive integer declaring the **oldest** API level you need. Use the oldest level
that covers your features — raising it drops the plugin from every older Noctalia. Levels: 3 mandatory
baseline, 4 `httpStream`, 5 drag-and-drop, 6 `string_map`, 8 `dismiss_on_outside_click`, 9 closures in
callback props, 10 `keyboard_focus`, 11 `persistent` panels, 12 system stats/`nowMs`, 13 `capture_keys`,
14 `[widget.actions]`, 15 `openSettings`, 17 service enable lifecycle, 18 `setNeedsFrameTick`,
21 `ui.markdown` + `submitOnEnter` + `stickToBottom`, 22 `require()`, 24 argv `runAsync`,
26 `getSetting`, 28 `openContextMenu`, 29 graph pointer callbacks, 31 `getColor`, 32 container tooltips.

## Settings

Settings are **host-rendered from the manifest** — there is no settings script. Scope them deliberately:

- `[[setting]]` at the manifest root — shared by every entry (a service, panel, and widget all read it).
- `[[<entry>.setting]]` — that entry only; **not visible to other entries**.

```toml
[[setting]]
key = "interval"
type = "int"
label_key = "settings.interval.label"
description_key = "settings.interval.description"
default = 5
min = 1
max = 60
```

Types: `string`, `string_list`, `string_map`, `bool`, `int`, `double`, `select`, `file`, `folder`,
`glyph`, `color`. Plus `options` (for `select`, as `{ value, label_key }`), `visible_when`
(`{ key, values }` — values compared as strings, so booleans are `"true"`/`"false"`), and `advanced`.

**`noctalia.getConfig(key)` is read-only and single-argument** (no `??` fallback chain). Reading an
undeclared key logs a warning and returns `nil`. Plugins **cannot write settings** — if the user must
change something at runtime from a panel or widget, persist it yourself under
`noctalia.pluginDataDir()`.

## Component conventions

```lua
--!nonstrict
-- bar widget entry
local value = noctalia.getConfig("label")

function update()
  noctalia.setUpdateInterval(1000)
  barWidget.setText(tostring(value))
end

function onClick()
  noctalia.togglePanel("author/plugin:panel")
end
```

- Start every `.luau` file with `--!nonstrict`.
- Build UI trees with `ui.*` (`ui.column`, `ui.row`, `ui.label`, `ui.glyph`, `ui.button`, `ui.toggle`,
  `ui.slider`, `ui.input`, `ui.select`, `ui.scroll`, `ui.image`, `ui.box`, `ui.markdown`, `ui.graph`,
  `ui.progress`, `ui.separator`, `ui.spacer`, `ui.dragSource`, `ui.dropZone`). Callbacks take a named
  plugin global or a closure.
- Bar widgets may use the imperative API (`setText`, `setGlyph`, `setImage`, `setTooltip`, `setColor`,
  `setGlyphColor`, `setVisible`, `isVertical`, `outputName`) **or** `barWidget.render(tree)`. Once a
  tree is rendered, later `setText`/`setGlyph` calls have no visible effect. The bar never takes
  keyboard focus, so `ui.input`/`ui.select`/`ui.scroll` are skipped there.
- Panel geometry is host-owned: declare `width`/`height`/`placement`/`position` on the `[[panel]]`
  entry. The host also injects placement/position/open-near-click/layer as user settings.
- **Bar gestures are user configuration.** A binding in `[widget.<name>.actions]` wins over your
  callback. Every widget has a built-in `middle = "settings-open-widget"` binding, so `onMiddleClick`
  only fires if you declare `middle = "none"`. There is no bar context-menu API —
  `panel.openContextMenu` is panel-only and must be called from a `ui.button`'s `onRightClick`.
- Use `noctalia.log` for logging. There is no `Logger` and no `console.log` in v5.
- All user-facing strings go through `noctalia.tr(key, subst)` / `noctalia.trp(key, count, subst)`.
  Interpolation uses `{name}` placeholders; plurals prefer `<key>.one` / `<key>.other`. **Do not add
  fallback text after `tr()`** — the host returns the key on a miss.
- Comments should explain *why*. Reference preserved legacy behaviour and deliberate divergences.

## Common AI mistakes

- **Hallucinated APIs** — inventing `noctalia.*` members or `ui.*` props. Cross-check
  `noctalia.d.luau`; unlisted props are silently skipped and only surface in the log.
- **Using v4 idioms** — `pluginApi`, `pluginSettings`, `saveSettings()`, `manifest.metadata`,
  `Main.qml`, `Settings.qml`, `console.log`, `Style.*`, `Color.*`, `PanelService`,
  `BarService`, `I18n.tr`. None of these exist.
- **Flat dotted translation keys**, camelCase keys, or a missing `translations/en.json`.
- **Object-shaped settings** — `priceAlerts`-style maps and nested objects cannot be declared. Use a
  JSON string, `string_map`, or `pluginDataDir()`.
- **Assuming cross-entry config** — entry-scoped settings are invisible to other entries.
- **Writing settings** — impossible; persist to `pluginDataDir()` instead.
- **A README that fails CI** — it needs an H1 plus an intro of at least 8 words, and non-empty
  `## Plugin` and `## Usage` sections. `## Plugin` must document the manifest id and every entry id in
  backticks, each panel's `noctalia msg panel-toggle <id>:<entry>` command, and the launcher prefix as
  `/prefix`. `## Requirements` is required when `dependencies` is non-empty (and must mention each
  dependency in backticks); `## Settings` is required when any setting is declared. No raw HTML.

## Performance

- Avoid expensive inline bindings; prefer functions and explicit re-render calls.
- `noctalia.setUpdateInterval(ms)` is clamped to ≥ 16 ms. Poll no faster than you need to; the docs'
  `systemStats()` sample cadence is ~2 s and calling it more often returns the same sample.
- `ui.scroll` has `stickToBottom`, `scrollToBottomRev`, and `revealKey` for transcripts and long lists.
- Use `Key`ed nodes in lists so reordering reuses native controls and closures stay aligned.
- Use `require("./lib/x.luau")` to split logic into testable modules.

## Verification

Always run both of these before considering a change done:

```bash
noctalia plugins lint .                          # declared settings vs getConfig() calls, entry files
python3 .github/workflows/validate-plugins.py    # manifests, translations, README, thumbnail, entries
```

`catalog.toml` is generated by `python3 .github/workflows/update-catalog.py` and **is committed here**
(unlike the upstream repos, where CI regenerates it) because a git source cannot list plugins without
it. Regenerate it whenever a plugin's `version` or `plugin_api` changes.

## Testing

- [ ] Plugin loads and runs with `noctalia -c` / the running shell
- [ ] Test with both light and dark themes
- [ ] Test on target compositors (Niri, Hyprland, Sway, Labwc, MangoWC) if using compositor features
- [ ] Verify settings persist and that runtime state survives a reload
- [ ] Check edge cases: empty states, missing data, network failure, rapid interactions
- [ ] `noctalia plugins lint` and `validate-plugins.py` are both clean

## PR checklist

- [ ] `plugin_api` is the oldest level that covers the features actually used
- [ ] `plugin.toml` valid, `id` matches `<author>/<folder>`, `default` present on every setting
- [ ] `translations/en.json` nested, lowercase single-segment keys, complete for every referenced key
- [ ] `README.md` satisfies the CI structure rules; `thumbnail.webp` is 960x540
- [ ] Every user-facing string uses `noctalia.tr()` / `trp()`
- [ ] No hallucinated APIs — all calls verified against `noctalia.d.luau`
- [ ] No `console.log`; `noctalia.log` used instead
- [ ] `catalog.toml` regenerated if `version` or `plugin_api` changed
- [ ] Runtime-mutable state persisted under `noctalia.pluginDataDir()`, not inside the plugin directory

## Pull requests

**Title format:** `type(plugin-name): short description`

```
feat(market-watch): add rapid-move alerts
fix(hermes-agent): handle a missing bridge token
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `chore`.

The description should explain what changed and why, how to test it, and reference related issues
(for example "Closes #123"). Community submission rules also require declaring every external command
in `dependencies` and accounting for each network call, filesystem write, and spawned process.

## Resources

- [Plugin documentation](https://docs.noctalia.dev/noctalia/plugins/development/)
- [Manifest & settings](https://docs.noctalia.dev/noctalia/plugins/development/manifest/)
- [Entry scripts](https://docs.noctalia.dev/noctalia/plugins/development/entries/)
- [Declarative UI](https://docs.noctalia.dev/noctalia/plugins/development/declarative-ui/)
- [Runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/)
- [Plugin API versions](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/)
- [Official plugins](https://github.com/noctalia-dev/official-plugins) — study `example` and `timer` first

<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->
