import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null

  property var cfg: pluginApi?.pluginSettings || ({})
  property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  property var editWatchList: cfg.watchList ?? defaults.watchList ?? ["btc", "eth", "bnb", "sol", "xrp"]
  // 旧配置没有 barWatchList 时从 barCoin 播种，与 Main.seedBarWatchList() 保持同一套规则。
  property var editBarWatchList: cfg.barWatchList ?? (cfg.barCoin ? [cfg.barCoin] : undefined) ?? defaults.barWatchList ?? [defaults.barCoin ?? "btc"]
  property int editBarScrollInterval: cfg.barScrollInterval ?? defaults.barScrollInterval ?? 5
  property string editDisplayMode: cfg.displayMode ?? defaults.displayMode ?? "text"
  property string editPanelPosition: cfg.panelPosition ?? defaults.panelPosition ?? "center"
  property bool editRedRises: cfg.redRises ?? defaults.redRises ?? false
  property int editRefreshInterval: cfg.refreshInterval ?? defaults.refreshInterval ?? 5
  property string editDataSource: cfg.dataSource ?? defaults.dataSource ?? "huobi"
  property string editMarketType: cfg.marketType ?? defaults.marketType ?? "spot"
  property string editProxyUrl: cfg.proxyUrl ?? defaults.proxyUrl ?? ""
  property string editLanguage: cfg.language ?? defaults.language ?? "en"

  property string configMessage: ""
  property bool configMessageIsError: false
  property string searchText: ""
  readonly property int localeTick: mainInstance?.refreshNonce ?? 0

  readonly property var mainInstance: pluginApi?.mainInstance

  spacing: Style.marginM

  function tr(key) {
    const tick = root.localeTick;
    return mainInstance ? mainInstance.tr(key) : key;
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.language")
    description: tr("settings.languageDesc")
    minimumWidth: 240
    model: [
      { "key": "en", "name": "English" },
      { "key": "zh-CN", "name": "中文" }
    ]
    currentKey: root.editLanguage
    defaultValue: defaults.language ?? "en"
    onSelected: key => {
      root.editLanguage = key;
      if (mainInstance) {
        mainInstance.language = key;
        mainInstance.refreshNonce++;
      }
    }
  }

  NDivider {
    Layout.fillWidth: true
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.dataSource")
    description: tr("settings.dataSourceDesc")
    minimumWidth: 240
    model: [
      { "key": "huobi", "name": tr("dataSource.huobi") },
      { "key": "binance", "name": tr("dataSource.binance") },
      { "key": "okx", "name": tr("dataSource.okx") },
      { "key": "coingecko", "name": tr("dataSource.coingecko") }
    ]
    currentKey: root.editDataSource
    defaultValue: defaults.dataSource ?? "huobi"
    onSelected: key => {
      root.editDataSource = key;
      if (key === "coingecko") {
        root.editMarketType = "spot";
      }
    }
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.marketType")
    description: tr("settings.marketTypeDesc")
    minimumWidth: 240
    visible: root.editDataSource !== "coingecko"
    model: [
      { "key": "spot", "name": tr("marketType.spot") },
      { "key": "perpetual", "name": tr("marketType.perpetual") }
    ]
    currentKey: root.editMarketType
    defaultValue: defaults.marketType ?? "spot"
    onSelected: key => root.editMarketType = key
  }

  NTextInput {
    Layout.fillWidth: true
    label: tr("settings.proxy")
    placeholderText: tr("settings.proxyPlaceholder")
    text: root.editProxyUrl
    onTextChanged: root.editProxyUrl = text
  }

  NText {
    text: tr("settings.proxyTip")
    pointSize: Style.fontSizeXS
    color: Color.mOnSurfaceVariant
  }

  NDivider {
    Layout.fillWidth: true
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.displayMode")
    description: tr("settings.displayModeDesc")
    minimumWidth: 240
    model: [
      { "key": "text", "name": tr("settings.displayModeFull") },
      { "key": "compact", "name": tr("settings.displayModeCompact") }
    ]
    currentKey: root.editDisplayMode
    defaultValue: defaults.displayMode ?? "text"
    onSelected: key => root.editDisplayMode = key
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.panelPosition")
    description: tr("settings.panelPositionDesc")
    minimumWidth: 240
    model: [
      { "key": "center", "name": tr("settings.panelPositionCenter") },
      { "key": "click", "name": tr("settings.panelPositionClick") }
    ]
    currentKey: root.editPanelPosition
    defaultValue: defaults.panelPosition ?? "center"
    onSelected: key => root.editPanelPosition = key
  }

  NDivider {
    Layout.fillWidth: true
  }

  NText {
    text: tr("settings.watchList")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mOnSurface
  }

  NText {
    text: tr("settings.watchListTip")
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
  }

  NText {
    text: tr("settings.search")
    pointSize: Style.fontSizeS
    font.weight: Style.fontWeightBold
    color: Color.mOnSurfaceVariant
  }

  NTextInput {
    Layout.fillWidth: true
    placeholderText: tr("settings.searchPlaceholder")
    text: root.searchText
    onTextChanged: root.searchText = text.toLowerCase()
  }

  NText {
    text: tr("settings.searchResults")
    pointSize: Style.fontSizeXS
    color: Color.mOnSurfaceVariant
    visible: root.searchText !== ""
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginS
    visible: root.searchText !== ""

    Repeater {
      model: getSearchResults()
      delegate: NButton {
        text: getCoinName(modelData)
        visible: !root.editWatchList.includes(modelData)
        onClicked: {
          addCoin(modelData);
          root.searchText = "";
        }
      }
    }
  }

  Repeater {
    model: root.editWatchList
    delegate: RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      NToggle {
        label: getCoinName(modelData)
        checked: true
        onToggled: checked => toggleCoin(modelData, checked)
        Layout.fillWidth: true
      }

      NIconButton {
        icon: root.isBarAsset(modelData) ? "pin" : "unpin"
        tooltipText: tr("settings.barAssetsToggle")
        colorFg: root.isBarAsset(modelData) ? Color.mPrimary : Color.mOnSurfaceVariant
        baseSize: Style.baseWidgetSize * 0.7
        onClicked: toggleBarAsset(modelData)
      }

      NIconButton {
        icon: "arrow-up"
        enabled: index > 0
        baseSize: Style.baseWidgetSize * 0.7
        onClicked: moveCoinUp(modelData)
      }

      NIconButton {
        icon: "arrow-down"
        enabled: index < root.editWatchList.length - 1
        baseSize: Style.baseWidgetSize * 0.7
        onClicked: moveCoinDown(modelData)
      }
    }
  }

  NText {
    text: tr("settings.barAssets")
    pointSize: Style.fontSizeS
    font.weight: Style.fontWeightBold
    color: Color.mOnSurfaceVariant
  }

  NText {
    text: tr("settings.barAssetsTip")
    pointSize: Style.fontSizeXS
    color: Color.mOnSurfaceVariant
  }

  NLabel {
    label: tr("settings.barScrollInterval") + ": " + Math.round(root.editBarScrollInterval) + " " + tr("settings.seconds")
    description: tr("settings.barScrollIntervalDesc")
  }

  NSlider {
    Layout.fillWidth: true
    from: 2
    to: 60
    stepSize: 1
    value: root.editBarScrollInterval
    onValueChanged: root.editBarScrollInterval = Math.round(value)
  }

  NDivider {
    Layout.fillWidth: true
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.colorScheme")
    description: tr("settings.colorSchemeDesc")
    minimumWidth: 240
    model: [
      { "key": "red-rises", "name": tr("settings.redRises") },
      { "key": "green-rises", "name": tr("settings.greenRises") }
    ]
    currentKey: root.editRedRises ? "red-rises" : "green-rises"
    defaultValue: "green-rises"
    onSelected: key => root.editRedRises = (key === "red-rises")
  }

  NLabel {
    label: tr("settings.refreshInterval") + ": " + Math.round(root.editRefreshInterval) + " " + tr("settings.seconds")
    description: tr("settings.refreshIntervalDesc")
  }

  NSlider {
    Layout.fillWidth: true
    from: 1
    to: 60
    stepSize: 1
    value: root.editRefreshInterval
    onValueChanged: root.editRefreshInterval = Math.round(value)
  }

  NDivider {
    Layout.fillWidth: true
  }

  NText {
    text: tr("settings.configMgmt")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mOnSurface
  }

  NText {
    text: tr("settings.configPath")
    pointSize: Style.fontSizeXS
    color: Color.mOnSurfaceVariant
  }

  RowLayout {
    spacing: Style.marginM

    NButton {
      text: tr("settings.export")
      onClicked: exportConfig()
    }

    NButton {
      text: tr("settings.import")
      onClicked: importConfig()
    }
  }

  NText {
    visible: root.configMessage !== ""
    text: root.configMessage
    pointSize: Style.fontSizeS
    color: root.configMessageIsError ? Color.mError : Color.mPrimary
  }

  Connections {
    target: mainInstance

    function onImportNonceChanged() {
      root.configMessage = mainInstance.importMessage;
      root.configMessageIsError = !mainInstance.importOk;
      if (mainInstance.importOk) {
        root.syncFromMainInstance();
      }
    }
  }

  function saveSettings() {
    if (!pluginApi) return;

    const normalizedWatchList = normalizeEditWatchList();
    const normalizedBarWatchList = normalizeEditBarWatchList(normalizedWatchList);
    const nextConfig = {
      watchList: normalizedWatchList,
      barWatchList: normalizedBarWatchList,
      barCoin: normalizedBarWatchList[0],
      barScrollInterval: root.editBarScrollInterval,
      displayMode: root.editDisplayMode,
      panelPosition: root.editPanelPosition === "click" ? "click" : "center",
      redRises: root.editRedRises,
      refreshInterval: root.editRefreshInterval,
      dataSource: root.editDataSource,
      marketType: effectiveMarketType(),
      proxyUrl: root.editProxyUrl,
      language: root.editLanguage
    };

    if (mainInstance) {
      mainInstance.applyConfig(nextConfig, true);
      return;
    }

    Object.keys(nextConfig).forEach(key => pluginApi.pluginSettings[key] = nextConfig[key]);
    pluginApi.pluginSettings.watchListSchemaVersion = 1;
    pluginApi.saveSettings();
  }

  function exportConfig() {
    if (mainInstance) {
      mainInstance.exportConfig();
      root.configMessage = tr("settings.configExported");
      root.configMessageIsError = false;
    }
  }

  function importConfig() {
    if (mainInstance) {
      mainInstance.importConfig();
    }
  }

  function syncFromMainInstance() {
    root.editWatchList = mainInstance.watchList;
    root.editBarWatchList = mainInstance.barWatchList;
    root.editBarScrollInterval = mainInstance.barScrollInterval;
    root.editDisplayMode = mainInstance.displayMode;
    root.editPanelPosition = mainInstance.panelPosition;
    root.editRedRises = mainInstance.redRises;
    root.editRefreshInterval = mainInstance.refreshInterval;
    root.editDataSource = mainInstance.dataSource;
    root.editMarketType = mainInstance.marketType;
    root.editProxyUrl = mainInstance.proxyUrl;
    root.editLanguage = mainInstance.language;
  }

  function toggleCoin(coin, checked) {
    const key = normalizeAsset(coin);
    let list = [...root.editWatchList];
    if (checked) {
      if (!list.includes(key)) {
        list.push(key);
      }
    } else {
      const index = list.indexOf(key);
      if (index > -1) {
        list.splice(index, 1);
      }
      // 状态栏列表必须始终是自选列表的子集，移出自选时同步剔除。
      const barList = root.editBarWatchList.filter(reference => normalizeAsset(reference) !== key);
      if (barList.length !== root.editBarWatchList.length) root.editBarWatchList = barList;
    }
    root.editWatchList = list;
  }

  function isBarAsset(coin) {
    const key = normalizeAsset(coin);
    return root.editBarWatchList.some(reference => normalizeAsset(reference) === key);
  }

  function toggleBarAsset(coin) {
    const key = normalizeAsset(coin);
    if (isBarAsset(coin)) {
      root.editBarWatchList = root.editBarWatchList.filter(reference => normalizeAsset(reference) !== key);
    } else {
      root.editBarWatchList = [...root.editBarWatchList, key];
    }
  }

  function moveCoinUp(coin) {
    let list = [...root.editWatchList];
    const index = list.indexOf(coin);
    if (index > 0) {
      [list[index - 1], list[index]] = [list[index], list[index - 1]];
      root.editWatchList = list;
    }
  }

  function moveCoinDown(coin) {
    let list = [...root.editWatchList];
    const index = list.indexOf(coin);
    if (index < list.length - 1) {
      [list[index], list[index + 1]] = [list[index + 1], list[index]];
      root.editWatchList = list;
    }
  }

  function getCoinName(coin) {
    if (mainInstance) {
      const instrument = mainInstance.getInstrument(coin);
      const name = mainInstance.getCoinName(coin);
      return instrument?.status === "unresolved" ? name + " (" + tr("settings.unavailable") + ")" : name;
    }
    return String(coin || "").toUpperCase();
  }

  function normalizeAsset(symbol) {
    return mainInstance ? mainInstance.getInstrumentId(symbol) : String(symbol || "").trim().toLowerCase();
  }

  function normalizeEditWatchList() {
    const result = [];
    const seen = {};
    for (let i = 0; i < root.editWatchList.length; i++) {
      const key = normalizeAsset(root.editWatchList[i]);
      if (key !== "" && !seen[key]) {
        seen[key] = true;
        result.push(key);
      }
    }
    return result.length > 0 ? result : ["btc"];
  }

  // 与 Main.normalizeBarWatchList() 同规则：约束为自选子集、按自选排序、非空回退。
  function normalizeEditBarWatchList(watchList) {
    const requested = {};
    for (let i = 0; i < root.editBarWatchList.length; i++) {
      const key = normalizeAsset(root.editBarWatchList[i]);
      if (key !== "") requested[key] = true;
    }

    const result = watchList.filter(reference => requested[reference] === true);
    return result.length > 0 ? result : [watchList[0]];
  }

  function effectiveMarketType() {
    return root.editDataSource === "coingecko" ? "spot" : root.editMarketType;
  }

  function getSearchResults() {
    if (!root.searchText || root.searchText === "") {
      return [];
    }
    if (mainInstance) {
      return mainInstance.searchCoinSymbols(root.searchText);
    }
    return [];
  }

  function addCoin(coin) {
    const key = normalizeAsset(coin);
    let list = [...root.editWatchList];
    if (key !== "" && !list.includes(key)) {
      list.push(key);
      root.editWatchList = list;
    }
  }
}
