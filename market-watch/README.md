# Market Watch

Market Watch is a Noctalia plugin that shows live market prices for cryptocurrencies,
metals and US stocks in the status bar and in a scrollable detail panel. Instead of
shipping a fixed coin table it discovers the exact tradable instruments from the
exchange you select, so newly listed markets work without a plugin update. Per-asset
price alerts and a rapid rise/fall detector can notify you when something moves.

## Plugin

| Field | Value |
| --- | --- |
| Manifest id | `chengongliang/market-watch` |
| Version | 2.0.0 |
| Plugin API | 26 |
| Dependency | `curl` |

Entries:

- `service` — the headless engine. It owns instrument resolution, the quote queue,
  the alert rules, the logo cache and the runtime state, and publishes all of it on
  the plugin's shared state channel.
- `bar` — the status bar widget: one asset, a rise/fall colour and an arrow.
- `watch` — the market table: price, 24h change, high and low for every watched asset.
- `settings` — the settings panel: watch list, bar asset, display mode, price alerts,
  rapid alert and configuration import/export.

Open the panels from the command line:

```sh
noctalia msg panel-toggle chengongliang/market-watch:watch
noctalia msg panel-toggle chengongliang/market-watch:settings
```

The bar widget opens the market panel on a left click. Its right click is bound to the
host's per-widget settings dialog (see the gesture note under Usage). The service also
answers plugin IPC, for example:

```sh
noctalia msg plugin chengongliang/market-watch:service focused refresh-now
noctalia msg plugin chengongliang/market-watch:service focused force-refresh
noctalia msg plugin chengongliang/market-watch:service focused toggle-mode
noctalia msg plugin chengongliang/market-watch:service focused toggle-panel
noctalia msg plugin chengongliang/market-watch:service focused status
```

## Requirements

- `curl` — every network call goes through it: symbol resolution, each quote, the
  logo lookup and the logo download. It is declared as a manifest dependency.

The plugin also needs a shell build with plugin API 26, and it writes files (see
State and files below). There is no other companion program.

## Usage

1. Add the **Market Watch** bar widget to your bar from the widget picker.
2. Open the settings panel (`noctalia msg panel-toggle chengongliang/market-watch:settings`)
   or click the gear button in the market panel, then search for an asset such as
   `btc`, `xau` or `aapl` and click a result to add it to the watch list.
3. Use the arrow buttons to reorder rows and the trash button to remove one. The
   first entry becomes the bar asset when the current one is removed.
4. Pick the bar asset, the display mode, and optionally an upper and lower price per
   asset, or a rapid move rule that watches the assets you tick.
5. Left click the bar widget to open the market table; the landing rows show price,
   24h change, 24h high and 24h low for each watched asset.
6. Scroll the wheel over the bar widget to walk the displayed asset along the watch
   list, in the order the settings panel lists it. It wraps at both ends, so one
   gesture reaches every asset; with a single watched asset there is nothing to cycle.
7. To stop choosing by hand, turn on the **bar carousel** in the settings panel: the
   widget then rotates the displayed asset on its own, every *interval* seconds
   (2-60, default 5). The rotation covers the assets you **follow** — the toggle on
   the left of each watch-list row — and with none followed it rotates the whole watch
   list. Use the `<` and `>` buttons in the carousel section to step it by hand, or the
   wheel: while the carousel is on, a wheel step moves the rotation instead of only the
   pill, and restarts the interval so your choice is not overridden an instant later.
   The carousel advances whether or not a panel is open, and it never issues a network
   request of its own.

The carousel and the wheel share one piece of state, `bar_coin`: the carousel never
writes it, so switching the carousel off returns the bar to the asset you last picked.
An asset that is not tradable is skipped while at least one followed asset is, so the
bar does not sit on `--`, and an asset removed from the watch list stops rotating.

Bar gestures are user configuration in Noctalia v5. This plugin ships four defaults:
`left = "none"` so the widget's own click handler opens the market panel,
`right = "settings-open-widget"`, and `scroll_up`/`scroll_down = "none"` so the wheel
reaches the widget instead of being consumed by the host. The v4 right-click menu — open panel, switch display
mode, settings, refresh now — cannot be a context menu in v5, because panels own the
only context-menu API. The equivalent actions are the panel's refresh and gear buttons
and the IPC events listed under Plugin.

## Settings

The first group of settings is rendered by the shell from the manifest. The plugin
reads them but cannot write them, so they are the *static* half of the configuration:

