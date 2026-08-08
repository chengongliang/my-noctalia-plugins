import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "MarketProviders.js" as MarketProviders

Item {
  id: root

  property var pluginApi: null

  // 读取配置
  readonly property var cfg: pluginApi?.pluginSettings || ({})
  readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})
  readonly property int watchListSchemaVersion: 2

  property var watchList: cfg.watchList ?? defaults.watchList ?? ["btc", "eth", "bnb", "sol", "xrp"]
  property string barCoin: cfg.barCoin ?? defaults.barCoin ?? "btc"
  property bool redRises: cfg.redRises ?? defaults.redRises ?? false
  property int refreshInterval: Math.max(1, Math.min(60, cfg.refreshInterval ?? defaults.refreshInterval ?? 5))
  property string displayMode: cfg.displayMode ?? defaults.displayMode ?? "text"  // "text" or "compact"
  property string panelPosition: cfg.panelPosition ?? defaults.panelPosition ?? "center"  // "center" or "click"
  property string dataSource: cfg.dataSource ?? defaults.dataSource ?? "huobi"
  property string marketType: cfg.marketType ?? defaults.marketType ?? "spot"
  property string proxyUrl: cfg.proxyUrl ?? defaults.proxyUrl ?? ""
  property string language: cfg.language ?? defaults.language ?? "en"
  readonly property var marketTypes: ["spot", "perpetual"]
  readonly property string configPath: Quickshell.env("HOME") + "/Downloads/crypto-market-config.json"
  property var translations: ({
    "en": {
      "barWidget": {
        "openPanel": "Open market panel",
        "switchCompact": "Switch to compact mode",
        "switchFull": "Switch to full mode"
      },
      "dataSource": {
        "binance": "Binance",
        "coingecko": "CoinGecko",
        "huobi": "Huobi",
        "okx": "OKX"
      },
      "marketType": {
        "perpetual": "Perpetual futures",
        "spot": "Spot"
      },
      "panel": {
        "catalogError": "Instrument catalog is unavailable",
        "change": "Change",
        "close": "Close",
        "coin": "Asset",
        "dataFrom": "Data source",
        "error": "Error",
        "high": "High",
        "loading": "Loading...",
        "low": "Low",
        "noData": "No data",
        "price": "Price",
        "refresh": "Refresh",
        "refreshNow": "Refresh now",
        "settings": "Settings",
        "title": "Market Watch"
      },
      "settings": {
        "barCoin": "Status bar asset",
        "barCoinDesc": "Select the asset to display in the status bar",
        "colorScheme": "Color scheme",
        "colorSchemeDesc": "Select the color scheme for price changes",
        "configExported": "Configuration exported to ~/Downloads/crypto-market-config.json",
        "configImportFailed": "Failed to import configuration",
        "configImportMissing": "Configuration file was not found or is empty",
        "configImported": "Configuration imported from ~/Downloads/crypto-market-config.json",
        "configMgmt": "Configuration",
        "configPath": "Config file path: ~/Downloads/crypto-market-config.json",
        "dataSource": "Data source",
        "dataSourceDesc": "Select the market data source",
        "displayMode": "Status bar display mode",
        "displayModeCompact": "Compact mode (45,230)",
        "displayModeDesc": "Select full or compact mode",
        "displayModeFull": "Full mode (BTC 45,230)",
        "export": "Export config",
        "greenRises": "Green rises",
        "import": "Import config",
        "language": "Interface language",
        "languageDesc": "Select the language used by this plugin",
        "marketType": "Market type",
        "marketTypeDesc": "Spot supports crypto pairs. Perpetual futures can display supported metals and stock contracts from exchanges.",
        "panelPosition": "Panel position",
        "panelPositionCenter": "Center",
        "panelPositionClick": "Click position",
        "panelPositionDesc": "Choose where the market panel opens from the bar widget",
        "proxy": "Proxy URL (optional)",
        "proxyPlaceholder": "http://127.0.0.1:7890",
        "proxyTip": "Leave empty to disable proxy. Format: http://host:port or socks5://host:port",
        "redRises": "Red rises",
        "refreshInterval": "Refresh interval",
        "refreshIntervalDesc": "Data update interval (1-60 seconds)",
        "search": "Search assets",
        "searchPlaceholder": "Enter an asset symbol to search (for example: btc, xau, aapl)",
        "searchResults": "Search results",
        "seconds": "seconds",
        "unavailable": "Unavailable from this data source",
        "watchList": "Watch list",
        "watchListTip": "Click an asset to add or remove it, and use arrows to reorder"
      }
    },
    "zh-CN": {
      "barWidget": {
        "openPanel": "打开行情面板",
        "switchCompact": "切换到简洁模式",
        "switchFull": "切换到完整模式"
      },
      "dataSource": {
        "binance": "币安",
        "coingecko": "CoinGecko",
        "huobi": "火币",
        "okx": "OKX"
      },
      "marketType": {
        "perpetual": "永续合约",
        "spot": "现货"
      },
      "panel": {
        "catalogError": "资产目录暂时不可用",
        "change": "涨跌幅",
        "close": "关闭",
        "coin": "资产",
        "dataFrom": "数据来源",
        "error": "错误",
        "high": "最高",
        "loading": "加载中...",
        "low": "最低",
        "noData": "无数据",
        "price": "最新价",
        "refresh": "刷新",
        "refreshNow": "立即刷新",
        "settings": "设置",
        "title": "市场行情"
      },
      "settings": {
        "barCoin": "状态栏显示资产",
        "barCoinDesc": "选择在状态栏显示的资产",
        "colorScheme": "涨跌配色",
        "colorSchemeDesc": "选择涨跌颜色方案",
        "configExported": "配置已导出到 ~/Downloads/crypto-market-config.json",
        "configImportFailed": "导入配置失败",
        "configImportMissing": "配置文件不存在或内容为空",
        "configImported": "已从 ~/Downloads/crypto-market-config.json 导入配置",
        "configMgmt": "配置管理",
        "configPath": "配置文件路径: ~/Downloads/crypto-market-config.json",
        "dataSource": "数据源",
        "dataSourceDesc": "选择行情数据来源",
        "displayMode": "状态栏显示模式",
        "displayModeCompact": "简洁模式 (45,230)",
        "displayModeDesc": "选择完整或简洁模式",
        "displayModeFull": "完整模式 (BTC 45,230)",
        "export": "导出配置",
        "greenRises": "绿涨红跌",
        "import": "导入配置",
        "language": "界面语言",
        "languageDesc": "选择此插件使用的显示语言",
        "marketType": "市场类型",
        "marketTypeDesc": "现货支持加密货币交易对。永续合约可显示交易所支持的金属和美股合约。",
        "panelPosition": "面板位置",
        "panelPositionCenter": "中间弹出",
        "panelPositionClick": "点击位置弹出",
        "panelPositionDesc": "选择行情面板从状态栏小部件打开的位置",
        "proxy": "代理地址（可选）",
        "proxyPlaceholder": "http://127.0.0.1:7890",
        "proxyTip": "留空则不使用代理。格式: http://host:port 或 socks5://host:port",
        "redRises": "红涨绿跌",
        "refreshInterval": "刷新频率",
        "refreshIntervalDesc": "数据更新间隔（1-60 秒）",
        "search": "搜索添加资产",
        "searchPlaceholder": "输入资产代码搜索（例如：btc, xau, aapl）",
        "searchResults": "搜索结果",
        "seconds": "秒",
        "unavailable": "当前数据源不可用",
        "watchList": "自选资产列表",
        "watchListTip": "点击资产名称添加或移除，使用箭头调整顺序"
      }
    }
  })
  property bool importOk: false
  property string importMessage: ""
  property int importNonce: 0

  // 币种列表
  property var allCoinsList: []
  property var instruments: []
  property var instrumentById: ({})
  property var instrumentBySymbol: ({})
  property var ambiguousSymbols: ({})
  property bool catalogReady: false
  property string catalogError: ""
  property int catalogRequestGeneration: -1
  property string catalogRequestProvider: ""
  property string catalogRequestMarketType: ""
  property int catalogCacheUpdatedAt: 0
  property bool catalogFromCache: false
  property bool persistResolvedWatchListPending: false
  property int dataGeneration: 0
  property var quoteStates: ({})
  property var inFlightQuotes: ({})
  property var queuedQuoteIds: ({})
  property int activeQuoteCount: 0
  readonly property int maxConcurrentQuotes: 4
  property var quoteQueue: []
  property string catalogCacheDir: Quickshell.env("HOME") + "/.cache/noctalia/crypto-market/catalogs"
  property string catalogCachePath: catalogCacheDir + "/" + dataSource + "-" + (dataSource === "coingecko" ? "spot" : marketType) + ".json"

  // Logo 管理
  property string logoDir: Quickshell.env("HOME") + "/.cache/noctalia/crypto-market/logos"
  property var logoCache: ({})
  property var logoFailures: ({})
  property bool logosReady: false
  readonly property int logoRetryCooldownMs: 60000
  // TradingView logoid cache: instrument id -> logoid, persisted so the
  // symbol-search endpoint is queried at most once per instrument.
  property var tvLogoIds: ({})
  readonly property string tvLogoIdCachePath: catalogCacheDir + "/tradingview-logoids.json"

  // 数据状态
  property var marketData: ({})
  property bool isLoading: true
  property string errorMessage: ""
  property int refreshNonce: 0
  property bool coinsListRefetchPending: false

  Component.onCompleted: {
    watchList = normalizeWatchList(watchList);
    barCoin = normalizeWatchReference(barCoin);
    if (!watchList.includes(barCoin)) {
      barCoin = watchList.length > 0 ? watchList[0] : "btc";
    }
    if (dataSource === "coingecko" || !marketTypes.includes(marketType)) {
      marketType = "spot";
    }
    loadTranslations();
    initLogoCache();
    loadTvLogoIdCache();
    loadCatalogCache();
    fetchCoinsList();
  }

  FileView {
    id: enTranslationFile
    path: pluginApi?.pluginDir ? pluginApi.pluginDir + "/i18n/en.json" : ""
    watchChanges: false
    printErrors: false

    onLoaded: root.storeTranslation("en", text())
    onTextChanged: root.storeTranslation("en", text())
  }

  FileView {
    id: zhTranslationFile
    path: pluginApi?.pluginDir ? pluginApi.pluginDir + "/i18n/zh-CN.json" : ""
    watchChanges: false
    printErrors: false

    onLoaded: root.storeTranslation("zh-CN", text())
    onTextChanged: root.storeTranslation("zh-CN", text())
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    printErrors: false
  }

  FileView {
    id: tvLogoIdCacheFile
    path: root.tvLogoIdCachePath
    watchChanges: false
    printErrors: false

    onLoaded: root.applyTvLogoIdCache(text())
  }

  FileView {
    id: catalogCacheFile
    path: root.catalogCachePath
    watchChanges: false
    printErrors: false

    onLoaded: root.applyCatalogCache(text())
  }

  Process {
    id: importConfigProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}

    onExited: exitCode => root.finishImportConfig(exitCode, String(stdout.text), String(stderr.text))
  }

  function loadTranslations() {
    if (enTranslationFile.path !== "") enTranslationFile.reload();
    if (zhTranslationFile.path !== "") zhTranslationFile.reload();
  }

  function storeTranslation(lang, text) {
    if (!text || text.length === 0) return;
    try {
      const next = Object.assign({}, root.translations);
      next[lang] = JSON.parse(text);
      root.translations = next;
      root.refreshNonce++;
    } catch (e) {
      Logger.w("CryptoMarket", "Failed to parse translation file for " + lang + ": " + e);
    }
  }

  function tr(path) {
    const lang = root.language === "zh" ? "zh-CN" : root.language;
    const selected = lookupTranslation(root.translations[lang], path);
    if (selected !== undefined) return selected;
    const fallback = lookupTranslation(root.translations["en"], path);
    return fallback !== undefined ? fallback : path;
  }

  function lookupTranslation(source, path) {
    if (!source) return undefined;
    const parts = path.split(".");
    let current = source;
    for (let i = 0; i < parts.length; i++) {
      if (current && current[parts[i]] !== undefined) {
        current = current[parts[i]];
      } else {
        return undefined;
      }
    }
    return current;
  }

  function normalizeAssetKey(asset) {
    return MarketProviders.normalizeSymbol(asset);
  }

  function parseInstrumentReference(reference) {
    const text = String(reference || "").trim();
    const parts = text.split(":");
    if (parts.length < 3) return null;
    if (!["huobi", "binance", "okx", "coingecko"].includes(parts[0])) return null;
    if (!["spot", "perpetual"].includes(parts[1])) return null;
    const exchangeSymbol = parts.slice(2).join(":");
    if (exchangeSymbol === "") return null;
    return {
      id: text,
      provider: parts[0],
      marketType: parts[1],
      exchangeSymbol: exchangeSymbol
    };
  }

  function normalizeWatchReference(asset) {
    if (asset && typeof asset === "object" && asset.id) return String(asset.id);
    const text = String(asset || "").trim();
    if (text === "") return "";
    if (parseInstrumentReference(text)) return text;
    return normalizeAssetKey(text);
  }

  function normalizeWatchList(assets) {
    const result = [];
    const seen = {};
    if (!Array.isArray(assets)) return result;

    for (let i = 0; i < assets.length; i++) {
      const reference = normalizeWatchReference(assets[i]);
      if (reference !== "" && !seen[reference]) {
        seen[reference] = true;
        result.push(reference);
      }
    }
    return result;
  }

  function getInstrument(reference) {
    if (reference && typeof reference === "object" && reference.id) return reference;
    const text = String(reference || "").trim();
    if (text !== "" && instrumentById[text]) return instrumentById[text];

    const parsedReference = parseInstrumentReference(text);
    const key = normalizeAssetKey(parsedReference ? parsedReference.exchangeSymbol : text);
    if (!parsedReference && key !== "" && instrumentBySymbol[key] && !ambiguousSymbols[key]) return instrumentBySymbol[key];

    if (key === "") return null;
    return {
      id: parsedReference ? parsedReference.id : key,
      provider: parsedReference ? parsedReference.provider : dataSource,
      marketType: parsedReference ? parsedReference.marketType : (dataSource === "coingecko" ? "spot" : marketType),
      exchangeSymbol: parsedReference ? parsedReference.exchangeSymbol : key,
      symbol: key,
      displaySymbol: key.toUpperCase(),
      name: key.toUpperCase(),
      base: key.toUpperCase(),
      quote: dataSource === "coingecko" ? "USD" : "USDT",
      status: "unresolved",
      logoUrl: ""
    };
  }

  function getInstrumentId(reference) {
    const instrument = getInstrument(reference);
    return instrument ? instrument.id : normalizeWatchReference(reference);
  }

  function getInstrumentSymbol(reference) {
    const instrument = getInstrument(reference);
    return instrument ? instrument.symbol : normalizeAssetKey(reference);
  }

  function getInstrumentDisplaySymbol(reference) {
    const instrument = getInstrument(reference);
    return instrument ? instrument.displaySymbol : normalizeAssetKey(reference).toUpperCase();
  }

  function getInstrumentName(reference) {
    const instrument = getInstrument(reference);
    if (!instrument) return normalizeAssetKey(reference).toUpperCase();
    return instrument.name || instrument.displaySymbol;
  }

  // 创建缓存目录的 Process
  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.logoDir, root.catalogCacheDir]
    stdout: StdioCollector {}
    stderr: StdioCollector {}

    onExited: exitCode => {
      if (exitCode === 0) {
        root.logosReady = true;
      } else {
        Logger.w("CryptoMarket", "Failed to create logo cache directory: " + String(stderr.text));
      }
    }
  }

  // 初始化 logo 缓存
  function initLogoCache() {
    mkdirProc.running = true;
  }

  // 下载单个 logo（ext 默认为 png，股票 SVG logo 传入 "svg"）
  function downloadLogo(cacheKey, url, callback, ext) {
    const extension = ext === "svg" ? "svg" : "png";
    const outputPath = logoDir + "/" + cacheKey + "." + extension;
    const tempPath = outputPath + ".tmp";
    // SVG 可能以注释开头，file 会误判为 text/plain，按扩展名选择校验方式
    const validator = extension === "svg"
      ? "test -s \"$1\" && grep -qi '<svg' \"$1\""
      : "test -s \"$1\" && file --brief --mime-type \"$1\" | grep -q '^image/'";

    // 检查文件是否已存在
    const checkProc = downloadProcComponent.createObject(root, {
      "command": ["sh", "-c", validator, "sh", outputPath]
    });

    checkProc.exited.connect(function(exitCode) {
      if (exitCode === 0) {
        callback(true);
        checkProc.destroy();
        return;
      }

      const proc = downloadProcComponent.createObject(root, {
        "command": proxyUrl ? ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", "-x", proxyUrl, "-o", tempPath, url] : ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", "-o", tempPath, url]
      });

      proc.exited.connect(function(exitCode) {
        if (exitCode === 0) {
          const finalizeProc = downloadProcComponent.createObject(root, {
            "command": ["sh", "-c", "if " + validator + "; then mv \"$1\" \"$2\"; else rm -f \"$1\"; exit 1; fi", "sh", tempPath, outputPath]
          });
          finalizeProc.exited.connect(function(finalizeExitCode) {
            callback(finalizeExitCode === 0);
            finalizeProc.destroy();
          });
          finalizeProc.running = true;
        } else {
          Logger.w("CryptoMarket", "Failed to download logo for " + cacheKey + ": " + String(proc.stderr.text));
          callback(false);
        }
        proc.destroy();
      });

      proc.running = true;
      checkProc.destroy();
    });

    checkProc.running = true;
  }

  function getLogoCacheKey(reference) {
    const instrument = getInstrument(reference);
    const id = instrument ? instrument.id : normalizeWatchReference(reference);
    return String(id || "asset").replace(/[^A-Za-z0-9._-]/g, "_");
  }

  // 动态下载资产 Logo
  function requestLogo(reference) {
    const instrument = getInstrument(reference);
    if (!instrument) return;
    const id = instrument.id;
    if (logoCache[id]) return;
    if (!canRetryLogo(id)) return;

    const cacheKey = getLogoCacheKey(id);
    const nextCache = Object.assign({}, logoCache);
    nextCache[id] = "downloading";
    root.logoCache = nextCache;

    // 先探测磁盘缓存（依次检查 png、svg），命中则直接复用，不发起网络请求
    const probeProc = downloadProcComponent.createObject(root, {
      "command": ["sh", "-c", "if test -s \"$1\" && file --brief --mime-type \"$1\" | grep -q '^image/'; then echo png; elif test -s \"$2\" && grep -qi '<svg' \"$2\"; then echo svg; fi", "sh", logoDir + "/" + cacheKey + ".png", logoDir + "/" + cacheKey + ".svg"]
    });

    probeProc.exited.connect(function(exitCode) {
      const cachedExt = String(probeProc.stdout.text).trim();
      probeProc.destroy();
      if (cachedExt === "png" || cachedExt === "svg") {
        root.finishLogoDownload(id, cacheKey, true, cachedExt);
        return;
      }

      if (instrument.logoUrl) {
        root.downloadLogo(cacheKey, instrument.logoUrl, function(success) {
          if (success) {
            root.finishLogoDownload(id, cacheKey, true);
          } else {
            root.searchExternalLogo(instrument, cacheKey);
          }
        });
        return;
      }

      // 已解析过的股票 logoid：直接走 TradingView 下载，不再重复搜索。
      if (root.tvLogoIds[id]) {
        root.downloadTradingViewLogo(instrument, cacheKey, root.tvLogoIds[id]);
        return;
      }

      root.searchExternalLogo(instrument, cacheKey);
    });
    probeProc.running = true;
  }

  function searchExternalLogo(instrument, cacheKey) {
    const id = instrument.id;
    const symbol = instrument.symbol;
    // CoinGecko logo search is exact-match only; the first fuzzy result is unsafe.
    const searchText = encodeURIComponent(instrument.exchangeSymbol || instrument.symbol || instrument.name);
    const searchUrl = "https://api.coingecko.com/api/v3/search?query=" + searchText;
    const searchProc = curlProcComponent.createObject(root, {
      "command": proxyUrl ? ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", "-x", proxyUrl, searchUrl] : ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", searchUrl]
    });

    searchProc.exited.connect(function(exitCode) {
      if (exitCode === 0) {
        try {
          const response = JSON.parse(String(searchProc.stdout.text));
          const candidates = Array.isArray(response.coins) ? response.coins : [];
          const exchangeId = String(instrument.exchangeSymbol || "").toLowerCase();
          const exactId = candidates.find(candidate => String(candidate.id || "").toLowerCase() === exchangeId);
          const symbolMatches = candidates.filter(candidate => normalizeAssetKey(candidate.symbol) === symbol);
          const foundCoin = exactId || (symbolMatches.length === 1 ? symbolMatches[0] : null);
          const logoUrl = foundCoin ? (foundCoin.large || foundCoin.thumb) : "";
          if (logoUrl) {
            downloadLogo(cacheKey, logoUrl, function(success) {
              root.finishLogoDownload(id, cacheKey, success);
            });
          } else {
            root.searchTradingViewLogo(instrument, cacheKey);
          }
        } catch (e) {
          Logger.w("CryptoMarket", "Failed to parse logo search response for " + id + ": " + e);
          root.searchTradingViewLogo(instrument, cacheKey);
        }
      } else {
        Logger.w("CryptoMarket", "Failed to search logo for " + id + ": " + String(searchProc.stderr.text));
        root.searchTradingViewLogo(instrument, cacheKey);
      }
      searchProc.destroy();
    });
    searchProc.running = true;
  }

  // 股票 logo 回退：通过 TradingView symbol-search 解析 logoid。
  function searchTradingViewLogo(instrument, cacheKey) {
    const id = instrument.id;
    const searchUrl = MarketProviders.tradingViewSearchUrl(instrument);
    if (searchUrl === "") {
      markLogoFailed(id);
      return;
    }

    const baseCommand = ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", "-H", "Origin: https://www.tradingview.com"];
    const searchProc = curlProcComponent.createObject(root, {
      "command": proxyUrl ? baseCommand.concat(["-x", proxyUrl, searchUrl]) : baseCommand.concat([searchUrl])
    });

    searchProc.exited.connect(function(exitCode) {
      if (exitCode === 0) {
        try {
          const response = JSON.parse(String(searchProc.stdout.text));
          const logoid = MarketProviders.parseTradingViewLogoId(response, instrument);
          if (logoid) {
            root.storeTvLogoId(id, logoid);
            root.downloadTradingViewLogo(instrument, cacheKey, logoid);
          } else {
            markLogoFailed(id);
          }
        } catch (e) {
          Logger.w("CryptoMarket", "Failed to parse TradingView logo search response for " + id + ": " + e);
          markLogoFailed(id);
        }
      } else {
        Logger.w("CryptoMarket", "Failed to search TradingView logo for " + id + ": " + String(searchProc.stderr.text));
        markLogoFailed(id);
      }
      searchProc.destroy();
    });
    searchProc.running = true;
  }

  function downloadTradingViewLogo(instrument, cacheKey, logoid) {
    const id = instrument.id;
    const logoUrl = MarketProviders.tradingViewLogoUrl(logoid);
    if (logoUrl === "") {
      markLogoFailed(id);
      return;
    }
    downloadLogo(cacheKey, logoUrl, function(success) {
      root.finishLogoDownload(id, cacheKey, success, "svg");
    }, "svg");
  }

  function storeTvLogoId(id, logoid) {
    if (!id || !logoid || root.tvLogoIds[id] === logoid) return;
    const next = Object.assign({}, root.tvLogoIds);
    next[id] = logoid;
    root.tvLogoIds = next;
    tvLogoIdCacheFile.setText(JSON.stringify(next, null, 2));
  }

  function loadTvLogoIdCache() {
    if (tvLogoIdCacheFile.path !== "") tvLogoIdCacheFile.reload();
  }

  function applyTvLogoIdCache(text) {
    if (!text || String(text).trim() === "") return;
    try {
      const cache = JSON.parse(String(text));
      if (!cache || typeof cache !== "object" || Array.isArray(cache)) return;
      const next = Object.assign({}, root.tvLogoIds);
      const keys = Object.keys(cache);
      for (let i = 0; i < keys.length; i++) {
        if (typeof cache[keys[i]] === "string" && cache[keys[i]] !== "") {
          next[keys[i]] = cache[keys[i]];
        }
      }
      root.tvLogoIds = next;
    } catch (e) {
      Logger.w("CryptoMarket", "Failed to parse TradingView logoid cache: " + e);
    }
  }

  function finishLogoDownload(id, cacheKey, success, ext) {
    if (success) {
      const extension = ext === "svg" ? "svg" : "png";
      setLogoPath(id, logoDir + "/" + cacheKey + "." + extension);
    } else {
      markLogoFailed(id);
    }
  }

  function setLogoPath(reference, path) {
    const key = getInstrumentId(reference);
    const nextCache = Object.assign({}, root.logoCache);
    nextCache[key] = path;
    root.logoCache = nextCache;

    const nextFailures = Object.assign({}, root.logoFailures);
    delete nextFailures[key];
    root.logoFailures = nextFailures;

    root.refreshNonce++;
  }

  function markLogoFailed(reference) {
    const key = getInstrumentId(reference);
    const nextCache = Object.assign({}, root.logoCache);
    delete nextCache[key];
    root.logoCache = nextCache;

    const nextFailures = Object.assign({}, root.logoFailures);
    nextFailures[key] = Date.now();
    root.logoFailures = nextFailures;
    root.refreshNonce++;
  }

  function canRetryLogo(reference) {
    const key = getInstrumentId(reference);
    const failedAt = root.logoFailures[key];
    if (!failedAt) return true;

    if ((Date.now() - failedAt) < root.logoRetryCooldownMs) {
      return false;
    }

    const nextFailures = Object.assign({}, root.logoFailures);
    delete nextFailures[key];
    root.logoFailures = nextFailures;
    return true;
  }

  Timer {
    interval: root.logoRetryCooldownMs
    repeat: true
    running: Object.keys(root.logoFailures).length > 0
    onTriggered: {
      const failedCoins = Object.keys(root.logoFailures);
      for (let i = 0; i < failedCoins.length; i++) {
        root.requestLogo(failedCoins[i]);
      }
    }
  }

  Component {
    id: downloadProcComponent
    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Component {
    id: curlProcComponent
    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  // 获取 logo 路径
  function getLogoPath(reference) {
    const instrument = getInstrument(reference);
    if (!instrument) return "";
    const key = instrument.id;

    // 如果缓存中有记录，直接返回
    if (logoCache[key] && logoCache[key] !== "downloading") {
      return "file://" + logoCache[key];
    }

    // 如果正在下载，返回空
    if (logoCache[key] === "downloading") {
      return "";
    }

    return "";
  }

  // 定时器
  Timer {
    interval: Math.max(root.refreshInterval * 1000, root.dataSource === "coingecko" ? 10000 : 1000)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshMarketData(false)
  }

  function refreshMarketData(force) {
    for (let i = 0; i < root.watchList.length; i++) {
      root.fetchMarketData(root.watchList[i], force === true);
    }
    if (root.watchList.length === 0) root.isLoading = false;
  }

  // 将报价请求放入有界队列，避免每次刷新同时启动所有 curl。
  function fetchMarketData(reference, force) {
    if (!root.catalogReady) return;
    const instrument = root.getInstrument(reference);
    if (!instrument) return;
    const id = instrument.id;
    const generation = root.dataGeneration;

    if (instrument.status === "unresolved") {
      const unresolvedState = root.quoteStates[id];
      if (!unresolvedState || unresolvedState.errorCode !== "unavailable") {
        root.setQuoteFailure(instrument, "unavailable", "Instrument is not available from the selected provider");
      }
      return;
    }

    const state = root.quoteStates[id];
    if (!force && state?.nextRetryAt && Date.now() < state.nextRetryAt) return;
    if (root.inFlightQuotes[id] === generation || root.queuedQuoteIds[id] === generation) return;

    const nextQueue = root.quoteQueue.slice();
    nextQueue.push({ id: id, generation: generation });
    root.quoteQueue = nextQueue;

    const nextQueued = Object.assign({}, root.queuedQuoteIds);
    nextQueued[id] = generation;
    root.queuedQuoteIds = nextQueued;
    root.pumpQuoteQueue();
  }

  function pumpQuoteQueue() {
    while (root.activeQuoteCount < root.maxConcurrentQuotes && root.quoteQueue.length > 0) {
      const nextQueue = root.quoteQueue.slice();
      const job = nextQueue.shift();
      root.quoteQueue = nextQueue;

      const nextQueued = Object.assign({}, root.queuedQuoteIds);
      if (nextQueued[job.id] === job.generation) delete nextQueued[job.id];
      root.queuedQuoteIds = nextQueued;

      if (job.generation !== root.dataGeneration) continue;
      const instrument = root.instrumentById[job.id] || root.getInstrument(job.id);
      if (!instrument || instrument.status === "unresolved") continue;
      root.startQuoteRequest(instrument, job.generation);
    }
  }

  function startQuoteRequest(instrument, generation) {
    const url = MarketProviders.quoteUrl(root.dataSource, instrument.marketType, instrument);
    if (url === "") {
      root.setQuoteFailure(instrument, "unsupported", "Provider cannot build a quote request");
      return;
    }

    const nextInFlight = Object.assign({}, root.inFlightQuotes);
    nextInFlight[instrument.id] = generation;
    root.inFlightQuotes = nextInFlight;
    root.activeQuoteCount++;
    root.setQuoteLoading(instrument);

    const proc = curlProcComponent.createObject(root, {
      "command": proxyUrl ? ["curl", "-fsSL", "--connect-timeout", "8", "--max-time", "20", "-x", proxyUrl, url] : ["curl", "-fsSL", "--connect-timeout", "8", "--max-time", "20", url]
    });

    proc.exited.connect(function(exitCode) {
      if (generation === root.dataGeneration) {
        if (exitCode === 0) {
          try {
            const response = JSON.parse(String(proc.stdout.text));
            const parsed = MarketProviders.parseQuote(root.dataSource, response, instrument);
            const numericFields = parsed ? [parsed.open, parsed.close, parsed.high, parsed.low, parsed.volume] : [];
            const validQuote = parsed && numericFields.every(value => Number.isFinite(Number(value)))
              && Number(parsed.open) > 0 && Number(parsed.close) > 0;
            if (validQuote) {
              root.setQuoteSuccess(instrument, parsed);
            } else {
              root.setQuoteFailure(instrument, "invalid-response", "Provider returned no usable quote");
            }
          } catch (e) {
            root.setQuoteFailure(instrument, "parse-error", String(e));
          }
        } else {
          root.setQuoteFailure(instrument, "network-error", String(proc.stderr.text).trim());
        }
      }

      const nextInFlight = Object.assign({}, root.inFlightQuotes);
      if (nextInFlight[instrument.id] === generation) delete nextInFlight[instrument.id];
      root.inFlightQuotes = nextInFlight;
      root.activeQuoteCount = Math.max(0, root.activeQuoteCount - 1);
      root.isLoading = false;
      proc.destroy();
      root.pumpQuoteQueue();
    });

    proc.running = true;
  }

  function setQuoteLoading(instrument) {
    const previous = root.quoteStates[instrument.id] || ({});
    const nextStates = Object.assign({}, root.quoteStates);
    nextStates[instrument.id] = Object.assign({}, previous, {
      status: previous.status === "ready" ? "ready" : "loading",
      errorCode: "",
      errorMessage: ""
    });
    root.quoteStates = nextStates;
    root.refreshNonce++;
  }

  function setQuoteSuccess(instrument, parsed) {
    const change = ((parsed.close - parsed.open) / parsed.open * 100);
    const quote = {
      open: parsed.open,
      close: parsed.close,
      high: parsed.high,
      low: parsed.low,
      volume: parsed.volume,
      change: change,
      isRising: parsed.close >= parsed.open,
      updatedAt: Date.now()
    };

    const nextMarketData = Object.assign({}, root.marketData);
    nextMarketData[instrument.id] = quote;
    root.marketData = nextMarketData;

    const nextStates = Object.assign({}, root.quoteStates);
    nextStates[instrument.id] = {
      status: "ready",
      updatedAt: quote.updatedAt,
      failureCount: 0,
      nextRetryAt: 0,
      errorCode: "",
      errorMessage: ""
    };
    root.quoteStates = nextStates;
    root.errorMessage = "";
    root.refreshNonce++;
  }

  function setQuoteFailure(instrument, code, message) {
    const previous = root.quoteStates[instrument.id] || ({});
    const failureCount = Number(previous.failureCount || 0) + 1;
    const hasQuote = root.marketData[instrument.id] !== undefined;
    const delay = Math.min(300000, 1000 * Math.pow(2, Math.min(failureCount, 8)));
    const nextStates = Object.assign({}, root.quoteStates);
    nextStates[instrument.id] = {
      status: hasQuote ? "stale" : "error",
      updatedAt: previous.updatedAt || 0,
      failureCount: failureCount,
      nextRetryAt: Date.now() + delay,
      errorCode: code,
      errorMessage: message
    };
    root.quoteStates = nextStates;
    root.isLoading = false;
    root.refreshNonce++;
    Logger.w("CryptoMarket", "Quote failed [" + root.dataSource + "/" + instrument.marketType + "/" + instrument.exchangeSymbol + "] " + code + ": " + message);
  }

  // 格式化价格
  function formatPrice(price) {
    if (!price || price <= 0) return "--";
    if (price >= 1000) {
      return price.toFixed(0).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    }
    if (price >= 1) return price.toFixed(2);
    if (price >= 0.01) return price.toFixed(4);
    // 小于 0.01 使用科学计数法
    if (price < 0.000001) {
      return price.toExponential(2);
    }
    return price.toFixed(6);
  }

  // 格式化涨跌幅
  function formatChange(change) {
    if (change === undefined || change === null) return "--";
    const sign = change >= 0 ? "+" : "";
    return `${sign}${change.toFixed(2)}%`;
  }

  // 获取价格颜色
  function getPriceColor(coin) {
    const data = marketData[getInstrumentId(coin)];
    if (!data) return "#888888";

    const isRising = data.isRising;
    // 红涨模式: 涨=红 跌=绿
    // 绿涨模式: 涨=绿 跌=红
    if (redRises) {
      return isRising ? "#ff704b" : "#39c38c";
    } else {
      return isRising ? "#39c38c" : "#ff704b";
    }
  }

  // 获取币种图标
  function getCoinIcon(coin) {
    const key = getInstrumentSymbol(coin);
    return key.slice(0, 2).toUpperCase();
  }

  function getCoinName(coin) {
    const instrument = getInstrument(coin);
    if (!instrument) return normalizeAssetKey(coin).toUpperCase();
    const name = instrument.name || "";
    return name && name.toLowerCase() !== instrument.displaySymbol.toLowerCase()
      ? instrument.displaySymbol + " (" + name + ")"
      : instrument.displaySymbol;
  }

  function searchCoinSymbols(query) {
    const text = normalizeAssetKey(query);
    if (text === "") return [];

    const source = root.catalogReady ? root.instruments : [];
    const filtered = source.filter(function(instrument) {
      const symbol = String(instrument.symbol || "").toLowerCase();
      const displaySymbol = String(instrument.displaySymbol || "").toLowerCase();
      const name = String(instrument.name || "").toLowerCase();
      return symbol.indexOf(text) === 0 || displaySymbol.indexOf(text) === 0 || name.indexOf(text) !== -1;
    });

    filtered.sort(function(a, b) {
      const aSymbol = String(a.symbol || "").toLowerCase();
      const bSymbol = String(b.symbol || "").toLowerCase();
      const aMatch = aSymbol.indexOf(text) === 0 ? 0 : 1;
      const bMatch = bSymbol.indexOf(text) === 0 ? 0 : 1;
      if (aMatch !== bMatch) return aMatch - bMatch;
      return String(a.displaySymbol || a.symbol).localeCompare(String(b.displaySymbol || b.symbol));
    });

    return filtered.slice(0, 10).map(instrument => instrument.id);
  }

  // 导出配置
  function exportConfig() {
    const config = {
      watchList: root.watchList,
      barCoin: root.barCoin,
      displayMode: root.displayMode,
      panelPosition: root.panelPosition,
      redRises: root.redRises,
      refreshInterval: root.refreshInterval,
      dataSource: root.dataSource,
      marketType: root.marketType,
      proxyUrl: root.proxyUrl,
      language: root.language
    };
    config.watchListSchemaVersion = root.watchListSchemaVersion;
    configFile.setText(JSON.stringify(config, null, 2));
  }

  function importConfig() {
    if (importConfigProc.running) return;
    importConfigProc.command = ["cat", root.configPath];
    importConfigProc.running = true;
  }

  function finishImportConfig(exitCode, stdoutText, stderrText) {
    if (exitCode !== 0) {
      root.importOk = false;
      root.importMessage = tr("settings.configImportMissing");
      root.importNonce++;
      return;
    }

    const text = String(stdoutText || "").trim();
    if (text === "") {
      root.importOk = false;
      root.importMessage = tr("settings.configImportMissing");
      root.importNonce++;
      return;
    }

    try {
      const imported = JSON.parse(text);
      const normalized = normalizeImportedConfig(imported);
      applyConfig(normalized, true);
      root.importOk = true;
      root.importMessage = tr("settings.configImported");
    } catch (e) {
      root.importOk = false;
      root.importMessage = tr("settings.configImportFailed") + ": " + e;
    }
    root.importNonce++;
  }

  function normalizeImportedConfig(config) {
    const validSources = ["huobi", "binance", "okx", "coingecko"];
    const validModes = ["text", "compact"];
    const validPanelPositions = ["center", "click"];
    const validLanguages = ["en", "zh-CN", "zh"];
    const validMarketTypes = root.marketTypes;
    const next = {
      watchList: root.watchList,
      barCoin: root.barCoin,
      displayMode: root.displayMode,
      panelPosition: root.panelPosition,
      redRises: root.redRises,
      refreshInterval: root.refreshInterval,
      dataSource: root.dataSource,
      marketType: root.marketType,
      proxyUrl: root.proxyUrl,
      language: root.language
    };

    if (Array.isArray(config.watchList)) {
      const coins = normalizeWatchList(config.watchList);
      if (coins.length > 0) next.watchList = coins;
    }
    if (typeof config.barCoin === "string" && config.barCoin.trim() !== "") next.barCoin = normalizeWatchReference(config.barCoin);
    if (validModes.includes(config.displayMode)) next.displayMode = config.displayMode;
    if (validPanelPositions.includes(config.panelPosition)) next.panelPosition = config.panelPosition;
    if (typeof config.redRises === "boolean") next.redRises = config.redRises;
    if (typeof config.refreshInterval === "number") next.refreshInterval = Math.max(1, Math.min(60, Math.round(config.refreshInterval)));
    if (validSources.includes(config.dataSource)) next.dataSource = config.dataSource;
    if (validMarketTypes.includes(config.marketType)) next.marketType = config.marketType;
    if (typeof config.proxyUrl === "string") next.proxyUrl = config.proxyUrl;
    if (validLanguages.includes(config.language)) next.language = config.language === "zh" ? "zh-CN" : config.language;

    if (!next.watchList.includes(next.barCoin)) {
      next.barCoin = next.watchList[0];
    }

    return next;
  }

  function applyConfig(config, persist) {
    const previousProxyUrl = root.proxyUrl;
    const previousDataSource = root.dataSource;
    const previousMarketType = root.marketType;
    const nextDataSource = config.dataSource;
    const nextMarketType = nextDataSource === "coingecko" ? "spot" : (root.marketTypes.includes(config.marketType) ? config.marketType : "spot");
    const providerChanged = previousDataSource !== nextDataSource || previousMarketType !== nextMarketType;
    const rawWatchList = Array.isArray(config.watchList) ? config.watchList : root.watchList;
    const targetPrefix = nextDataSource + ":" + nextMarketType + ":";
    const nextWatchList = providerChanged
      ? normalizeWatchList(rawWatchList.map(reference => {
        const text = String(reference?.id ?? reference ?? "");
        return text.indexOf(targetPrefix) === 0 ? text : root.getInstrumentSymbol(reference);
      }))
      : normalizeWatchList(rawWatchList);
    root.watchList = nextWatchList.length > 0 ? nextWatchList : root.watchList;
    const rawBarCoin = String(config.barCoin?.id ?? config.barCoin ?? "");
    root.barCoin = providerChanged
      ? (rawBarCoin.indexOf(targetPrefix) === 0 ? rawBarCoin : root.getInstrumentSymbol(config.barCoin))
      : normalizeWatchReference(config.barCoin);
    if (!root.watchList.includes(root.barCoin)) {
      root.barCoin = root.watchList[0];
    }
    root.displayMode = config.displayMode;
    root.panelPosition = config.panelPosition === "click" ? "click" : "center";
    root.redRises = config.redRises;
    root.refreshInterval = Math.max(1, Math.min(60, config.refreshInterval));
    root.dataSource = nextDataSource;
    root.marketType = nextMarketType;
    root.proxyUrl = config.proxyUrl;
    root.language = config.language;
    root.marketData = ({});
    root.quoteStates = ({});
    root.isLoading = true;
    root.errorMessage = "";
    root.dataGeneration++;
    root.quoteQueue = [];
    root.queuedQuoteIds = ({});
    root.refreshNonce++;

    if (providerChanged) {
      root.persistResolvedWatchListPending = persist === true;
      root.instruments = [];
      root.instrumentById = ({});
      root.instrumentBySymbol = ({});
      root.ambiguousSymbols = ({});
      root.allCoinsList = [];
      root.catalogReady = false;
      root.catalogError = "";
      root.catalogCacheUpdatedAt = 0;
      root.catalogFromCache = false;
      root.loadCatalogCache();
    }

    if (previousProxyUrl !== root.proxyUrl || providerChanged) {
      root.logoFailures = ({});
      root.fetchCoinsList(true);
    }

    if (root.catalogReady) root.resolveLegacyWatchList();

    if (persist) {
      const resolvedSchema = !providerChanged || root.catalogReady;
      root.persistCurrentSettings(resolvedSchema ? root.watchListSchemaVersion : 1);
      if (resolvedSchema) root.persistResolvedWatchListPending = false;
    }

    if (!providerChanged) root.refreshMarketData(true);
  }

  function persistCurrentSettings(schemaVersion) {
    if (!pluginApi) return;
    pluginApi.pluginSettings.watchList = root.watchList;
    pluginApi.pluginSettings.barCoin = root.barCoin;
    pluginApi.pluginSettings.displayMode = root.displayMode;
    pluginApi.pluginSettings.panelPosition = root.panelPosition;
    pluginApi.pluginSettings.redRises = root.redRises;
    pluginApi.pluginSettings.refreshInterval = root.refreshInterval;
    pluginApi.pluginSettings.dataSource = root.dataSource;
    pluginApi.pluginSettings.marketType = root.marketType;
    pluginApi.pluginSettings.proxyUrl = root.proxyUrl;
    pluginApi.pluginSettings.language = root.language;
    pluginApi.pluginSettings.watchListSchemaVersion = schemaVersion;
    pluginApi.saveSettings();
  }

  // 获取币种列表
  function fetchCoinsList(force) {
    if (coinsListProc.running) {
      if (force) root.coinsListRefetchPending = true;
      return;
    }
    root.coinsListRefetchPending = false;
    const url = getSymbolsUrl();
    if (url === "") {
      root.catalogError = "unsupported-provider";
      return;
    }
    const effectiveType = root.dataSource === "coingecko" ? "spot" : root.marketType;
    root.catalogRequestGeneration = root.dataGeneration;
    root.catalogRequestProvider = root.dataSource;
    root.catalogRequestMarketType = effectiveType;
    coinsListProc.command = proxyUrl ? ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", "-x", proxyUrl, url] : ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30", url];
    coinsListProc.running = true;
  }

  function getSymbolsUrl() {
    const effectiveType = root.dataSource === "coingecko" ? "spot" : root.marketType;
    return MarketProviders.instrumentsUrl(root.dataSource, effectiveType);
  }

  function parseSymbolsResponse(response, provider, type) {
    const selectedProvider = provider || root.dataSource;
    const effectiveType = selectedProvider === "coingecko" ? "spot" : (type || root.marketType);
    return MarketProviders.parseInstruments(selectedProvider, effectiveType, response);
  }

  function setInstrumentCatalog(nextInstruments, fromCache, cacheUpdatedAt) {
    if (!Array.isArray(nextInstruments) || nextInstruments.length === 0) return false;

    const byId = {};
    const bySymbol = {};
    const ambiguous = {};
    const ids = [];
    const effectiveType = root.dataSource === "coingecko" ? "spot" : root.marketType;
    for (let i = 0; i < nextInstruments.length; i++) {
      const instrument = nextInstruments[i];
      if (!instrument || !instrument.id || !instrument.symbol) continue;
      if (instrument.provider !== root.dataSource || instrument.marketType !== effectiveType) continue;
      byId[instrument.id] = instrument;
      if (!bySymbol[instrument.symbol]) {
        bySymbol[instrument.symbol] = instrument;
      } else {
        ambiguous[instrument.symbol] = true;
      }
      ids.push(instrument.id);
    }
    if (ids.length === 0) return false;

    root.instruments = ids.map(id => byId[id]);
    root.instrumentById = byId;
    root.instrumentBySymbol = bySymbol;
    root.ambiguousSymbols = ambiguous;
    root.allCoinsList = ids;
    root.catalogReady = true;
    root.catalogError = fromCache ? "stale-cache" : "";
    root.catalogCacheUpdatedAt = fromCache ? Number(cacheUpdatedAt || 0) : Date.now();
    root.catalogFromCache = fromCache === true;
    root.errorMessage = "";
    root.resolveLegacyWatchList();
    root.refreshNonce++;

    if (root.persistResolvedWatchListPending) {
      root.persistCurrentSettings(root.watchListSchemaVersion);
      root.persistResolvedWatchListPending = false;
    }

    if (!root.isLoading || root.watchList.length > 0) root.refreshMarketData(false);

    if (!fromCache) root.saveCatalogCache();
    return true;
  }

  function resolveLegacyWatchList() {
    const migrated = [];
    const seen = {};
    for (let i = 0; i < root.watchList.length; i++) {
      const reference = root.watchList[i];
      const exact = root.instrumentById[String(reference || "")];
      const key = root.normalizeAssetKey(reference);
      const instrument = exact || (!root.ambiguousSymbols[key] ? root.instrumentBySymbol[key] : null);
      const nextReference = instrument ? instrument.id : root.normalizeWatchReference(reference);
      if (nextReference !== "" && !seen[nextReference]) {
        seen[nextReference] = true;
        migrated.push(nextReference);
      }
    }

    root.watchList = migrated;
    const currentBarInstrument = root.getInstrument(root.barCoin);
    if (currentBarInstrument && root.instrumentById[currentBarInstrument.id]) {
      root.barCoin = currentBarInstrument.id;
    } else if (migrated.length > 0) {
      root.barCoin = migrated[0];
    }
  }

  function loadCatalogCache() {
    if (catalogCacheFile.path !== "") catalogCacheFile.reload();
  }

  function applyCatalogCache(text) {
    if (root.catalogReady || !text || String(text).trim() === "") return;
    try {
      const cache = JSON.parse(String(text));
      const effectiveType = root.dataSource === "coingecko" ? "spot" : root.marketType;
      if (cache.provider !== root.dataSource || cache.marketType !== effectiveType || !Array.isArray(cache.instruments)) return;
      root.setInstrumentCatalog(cache.instruments, true, cache.updatedAt);
    } catch (e) {
      Logger.w("CryptoMarket", "Failed to parse cached instrument catalog: " + e);
    }
  }

  function saveCatalogCache() {
    const effectiveType = root.dataSource === "coingecko" ? "spot" : root.marketType;
    catalogCacheFile.setText(JSON.stringify({
      provider: root.dataSource,
      marketType: effectiveType,
      updatedAt: Date.now(),
      instruments: root.instruments
    }));
  }

  function setCatalogFailure(code, message) {
    root.catalogError = code;
    if (!root.catalogReady) {
      root.isLoading = false;
      root.errorMessage = root.tr("panel.catalogError");
    }
    Logger.w("CryptoMarket", message);
  }

  Process {
    id: coinsListProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: exitCode => {
      const requestIsCurrent = root.catalogRequestGeneration === root.dataGeneration
        && root.catalogRequestProvider === root.dataSource
        && root.catalogRequestMarketType === (root.dataSource === "coingecko" ? "spot" : root.marketType);
      if (!requestIsCurrent) {
        Logger.d("CryptoMarket", "Discarded obsolete instrument catalog response [" + root.catalogRequestProvider + "/" + root.catalogRequestMarketType + "]");
      } else if (exitCode === 0) {
        try {
          const text = String(stdout.text);
          const response = JSON.parse(text);
          const parsedInstruments = parseSymbolsResponse(response, root.catalogRequestProvider, root.catalogRequestMarketType);
          if (!root.setInstrumentCatalog(parsedInstruments, false)) {
            root.setCatalogFailure("empty-catalog", "Provider returned no supported instruments for " + root.dataSource + "/" + root.marketType);
          }
        } catch (e) {
          root.setCatalogFailure("parse-error", "Failed to parse coin list for " + root.dataSource + "/" + root.marketType + ": " + e);
        }
      } else {
        root.setCatalogFailure("network-error", "Failed to fetch coin list for " + root.dataSource + "/" + root.marketType + ": " + String(stderr.text));
        root.loadCatalogCache();
      }
      if (root.coinsListRefetchPending) {
        root.fetchCoinsList(false);
      }
    }
  }
}
