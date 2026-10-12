# My Noctalia Plugins

Personal [Noctalia](https://noctalia.dev) plugin source repository, targeting **Noctalia v5+** and the
Luau plugin API.

Each plugin is a directory holding a static `plugin.toml` manifest, one or more Luau entry scripts, a
`translations/` bundle, a `README.md`, and a `thumbnail.webp`. `catalog.toml` at the repository root
indexes every plugin so the shell can list and compatibility-check them without a full clone.

## Plugins

| Plugin | Description |
|---|---|
| [`market-watch`](./market-watch) | Real-time market data for cryptocurrencies, metals, and US stocks on the bar and in a panel, with price and rapid-move alerts. |
| [`hermes-agent`](./hermes-agent) | Native Noctalia status and chat surface for Hermes Agent, including a client-only mode that drives a Hermes bridge running on a remote server over SSH. |

## Installation

Add this repository as a plugin source, then enable the plugins you want:

```bash
noctalia msg plugins source add CGL git https://github.com/chengongliang/my-noctalia-plugins
noctalia msg plugins list
noctalia msg plugins enable chengongliang/market-watch
noctalia msg plugins enable chengongliang/hermes-agent
```

Or point the shell at a local checkout while developing:

```bash
noctalia msg plugins source add dev path /path/to/my-noctalia-plugins
```

`.luau` edits hot-reload; manifest changes are picked up on the next configuration reload.

## Repository layout

```
market-watch/
  plugin.toml            # manifest: identity, entries, settings schema
  service.luau           # catalogue/quote polling, alert evaluation, shared state
  widget.luau            # bar widget
  panel.luau             # market table panel
  settings_panel.luau    # runtime configuration panel
  lib/                   # shared Luau modules (providers, alerts, store)
  translations/
    en.json              # nested keys; label_key paths resolve into this tree
    zh-Hans.json
  tests/                 # plain-Lua test harnesses + JSON fixtures
  README.md
  thumbnail.webp
```

Plugin ids are `<author>/<plugin>`, and the directory name matches the part after the slash. The author
segment is fixed to `chengongliang` here.

## Development

Run the same checks CI uses before committing:

```bash
# Cross-check declared settings against getConfig() calls, and entry files
noctalia plugins lint .

# Validate manifests, translations, README structure, thumbnails, and entry paths
python3 .github/workflows/validate-plugins.py

# Rebuild the plugin index that the shell reads from a git source
python3 .github/workflows/update-catalog.py
```

`AGENTS.md` documents the plugin conventions for this repository. `catalog.toml` is generated; it is
committed here because this repository has no catalogue CI, and a git source cannot list plugins
without it.

## License

This repository is licensed under the MIT License. See [`LICENSE`](./LICENSE).

Individual plugins may include additional source attribution in their own README files and manifests.