| Setting | Type | Default | Effect |
| --- | --- | --- | --- |
| Data source | select | `huobi` | Which exchange or aggregator provides symbol resolution and quotes: Huobi, Binance, OKX or CoinGecko. |
| Market type | select | `spot` | Spot pairs or USDT perpetual contracts. CoinGecko is always spot. |
| Proxy URL | string | empty | Optional `http://host:port` or `socks5://host:port`, passed to every `curl` call. |
| Refresh interval | int, 1-60 | 5 | Seconds between refresh cycles. CoinGecko is floored at 10 seconds. |
| Red rises | bool | false | Rise in red and fall in green, instead of the Western green/red. |

Everything else is edited in the **settings panel** and stored by the service in
`pluginDataDir()/market.json`, because a v5 plugin cannot write settings:

- the watch list (order included) and the bar asset — it starts from a built-in default
  (btc, eth, bnb, sol, xrp) and is edited here, with add/remove/reorder and symbol search,
- the status bar display mode (full text or compact price only),
- the per-asset upper and lower price alerts,
- the rapid rise/fall rule: enable, threshold percent, observation window, cooldown
  and the monitored assets,
- the bar carousel: whether it rotates, the interval in seconds, and which assets it
  follows (empty means the whole watch list).

Configuration import and export use `~/Downloads/crypto-market-config.json`, the same
path as the v4 plugin. Export writes that file; import reads it and applies the
runtime half of the configuration. The static settings in the file are informational:
the import reports them so you know to change them in the host settings window.

## Data sources

Metals and US stocks appear as exchange-listed USDT perpetual contracts, for example
`AAPL-USDT` on HTX or a tokenized-stock swap on OKX; spot markets are crypto pairs
only.

There is no bulk instrument download. Symbols are built on demand from the bare asset
name, in exactly the shapes the v4 quote URLs already used:

| Provider | Spot symbol | Perpetual symbol | Quote | Availability check |
| --- | --- | --- | --- | --- |
| Huobi | `btcusdt` | `BTC-USDT` | 1-day kline | the first quote |
| Binance | `BTCUSDT` | `BTCUSDT` | 1-day kline | per-symbol `exchangeInfo?symbol=` |
| OKX | `BTC-USDT` | `BTC-USDT-SWAP` | 1-day candle | per-symbol `instruments?instId=` |
| CoinGecko | coin id, from `/search?query=` | not available | `simple/price` with 24h change | `/search?query=` |

This is a deliberate change from v4, which resolved the watch list against the
provider's complete catalogue because one service callback may not decode a body of
that size (Huobi's spot catalogue alone is about 1.4 MB, and subprocess stdout is
truncated at 1 MiB). The practical consequences:

- A symbol that the exchange does not trade is reported as unavailable, either by the
  per-symbol check (Binance, OKX) or by the first quote (Huobi, CoinGecko).
- The add-symbol search no longer walks the entire instrument universe. It answers
  from the small search endpoints — CoinGecko `/search?query=` and TradingView's
  symbol search, which is also how tokenized-stock perpetuals are found. The query is
  debounced and cached, so typing does not turn into a request per keystroke.
- Resolved instrument metadata (id, symbols, name, availability) is cached in
  `pluginDataDir()/instruments.json`, so a restart does not have to re-resolve or
  re-verify anything.

Quotes are requested four at a time, and a failing instrument backs off exponentially
(capped at five minutes) while its last good value stays on screen marked as stale.
Every response is size-checked before it is parsed, and a malformed or oversized body
never replaces the last good quote.

## Alerts

- **Price alerts** fire when the price crosses an upper or lower bound. The first
  sample only arms the rule, so starting the shell while the price already sits beyond
  a bound does not fire; the rule re-arms once the price comes back inside the band.
- **Rapid alerts** compare the newest price with the oldest price inside the
  observation window. Crossing the threshold fires once, then the pair stays disarmed
  until the price returns inside the band and the cooldown has elapsed.
- Notifications are plain host notifications: v4 could pick an icon per alert
  (arrow up, arrow down, bell) and v5's notify API takes a title and a body only, so
  the direction is carried by the message text instead.
- Alert state lives in memory. Reloading the plugin re-arms the rules rather than
  notifying about crossings that happened while it was not running.

## State and files

| Path | Written by | Contents |
| --- | --- | --- |
| `pluginDataDir()/market.json` | the service | Watch list, bar asset, display mode, both alert rules, the bar carousel (enabled, interval, followed assets, current index), schema version. |
| `pluginDataDir()/instruments.json` | the service | Resolved instrument metadata for the assets in use. |
| `pluginDataDir()/logos/<instrument>.<png\|svg>` | the service | Cached asset logos. |
| `pluginDataDir()/tradingview-logoids.json` | the service | Resolved TradingView logo ids, so the symbol search runs at most once per asset. |
| `~/Downloads/crypto-market-config.json` | the settings panel | Export target and import source for the configuration. |

