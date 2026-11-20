# Market Watch Price History (Noctalia v5)

## 1. Scope / Trigger

Use this contract when changing historical prices, the clickable watch panel,
history request lifecycle, or graph readouts. This is Luau/v5 guidance; QML and
manifest.json examples elsewhere in this layer describe the older implementation.

## 2. Signatures

```lua
Providers.HISTORY_TIMEFRAMES                            -- { "5m", "4h", "1d", "1w" }
Providers.history_interval_ms(timeframe)                -- duration or nil
Providers.history_url(provider, market_type, instrument, timeframe) -- string URL or ""
Providers.parse_history(provider, response, instrument, timeframe) -- history record or nil
History.state_key(id, timeframe)                        -- shared history state key
History.prepare(points, now_ms, interval_ms, chart_type, window_ms) -- chart data
History.graph_values(segment)                          -- host-aligned curve values
History.price_at(segment, norm_x)                      -- interpolated time/price or nil
History.point_at(segment, norm_x)                      -- nearest point, index or nil
```

The panel requests data with `market.cmd = { op = "history_request", id, timeframe, nonce }`.
Missing `timeframe` defaults to `5m`. The service publishes intraday data to the
compatible `market.history:<full instrument id>` key, and longer intervals to
`market.history:<full instrument id>:<timeframe>`. Both entries use `History.state_key`.
The service includes `history_epoch` in `market.config`.

## 3. Contracts

- Adapter history: `{ points = { { timestamp_ms, price } }, interval_ms, basis }`.
  `basis` is `candle` or `price`. Exchange candle timestamps mark interval starts;
  the close of the current interval can change. CoinGecko retains its actual times.
- Exchange points may also carry real `open`, `high`, `low`, and `close` values.
  Candles require finite positive OHLC with `low <= open/close <= high`; candle
  mode scales to wick extrema, splits native flex cells into bounded groups,
  and falls back to a line when the source has no valid OHLC. Never fabricate OHLC.
- `Store` owns persisted `chart_type` (`line` by default, or `candle`), including
  import/export. The service validates `set_chart_type` and publishes the choice
  in `market.config`; switching modes reuses loaded history without a new request.
- The panel owns transient `timeframe`: `5m` (Intraday), `4h`, `1d`, or `1w`.
  Navigating between assets retains it; reopening resets it to Intraday. It does
  not add a persisted setting or affect quote/alert polling. CoinGecko only offers
  Intraday; disable other buttons with an explanatory tooltip.
- Exchange requests fetch up to 300 actual candles: Huobi uses
  `5min/4hour/1day/1week`, Binance `5m/4h/1d/1w`, OKX `5m/4H/1D/1W`.
  Intraday retains the 24-hour window; other windows span `interval_ms * 300`.
  Never relabel five-minute samples as daily or weekly candles.
- State includes `id`, `source`, `market_type`, `epoch`, `revision`, `status`,
  `timeframe`, `window_ms`, `points`, `interval_ms`, `basis`, `first_at`, `last_at`,
  `updated_at`, `error_code`.
  `updated_at = 0` means there has been no successful load; never format it as a date.
- Identity is provider/market/exact exchange symbol. The service validates requests
  against the current watch list; the panel does not reconstruct provider URLs.
- Only a visible selected detail schedules a request, on entry and every 30 seconds.
  The service has no historical polling timer. Close/back stop new requests;
  already running curl can finish without reopening the detail.
- Deduplicate per id/timeframe/epoch; count all intervals towards the global
  four-process history limit. Cache keys, in-flight tokens, panel snapshots and
  chart node keys separate intervals so late responses/hover events cannot cross
  into a different chart. Clear all intervals on provider, market, proxy changes
  and service reload; prune all intervals of removed assets. Obsolete callbacks
  may not publish or release a newer slot.
- Reuse argv-form curl and the configured proxy. Check truncation, body length,
  exit status and decoded type before parsing. Stay within 100 KiB per JSON decode.
- The cache is in memory, separate from quote/alert state and persisted configuration.
- Graph pointer callbacks require API 29. `ui.graph` takes normalized numeric values,
  not timestamp x-values; axes/readout labels are separate UI nodes. Do not invent
  tooltip/crosshair props or use newer props without changing the API requirement.
