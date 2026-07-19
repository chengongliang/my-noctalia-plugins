# Noctalia Plugin Guidelines

This layer covers both plugins in this repository: `market-watch` and
`hermes-agent`. Each plugin is a self-contained directory loaded by Noctalia
Shell, not a package built by this repository.

## Guides

| Guide | Use it for |
| --- | --- |
| [Architecture](./architecture.md) | Plugin layout, entry points, manifests, and shared state |
| [QML Components](./qml-components.md) | Bar, panel, settings, launcher, and widget contracts |
| [State And I/O](./state-and-io.md) | Settings fallback, `Process`, `FileView`, async work, and logging |
| [Provider Contracts](./provider-contracts.md) | Market Watch instruments, quotes, catalogs, and logos |
| [Testing And Release](./testing-and-release.md) | Fixtures, shell checks, documentation, and registry synchronization |

## Pre-Development Checklist

- [ ] Identify the affected plugin directory and read its `manifest.json`, README, and entry points.
- [ ] Check the official reference implementations: [`hello-world`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/hello-world) for the minimal plugin contract and [`timer`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/timer) for shared `mainInstance` state.
- [ ] Confirm every new setting has a `metadata.defaultSettings` value and an edit-copy in `Settings.qml`.
- [ ] Search for an existing helper, translation key, asset, or provider parser before adding another one.
- [ ] For external data, define the normalized boundary before changing a panel or settings consumer.
- [ ] Keep user-facing text in the plugin's `i18n/` files and use `pluginApi?.tr(...)`.

## Quality Check

Run the checks appropriate to the change before committing:

```bash
jq empty market-watch/manifest.json hermes-agent/manifest.json registry.json
node market-watch/tests/MarketProviders.test.js
git diff --check
```

For QML or lifecycle changes, run `qs -c noctalia-shell` and exercise the
affected plugin in both light and dark themes. For settings, save, restart,
and verify the persisted shape. For provider changes, use offline fixtures and
also verify proxy and temporary-network-failure behavior manually.

The root `README.md` and each plugin README document installation. A plugin
version bump requires the matching `registry.json` version and `lastUpdated`
update in the same change.