Logos are resolved in the same order as v4: the provider metadata, then an exact
CoinGecko match, then an unfiltered TradingView symbol search that also covers
tokenized-stock perpetuals. A failed lookup is retried at most once a minute. v4
cropped logos into a circle; `ui.image` only rounds corners, so the icon uses a radius
that approximates the old mask, and an asset without a logo falls back to a two-letter
badge. The TradingView logos are SVG: when `rsvg-convert` happens to be installed they
are rasterised first, otherwise the SVG file is displayed directly and the badge
remains the fallback if the shell cannot decode it.

## Migrating from the v4 plugin

The market data engine, the provider adapters and the alert rules were ported
behaviour-for-behaviour, including the symbol grammar, the clamps, the first-sample
arming rule and the rolling-window cooldown. Some user-facing pieces had to change
because v5 removed or replaced them:

| v4 | v5 |
| --- | --- |
| Custom `Settings.qml` page | A `[[panel]]` (`settings`) plus host-rendered manifest settings. |
| `language` setting with bundled `i18n/*.json` | Translations follow the shell locale; `translations/en.json` and `translations/zh-Hans.json` ship with the plugin. |
| `panelPosition` (center or click) | Host-provided panel placement, position and open-near-click, per panel. |
| Bar right-click menu with four entries | Gesture bindings plus IPC events and panel buttons; the bar has no context-menu API. |
| Alert icons (`arrow-up`, `arrow-down`, `bell-ringing`) | Text-only notifications. |
| Circular logo mask (`OpacityMask`) | `ui.image` with a corner radius, or the two-letter badge. |
| `priceAlerts`, `rapidAlert`, `watchList`, `barCoin`, `displayMode` as plugin settings | Runtime state in `pluginDataDir()/market.json`, edited in the settings panel. |
| `barCoin` shared by every widget instance | Unchanged: one global bar asset, since there is no per-instance settings API. |
| `watchListSchemaVersion` migration marker | Kept in `market.json`; bare symbols are rewritten to provider instrument ids as soon as the symbol is resolved. |
| Resolution against the provider's complete catalogue | Not possible in v5 (one decode may not exceed ~100 KB, and captured stdout is capped at 1 MiB). Symbols are built on demand instead; see [Data sources](#data-sources). |
| Search across the whole instrument universe | Answered from the CoinGecko and TradingView search endpoints, so a query only finds instruments those endpoints know about. |
| A catalogue failure stuck the panel on "loading" | There is no catalogue step any more, so a plugin-wide error is limited to a missing `curl`; everything else is per-instrument. |
| The bar ticker: `barWatchList` + `barScrollInterval`, driven by a `Timer` and a slide-up/fade `NumberAnimation` | Ported as the bar carousel (`carousel_ids` + `carousel_interval`): it rotates the followed assets on a 2-60 s interval. Two differences. The slide animation is not reproduced, because v5 has no animation primitives - this is the same instant swap v4 degraded to when its animation duration was 0. And an empty followed set rotates the whole watch list rather than nothing. |
| No wheel handling at all (absent from `BarWidget.qml`, `Main.qml` and `Panel.qml`) | **New in v5:** the wheel steps the bar asset, and steps the rotation while the carousel is on. |

The exported configuration is accepted in either spelling: the port's snake_case keys
or the v4 camelCase names.

## Development

The provider and alert modules are host-free and run under a plain Lua interpreter, so
the v4 fixture corpus still guards them:

```sh
lua5.4 tests/alerts_test.luau
lua5.4 tests/providers_test.luau
```

Both suites drive the same assertions as the v4 tests against the unchanged files in
`tests/fixtures/`: the four quote payloads, the two per-symbol verification payloads,
symbol round trips against the Huobi perpetual catalogue, CoinGecko id resolution from
the bulk list's own data, the TradingView search and logo fallback, price formatting,
the crossing and cooldown logic and the normalisation clamps.

The service is written in a Lua 5.4-compatible subset as well, so it can be executed
offline against a mock host with the same fixtures; that is how the quote queue, the
debounce, the backoff and the size guards are exercised without a live shell.

```sh
noctalia plugins lint .
python3 .github/workflows/validate-plugins.py
```

## License

MIT. See the repository LICENSE file.
