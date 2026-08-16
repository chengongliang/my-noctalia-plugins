# Market Watch Plugin

A real-time market monitoring plugin for Noctalia Shell, displaying live crypto spot prices and supported USDT perpetual contract prices from multiple exchanges.

![Version](https://img.shields.io/badge/version-1.2.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Multi-Exchange Support**: Huobi, Binance, OKX, and CoinGecko
- **Spot and Perpetual Markets**: Spot crypto pairs plus supported USDT perpetual contracts, including exchange-listed metals and stock contracts
- **Status Bar Widget**: Display single asset price with trend indicator
- **Market Panel**: Detailed view of multiple assets with 24h high/low
- **Display Modes**: Text mode (with asset symbol) or compact mode (price only)
- **Color Schemes**: Red-rises-green-falls or green-rises-red-falls
- **Provider-driven Instruments**: Discovers exact tradable instruments from Huobi, Binance, OKX, and CoinGecko instead of guessing symbols
- **Reliable Quote Refresh**: Limits concurrent requests, preserves stale values, and rejects responses from an obsolete provider configuration
- **Auto Logo Management**: Uses instrument metadata first, then exact external matching, an identity-keyed cache, and a text fallback
- **Price Alerts**: Set independent upper and lower prices for every monitored instrument; notifications fire on fresh threshold crossings and automatically re-arm after the price returns inside the range
- **Rapid-Move Alerts**: Configure a percentage, rolling time window, cooldown, and explicit instrument selection for fast rises and falls
- **Language Switcher**: Switch the plugin interface between English and Simplified Chinese
- **Proxy Support**: Optional HTTP/SOCKS5 proxy configuration
- **Config Import/Export**: Export and restore your settings with a JSON file

## Installation

1. Copy the plugin to Noctalia plugins directory:
```bash
cp -r market-watch ~/.config/noctalia/plugins/
```

2. Restart Noctalia Shell or reload the configuration.

## Usage

### Status Bar Widget
- **Left Click**: Open or close the detailed market panel
- **Right Click**: Open the context menu for settings, refresh, and display mode switching

### Market Panel
- View multiple coins with real-time prices, 24h change, high/low
- Click **Refresh** button to manually update data
- Click **Settings** to configure the plugin

### Settings
- **Data Source**: Choose between Huobi, Binance, OKX, or CoinGecko
- **Proxy URL**: Optional HTTP/SOCKS5 proxy (format: `http://host:port` or `socks5://host:port`)
- **Market Type**: Choose spot or perpetual futures for Huobi, Binance, and OKX
- **Status Bar Asset**: Select which asset to display in the status bar
- **Display Mode**: Full mode (with symbol) or compact mode (price only)
- **Panel Position**: Open the market panel centered or near the clicked bar widget
- **Watch List**: Add/remove assets by clicking, reorder with arrow buttons
- **Per-asset price alerts**: Enable an alert row and enter optional upper and lower prices for each watch-list instrument
- **Rapid rise/fall alerts**: Enable the global rule, set its percentage/window/cooldown, and check the instruments it should monitor
- **Color Scheme**: Red rises (Chinese style) or green rises (Western style)
- **Refresh Interval**: Set update frequency from 1 to 60 seconds
- **Language**: Switch the plugin interface between English and Simplified Chinese
- **Config Management**: Export/import settings to/from `~/Downloads/crypto-market-config.json`

## Configuration

Default settings in `manifest.json`:
```json
{
  "watchList": ["btc", "eth", "bnb", "sol", "xrp"],
  "barCoin": "btc",
  "displayMode": "text",
  "panelPosition": "center",
  "redRises": false,
  "refreshInterval": 5,
  "dataSource": "huobi",
  "marketType": "spot",
  "proxyUrl": "",
  "language": "en",
  "watchListSchemaVersion": 2,
  "priceAlerts": {},
  "rapidAlert": {
    "enabled": false,
    "thresholdPercent": 5,
    "windowMinutes": 5,
    "cooldownMinutes": 30,
    "instrumentIds": []
  }
}
```

## Supported Assets

Instruments are discovered from the selected provider catalog. Search results use the provider's exact tradable identifier, so newly listed instruments do not require plugin code changes. Unavailable or ambiguous legacy entries remain visible until you replace or remove them.

## Data Sources

### Huobi (Default)
- API: `https://api.huobi.pro/market/history/kline`
- Perpetual API: `https://api.hbdm.com/linear-swap-ex/market/history/kline`
- No rate limits for basic usage
- Recommended refresh interval: 5 seconds

### Binance
- API: `https://api.binance.com/api/v3/klines`
- Perpetual API: `https://fapi.binance.com/fapi/v1/klines`
- Rate limit: 1200 requests per minute
- Recommended refresh interval: 3 seconds

### OKX
- API: `https://www.okx.com/api/v5/market/candles`
- Perpetual symbols use `-USDT-SWAP` instruments
- Rate limit: 20 requests per 2 seconds
- Recommended refresh interval: 5 seconds

### CoinGecko
- API: `https://api.coingecko.com/api/v3/simple/price`
- Spot crypto assets only in this plugin
- Rate limit: 50 calls per minute (free tier)
- **Minimum refresh interval: 10 seconds** (enforced by plugin)

## Troubleshooting

### No data displayed
1. Check internet connection
2. Test API access: `curl -s 'https://api.huobi.pro/market/history/kline?period=1day&size=1&symbol=btcusdt'`
3. Try enabling proxy in settings if behind a firewall
4. Switch to a different data source

### Logos not showing
- Logos are resolved from provider metadata or an exact external match and cached on first use
- If no trustworthy image is available, the asset symbol is shown as a text fallback
- Check cache directory: `ls ~/.cache/noctalia/crypto-market/logos/`
- If behind a firewall, configure proxy URL in settings

### Plugin not loading
1. Verify JSON syntax: `jq . manifest.json`
2. Check plugin is enabled: `cat ~/.config/noctalia/plugins.json | jq '.states["crypto-market"]'`
3. Check Noctalia logs for errors

### Rate limit errors
- Increase refresh interval in settings
- CoinGecko free tier: use minimum 10 seconds interval
- Binance: recommended 3+ seconds for multiple coins

## Development

### Project Structure
```
market-watch/
├── Main.qml          # Core data manager, API polling, logo cache
├── AlertEngine.js    # Price-boundary and rapid-move alert evaluation
├── MarketProviders.js # Provider discovery and quote adapters
├── BarWidget.qml     # Status bar widget component
├── Panel.qml         # Market panel with coin table
├── Settings.qml      # Configuration interface
├── i18n/             # Plugin translations
├── manifest.json     # Plugin metadata and defaults
└── tests/             # Offline provider parser fixtures
```

### Tech Stack
- **QML/Qt Quick**: UI framework
- **Quickshell API**: Noctalia integration
- **Process**: Shell command execution for API calls and logo downloads

### API Testing
```bash
# Test Huobi API
curl -s 'https://api.huobi.pro/market/history/kline?period=1day&size=1&symbol=btcusdt'

# Test Huobi perpetual API
curl -s 'https://api.hbdm.com/linear-swap-ex/market/history/kline?period=1day&size=1&contract_code=BTC-USDT'

# Test Binance API
curl -s 'https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1d&limit=1'

# Test Binance perpetual API
curl -s 'https://fapi.binance.com/fapi/v1/klines?symbol=BTCUSDT&interval=1d&limit=1'

# Test OKX API
curl -s 'https://www.okx.com/api/v5/market/candles?instId=BTC-USDT&bar=1D&limit=1'

# Test OKX perpetual API
curl -s 'https://www.okx.com/api/v5/market/candles?instId=BTC-USDT-SWAP&bar=1D&limit=1'

# Test CoinGecko API
curl -s 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true'
```

## License

MIT License - see LICENSE file for details.

## Author

chengongliang

## Version

1.2.0 - Adds per-instrument upper/lower price alerts and selectable rolling rapid-move notifications; requires Noctalia Shell >= 4.6.6