- Derive hover times from real source timestamps and display the local zone.
  Line hover interpolates time and price at x using the host's Hermite curve,
  independent of pointer y; candle hover reads the actual interval's OHLC.
  In candle mode, the unhovered default OHLC readout summarizes the displayed
  window (window open/high/low and current close), including the 24-hour summary
  for Intraday, rather than a single interval's extrema. Longer windows include
  the year in timestamps. One real candle remains drawable for newly listed assets.
  Split long missing intervals, retain proportional time spacing and one common vertical price scale.
  A constant-price line is centered; empty/single-point data does not pretend to
  be a complete day's line. Keep full price precision in hover readouts.
- Use a named graph leave callback: removal teardown cannot call a superseded
  closure. Convert normalized pointer arguments from strings and clamp them.
- Hover-dependent readout labels use `baseline = "textFixedHeight"` with
  `maxLines = 1`. Latest and hovered samples both use `history.sample`
  (`{time} · {price} {currency}`), without an appearing/disappearing prefix.
  The default `text` baseline measures each string, which can change label
  height, move the flex plot, and retrigger pointer enter/leave at its edge.
  Use the host's font-wide metrics, not a hard-coded pixel height.

## 4. Validation & Error Matrix

| Condition | Expected behavior |
| --- | --- |
| First request pending | Loading, no successful-update date |
| First request fails | Error and retry; no invented curve |
| Refresh fails with good points | Stale curve and original successful time |
| Upstream empty/invalid/truncated/oversized response | Reject, preserve good history |
| No usable history, or line mode with fewer than two points | Clear empty/insufficient state |
| Duplicate requests or rapid manual refresh | No duplicate in-flight process per id/timeframe |
| Invalid timeframe | Ignore command; no process or cache entry |
| Rapid 4h/daily/weekly switches | Active button changes immediately; show only selected interval's cache; total history processes ≤ 4 |
| Single valid weekly candle / failed refresh | Render the real candle / retain it as stale |
| Old epoch or superseded token callback | No publication or clearing newer request |
| Close/back then time advances | No new history request |
| NaN/infinite/nonpositive price, future/out-of-window time | Exclude from chart |
| Provider/market switch or asset removed | Exit old detail, invalidate old state |
| Pointer enters/leaves the plot beside a localized readout | Readout height and plot bounds stay unchanged; no hover feedback loop |

## 5. Good / Base / Bad Cases

- Good: OKX explicitly requests 300 five-minute candles; its default 100 cannot cover
  a full day. Failed network access remains an error, not a fabricated dataset.
- Base: current CoinGecko `days=1` omits `interval`; show the source's actual cadence
  and coverage, even when shorter than 24 hours.
- Good: daily/weekly requests retain older timestamps outside the intraday cutoff,
  and an older 4h callback only updates its own state key.
- Bad: explicitly requesting CoinGecko `interval=5m` as if universally free, using
  rapid-alert samples as daily history, or feeding downloaded history into alerts.

## 6. Tests Required

Run history pure tests plus real service/panel mocked-host lifecycle tests and the
existing provider/alert tests under Lua 5.4. Assert timestamps/IDs, all provider
market variants, cleanup/token isolation, request counts across 30 seconds and
close/back, full-precision hover, gaps/constant prices, stale preservation and
first-load dates. Assert all three exchange periods in spot/perpetual URLs,
invalid commands, separate interval snapshots and process slots, long-window
cutoffs, single weekly candles, period buttons, year-bearing hover times, and
all-period cleanup on removal/proxy change/reload. Run `noctalia plugins lint .` and the official plugin validator;
regenerate committed `catalog.toml` when the version or minimum API changes.
Report GUI/light-dark/network checks separately from mocked tests.
Hover regressions must assert the same prefix-free format and fixed label-height
policy for latest and hovered samples in both line and candle modes. Pointer
leave restores the latest sample's actual time and price, not merely a label.

## 7. Wrong vs Correct

```lua
-- Wrong: assumes every source has exactly five-minute timestamps.
local sample_time = window_start + index * 300000

-- Correct: hover reads the point actually represented by the graph segment.
local point = history.price_at(segment, norm_x)
if point ~= nil then
  local text = noctalia.formatTime("%m-%d %H:%M %Z", point.timestamp_ms / 1000)
end
```
