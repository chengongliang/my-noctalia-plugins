# Reuse And Ownership

Search before adding a helper, constant, translation key, or provider branch:

```bash
rg -n "function <name>|<constant>|<translation.key>|<provider>" market-watch hermes-agent
```

Keep one owner for each contract:

- provider response parsing belongs in `market-watch/MarketProviders.js`;
- shared market state and request lifecycle belong in `market-watch/Main.qml`;
- rendering and input belong in the component that owns that surface;
- bridge state normalization belongs in `hermes-agent/scripts/hermes_bridge.py`;
- user-facing text belongs in the plugin locale files.

Do not copy a parser into a panel, rebuild a provider URL from a symbol, or
duplicate settings writes in multiple controls. When the same untyped payload
field is read in two consumers, add or extend the normalizer at its boundary.

Before committing a batch change, search for old names and all affected
manifest, registry, locale, and README references. This repository has no
generated client package to hide a missed copy.
