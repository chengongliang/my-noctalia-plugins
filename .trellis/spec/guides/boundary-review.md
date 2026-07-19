# Boundary Review

Map a cross-boundary change before editing:

```text
external response -> adapter/normalizer -> Main.qml state
  -> persisted settings/cache -> Panel/Bar/Settings rendering
```

For each arrow, record the exact shape, owner, invalid values, and failure
state. Market Watch uses stable instrument IDs, catalog/quote generations,
cache provider keys, and explicit stale/error states to prevent provider-switch
races. Hermes uses a JSON HTTP contract, loopback transport, token auth, and a
normalized `HermesState` snapshot.

Review these cases whenever the boundary changes:

- empty, malformed, unavailable, or ambiguous input;
- stale asynchronous responses after a provider, market, or bridge change;
- persistence round-trips and schema migration;
- partial success where one row or endpoint fails;
- proxy, SSH tunnel, timeout, and retry behavior;
- translations, assets, and documentation that describe the same contract.

Consumers should render normalized state and error categories. They should not
parse raw provider JSON, inspect bridge files directly, or invent a second
version of the persisted schema.
