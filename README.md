# My Noctalia Plugins

Personal Noctalia Shell plugin collection.

## Plugins

| Plugin | Description | Source |
|---|---|---|
| [`market-watch`](./market-watch) | Real-time market data for cryptocurrencies, metals, and US stocks. | Local plugin by chengongliang |
| [`hermes-agent`](./hermes-agent) | Native Noctalia status and side-panel interface for Hermes Agent. | Adapted from [`Nomadcxx/legacy-v4-plugins:add-hermes-agent`](https://github.com/Nomadcxx/legacy-v4-plugins/tree/add-hermes-agent) |

## Installation

Copy the plugin directory you want to use into your Noctalia plugins directory:

```bash
cp -r market-watch ~/.config/noctalia/plugins/
cp -r hermes-agent ~/.config/noctalia/plugins/
```

Then restart Noctalia Shell or reload the configuration.

## Development

- Each plugin has its own `manifest.json` and README.
- `registry.json` is the plugin discovery index. When a plugin version changes, update its matching `version` and `lastUpdated` fields in the same commit.
- User-facing strings should live in each plugin's `i18n/` files.
- Plugin settings defaults should be declared in `manifest.json`.

## License

This repository is licensed under the MIT License. See [`LICENSE`](./LICENSE).

Individual plugins may include additional source attribution in their own README files and manifests.
