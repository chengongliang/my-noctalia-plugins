# Market Watch Alert Contracts

## 1. Scope / Trigger

Apply this contract whenever `market-watch` changes per-instrument price
boundaries, rapid-move detection, alert persistence, or notification delivery.
Alerts cross persisted settings, fresh provider quotes, in-memory state, and the
Noctalia toast service, so every boundary must preserve the full instrument ID.

## 2. Signatures

`AlertEngine.js` owns pure evaluation:

```js
normalizePriceAlert(value) -> { enabled, upperPrice, lowerPrice }
normalizePriceAlerts(value) -> { [instrumentId]: PriceAlert }
isPriceAlertValid(value) -> boolean
evaluatePriceAlert(rule, price, previousState) -> { state, triggers[] }
normalizeRapidAlert(value) -> RapidAlert
isRapidAlertSelected(rule, instrumentId) -> boolean
evaluateRapidMove(samples, rule, previousState, now) -> { state, trigger, changePercent }
trimSamples(samples, now, windowMinutes) -> Sample[]
```

`Main.qml` calls the evaluators only from `setQuoteSuccess`; stale/error quote
paths must never call them. Notification delivery uses:

```qml
ToastService.showNotice(translatedTitle, translatedBody, icon)
```

## 3. Contracts

Persist price rules by exact ID, never by a bare symbol:

```js
priceAlerts: {
  "huobi:spot:btcusdt": {
    enabled: true,
    upperPrice: 70000,
    lowerPrice: 50000
  }
}
```

`upperPrice` and `lowerPrice` are optional positive numbers; when both exist,
`lowerPrice < upperPrice`. The first fresh quote initializes `upperTriggered`
and `lowerTriggered` without notifying. A later crossing notifies once; moving
back inside the boundary re-arms that direction.

The single global rapid rule is:

```js
rapidAlert: {
  enabled: false,
  thresholdPercent: 5,
  windowMinutes: 5,
  cooldownMinutes: 30,
  instrumentIds: []
}
```

Only explicitly selected IDs are sampled. Compare the newest sample with the
oldest valid sample in the rolling window. Rise and fall directions have
separate armed and cooldown state. Provider/market generation changes clear
transient price state, rapid samples, and cooldown state without rewriting
persisted rules to another provider's IDs.

## 4. Validation & Error Matrix

| Condition | Result |
| --- | --- |
| Missing, zero, negative, or non-numeric boundary | Normalize to `null`; do not notify |
| Lower boundary is greater than or equal to upper | Show settings error; evaluator emits no trigger |
| Rule disabled or ID not selected | Do not sample or notify |
| First valid quote/sample | Establish baseline only |
| Fresh quote crosses an armed boundary | Emit one localized toast and disarm that direction |
| Quote remains beyond a boundary | Do not repeat |
| Stale/error/obsolete-generation quote | Preserve data state; do not evaluate alerts |
| Provider/market switch | Clear transient alert state; keep unmatched persisted IDs inactive |

## 5. Good / Base / Bad Cases

- Good: `huobi:spot:btcusdt` crosses its configured upper price after a fresh
  baseline; one toast includes the display symbol, threshold, and current price.
- Base: the quote remains above the upper price for several refreshes; no
  repeated toast occurs until the quote returns below and crosses again.
- Bad: a `binance:spot:BTCUSDT` rule is rebound to Huobi by matching `btc`; this
  can notify for a different instrument and is forbidden.

## 6. Tests Required

Run `node market-watch/tests/AlertEngine.test.js` and assert:

- first quotes beyond a boundary do not notify;
- upper/lower crossings trigger once and re-arm after returning inside;
- malformed and inverted price ranges emit no trigger;
- rapid rise and fall use the rolling window;
- unselected IDs are rejected and cooldown suppresses repeats.

Also run provider fixtures, JSON validation, translation-key audit, and a live
Noctalia hot-load/settings check when QML or persistence changes.

## 7. Wrong vs Correct

```js
// Wrong: symbol-only rules leak across provider and market changes.
priceAlerts.btc = { upperPrice: 70000 };
evaluateAlert(lastCachedQuote);

// Correct: evaluate an exact ID only after a fresh successful quote.
priceAlerts["huobi:spot:btcusdt"] = { enabled: true, upperPrice: 70000, lowerPrice: null };
evaluatePriceAlertForQuote(instrument, freshQuote);
```
