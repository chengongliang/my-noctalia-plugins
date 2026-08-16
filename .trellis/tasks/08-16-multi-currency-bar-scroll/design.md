# 技术设计：状态栏多币种滚动

## 1. 边界

改动集中在 `market-watch` 插件，不触碰 `hermes-agent` 与 Python 桥接。

| 文件 | 角色 | 改动性质 |
| --- | --- | --- |
| `market-watch/Main.qml` | 共享状态、设置回退链、导入导出 | 新增 2 个持久化字段 + 3 个函数，改 5 处已有函数 |
| `market-watch/BarWidget.qml` | 状态栏渲染 | 重写渲染与状态解析，新增轮播定时器与滑动动画 |
| `market-watch/Settings.qml` | 设置页 | 移除 `barCoin` 下拉框，行内新增开关，新增间隔滑块 |
| `market-watch/manifest.json` | 默认设置 + 版本 | 新增 2 个默认值，版本 1.1.0 → 1.2.0 |
| `market-watch/i18n/{en,zh-CN}.json` | 用户文案 | 新增 5 键，移除 2 键 |
| `market-watch/README{,_CN}.md` | 文档 | 设置说明 + 默认配置块 |
| `registry.json` | 插件登记 | 版本 + `lastUpdated` |

`Panel.qml`、`MarketProviders.js`、`tests/` 不改动。

## 2. 数据契约

### 2.1 新增持久化字段

```jsonc
{
  "barWatchList": ["btc"],   // watchList 的子集，顺序不持久化语义（读取时按 watchList 排序）
  "barScrollInterval": 5     // 秒，2-60
}
```

`barCoin` **保留**，语义降级为「派生兼容字段」：持久化时始终写入 `barWatchList[0]`。它不再驱动任何渲染，只服务于配置导入导出和旧版本插件回滚。

### 2.2 不变式

1. `barWatchList ⊆ watchList`
2. `barWatchList` 的顺序恒等于它在 `watchList` 中出现的顺序
3. `barWatchList.length >= 1`，当 `watchList` 非空时
4. `barCoin === barWatchList[0]`

这四条由 `Main.normalizeBarWatchList()` 单点保证，所有写入路径都必须经过它。

## 3. Main.qml

### 3.1 新增属性

```qml
property var barWatchList: []                       // Component.onCompleted 中播种
property int barScrollInterval: Math.max(2, Math.min(60,
  cfg.barScrollInterval ?? defaults.barScrollInterval ?? 5))
```

### 3.2 新增函数

```qml
// 升级播种：cfg 有新字段用新字段；否则从旧 barCoin 播种；否则用 manifest 默认值。
// 这一步保证升级用户的状态栏显示资产不变。
function seedBarWatchList() {
  if (Array.isArray(cfg.barWatchList)) return cfg.barWatchList;
  if (typeof cfg.barCoin === "string" && cfg.barCoin.trim() !== "") return [cfg.barCoin];
  if (Array.isArray(defaults.barWatchList)) return defaults.barWatchList;
  return [defaults.barCoin ?? "btc"];
}

// 唯一的规范化入口：去重 + 约束为 watchList 子集 + 按 watchList 排序 + 非空回退。
function normalizeBarWatchList(list) {
  const requested = {};
  const raw = Array.isArray(list) ? list : [];
  for (let i = 0; i < raw.length; i++) {
    const reference = normalizeWatchReference(raw[i]);
    if (reference !== "") requested[reference] = true;
  }
  const result = root.watchList.filter(reference => requested[reference] === true);
  if (result.length > 0) return result;
  return root.watchList.length > 0 ? [root.watchList[0]] : [];
}

// 不变式 4
function syncBarCoin() {
  root.barCoin = root.barWatchList.length > 0 ? root.barWatchList[0] : "";
}
```

### 3.3 改动的已有函数

| 函数 | 改动 |
| --- | --- |
| `Component.onCompleted` | `watchList` 规范化之后调用 `barWatchList = normalizeBarWatchList(seedBarWatchList())`，再 `syncBarCoin()`；移除原来「barCoin 不在 watchList 就取 watchList[0]」的逻辑（已被不变式覆盖） |
| `resolveLegacyWatchList()` | 迁移 `watchList` 时同步建立 `原引用 → 迁移后引用` 映射，用它重映射 `barWatchList` 后再 `normalizeBarWatchList()`，最后 `syncBarCoin()` |
| `applyConfig(config, persist)` | 与 `watchList` 相同的 provider 切换重映射逻辑套用到 `config.barWatchList`；`barScrollInterval` 夹取到 2–60；先算 `watchList` 再算 `barWatchList`，最后 `syncBarCoin()` |
| `normalizeImportedConfig(config)` | `Array.isArray(config.barWatchList)` 时接受；`typeof config.barScrollInterval === "number"` 时 `Math.max(2, Math.min(60, Math.round(v)))` |
| `exportConfig()` / `persistCurrentSettings()` | 写入 `barWatchList` 与 `barScrollInterval`，`barCoin` 写 `barWatchList[0]` |

`resolveLegacyWatchList()` 的映射构造（当前循环里已经算出 `nextReference`，只需顺手记一笔）：

```qml
const refMap = {};
// ... 现有循环内：
refMap[String(reference || "")] = nextReference;
// ... 循环后：
root.watchList = migrated;
root.barWatchList = normalizeBarWatchList(
  root.barWatchList.map(reference => refMap[String(reference || "")] ?? reference));
syncBarCoin();
```

### 3.4 抓取逻辑不变

`refreshMarketData()` 仍只遍历 `watchList`。因为 `barWatchList ⊆ watchList`，状态栏显示的每个资产都必然在抓取范围内——这正是选择「子集」方案而非独立列表的核心收益。右键菜单的「立即刷新」也无需改动。

## 4. BarWidget.qml

### 4.1 状态解析（替换全局 isLoading/errorMessage）

`Main.qml` 已有 per-instrument 的 `quoteStates[id]`，当前 BarWidget 完全没用。新增单一解析函数，把它和 `marketData` 收敛成一个视图对象：

```qml
function assetView(reference) {
  const t = tick;                                  // 依赖 refreshNonce 触发重算
  const id = mainInstance?.getInstrumentId(reference) ?? String(reference);
  const symbol = mainInstance?.getInstrumentDisplaySymbol(reference) ?? String(reference).toUpperCase();
  const data = mainInstance?.marketData[id];
  const state = mainInstance?.quoteStates[id];

  let status = "loading";
  if (data) status = "ready";                       // stale 也走 ready：优先显示已有最新价
  else if (state?.errorCode === "unavailable") status = "unavailable";
  else if (state?.status === "error") status = "error";

  return {
    symbol: symbol,
    data: data,
    status: status,
    message: state?.errorMessage || mainInstance?.errorMessage || ""
  };
}
```

### 4.2 渲染表

| status | text 模式 | compact 模式 | suffix | 背景/前景 |
| --- | --- | --- | --- | --- |
| `ready` | `BTC 45,230` | `45,230` | `↑` / `↓` | transparent |
| `loading` | `BTC ...` | `...` | `` | transparent |
| `unavailable` | `BTC ✕` | `✕` | `` | `#3a3a3a` / `#888888` |
| `error` | `BTC ⚠` | `⚠` | `` | `#3a3a3a` / `#888888` |

工具提示：

- `ready` → `SYM\n最新价: X\n涨跌幅: Y`（沿用现有 `panel.price` / `panel.change`）
- `loading` → `panel.loading`
- `unavailable` → `SYM — settings.unavailable`（复用已有键，见 §7）
- `error` → `SYM — panel.error: <message>`

**关键行为差异**：这些状态现在是**逐资产**的。单条资产网络失败只让它自己那一帧显示 `⚠`，其余资产轮播到时照常显示价格——满足 PRD「不得因单条资产失败清空整个小部件」。

### 4.3 轮播与动画

结构：在 `BarPill` 外包一层裁剪容器，**只用一个 `BarPill` 实例**（点击/右键/工具提示绑定不需要复制），靠 `y` 位移做「上滑移出 → 换内容 → 下方滑入」。

```qml
Item {
  id: root
  implicitWidth: scrollClip.implicitWidth
  implicitHeight: scrollClip.implicitHeight

  readonly property var barAssets: mainInstance?.barWatchList ?? []
  readonly property int scrollIntervalMs: Math.max(2, Math.min(60,
    mainInstance?.barScrollInterval ?? 5)) * 1000
  property int currentIndex: 0
  readonly property var currentAsset: barAssets.length > 0
    ? barAssets[Math.min(currentIndex, barAssets.length - 1)] : ""

  Item {
    id: scrollClip
    anchors.fill: parent
    clip: true
    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight
    Behavior on implicitWidth { NumberAnimation { duration: Style.animationFast; easing.type: Easing.OutCubic } }

    BarPill { id: pill; /* y 自由，不绑定 */ }
  }

  Timer {
    interval: root.scrollIntervalMs
    repeat: true
    running: root.barAssets.length > 1
    onTriggered: if (!scrollAnim.running) scrollAnim.restart()
  }

  SequentialAnimation {
    id: scrollAnim
    ParallelAnimation {
      NumberAnimation { target: pill; property: "y"; to: -scrollClip.height; duration: 160; easing.type: Easing.InCubic }
      NumberAnimation { target: pill; property: "opacity"; to: 0; duration: 160 }
    }
    ScriptAction { script: {
      root.currentIndex = (root.currentIndex + 1) % Math.max(1, root.barAssets.length);
      pill.y = scrollClip.height;
    } }
    ParallelAnimation {
      NumberAnimation { target: pill; property: "y"; to: 0; duration: 200; easing.type: Easing.OutCubic }
      NumberAnimation { target: pill; property: "opacity"; to: 1; duration: 200 }
    }
  }

  onBarAssetsChanged: {
    scrollAnim.stop();
    pill.y = 0; pill.opacity = 1;
    if (currentIndex >= barAssets.length) currentIndex = 0;
  }
}
```

要点：

- **内容替换发生在 pill 完全移出裁剪区时**，所以文字宽度突变不可见，滑入时已是新宽度。
- **宽度平滑**：`Behavior on implicitWidth` 让状态栏邻居部件平滑让位而不是瞬跳。副作用是滑入的 ~150ms 内 `pill.width`（瞬变）与 `scrollClip.width`（渐变）短暂不等，可能有轻微裁边。手动验证若观感不佳，回退方案是去掉 Behavior 让宽度瞬变（此刻 pill 不可见，视觉代价只是邻居部件瞬移）。
- **单条不滚**：`running: barAssets.length > 1` 直接满足验收条件。
- **垂直状态栏**：`BarPill` 内部按 `Settings.getBarPositionForScreen()` 切换水平/垂直子组件；本设计只操作外层 `y` 与裁剪盒，两种朝向都按 `scrollClip.height` 位移，语义一致，但必须双向手动验证。

### 4.4 被否决的方案

- **`qs.Widgets.NSlideSwapView`**：仓库规则要求先找现成件。它确实做滑动换页，但（1）位移轴是 `x`（水平），PRD 要的是上下；（2）`swap()` 在 `width <= 0 || height <= 0` 时直接跳过动画，而状态栏部件宽度由内容驱动、初始为 0；（3）内部用 `ShaderEffectSource` 截屏，对一个高频重绘的窄条部件是不必要的开销。故不复用。
- **两个 `BarPill` 堆叠对滑**：需要复制 `onClicked` / `onRightClicked` / `tooltipText` 绑定，并处理两条不同宽度的实例，收益不抵复杂度。
- **改 `BarPill` 支持自定义内容**：`BarPill` 属于 Noctalia Shell（`/etc/xdg/quickshell/noctalia-shell/`），不是本仓库资产，不能改。

## 5. Settings.qml

### 5.1 编辑副本

```qml
property var editBarWatchList: cfg.barWatchList
  ?? (cfg.barCoin ? [cfg.barCoin] : undefined)
  ?? defaults.barWatchList ?? [defaults.barCoin ?? "btc"]
property int editBarScrollInterval: cfg.barScrollInterval ?? defaults.barScrollInterval ?? 5
```

移除 `editBarCoin` 及其 `NComboBox`（现 `Settings.qml:117-126`）和 `buildBarCoinModel()`。

### 5.2 行内开关

现有自选列表 `Repeater` 的每一行（`Settings.qml:212-239`）在两个排序箭头之前插入：

```qml
NIconButton {
  icon: root.isBarAsset(modelData) ? "pin" : "unpin"
  tooltipText: tr("settings.barAssetsToggle")
  colorFg: root.isBarAsset(modelData) ? Color.mPrimary : Color.mOnSurfaceVariant
  baseSize: Style.baseWidgetSize * 0.7
  onClicked: toggleBarAsset(modelData)
}
```

配套函数：

```qml
function isBarAsset(coin) { return root.editBarWatchList.includes(normalizeAsset(coin)); }

function toggleBarAsset(coin) {
  const key = normalizeAsset(coin);
  const list = [...root.editBarWatchList];
  const index = list.indexOf(key);
  if (index > -1) list.splice(index, 1); else list.push(key);
  root.editBarWatchList = list;
}
```

`toggleCoin(coin, false)`（从自选移除）必须同步剔除 `editBarWatchList` 中的同一项，否则会短暂违反不变式 1。

### 5.3 间隔滑块

紧跟自选列表 `Repeater` 之后（与状态栏开关同一视觉分组）：

```qml
NLabel {
  label: tr("settings.barScrollInterval") + ": " + Math.round(root.editBarScrollInterval) + " " + tr("settings.seconds")
  description: tr("settings.barScrollIntervalDesc")
}
NSlider { Layout.fillWidth: true; from: 2; to: 60; stepSize: 1
  value: root.editBarScrollInterval
  onValueChanged: root.editBarScrollInterval = Math.round(value) }
```

### 5.4 保存与同步

`saveSettings()` 的 `nextConfig` 增加：

```qml
barWatchList: normalizedBarWatchList,          // normalizedWatchList.filter(ref => barSet[ref]),空则 [normalizedWatchList[0]]
barScrollInterval: root.editBarScrollInterval,
barCoin: normalizedBarWatchList[0],            // 派生兼容字段
```

`syncFromMainInstance()` 增加 `editBarWatchList` / `editBarScrollInterval`，移除 `editBarCoin`。

## 6. 兼容与迁移

| 场景 | 行为 |
| --- | --- |
| 全新安装 | manifest 默认 `barWatchList: ["btc"]`、`barScrollInterval: 5` |
| 旧配置有 `barCoin: "huobi:spot:ethusdt"`，无 `barWatchList` | `seedBarWatchList()` 播种为 `["huobi:spot:ethusdt"]`，状态栏显示资产与升级前**完全一致** |
| 旧配置 `barCoin` 已不在 `watchList` 中 | `normalizeBarWatchList()` 过滤后为空 → 回退 `[watchList[0]]`，与现有 `Component.onCompleted` 的兜底一致 |
| 用户降级回 1.1.0 | 1.1.0 只读 `barCoin`，而我们始终把它写成 `barWatchList[0]`，降级后显示第一个轮播资产 |
| 导入的配置缺新字段 | `normalizeImportedConfig()` 的 `next` 初值取当前运行值，缺字段即保持不变 |
| 导入的 `barWatchList` 含非自选资产 | `normalizeBarWatchList()` 过滤掉 |
| 切换数据源 | 与 `watchList` 走同一套 `provider:marketType:` 前缀重映射 |

`watchListSchemaVersion` **不动**（仍为 2）。它标记的是 watchList 引用格式的迁移状态，`barWatchList` 是新增字段而非格式变更；贸然 +1 会让已解析的配置重新走 legacy 解析路径。

## 7. i18n

四处同改：`i18n/en.json`、`i18n/zh-CN.json`、`Main.qml` 内嵌 en 兜底（`Main.qml:63-104`）、内嵌 zh-CN 兜底（`Main.qml:139-180`）。

新增：

| 键 | en | zh-CN |
| --- | --- | --- |
| `settings.barAssets` | Status bar assets | 状态栏轮播资产 |
| `settings.barAssetsTip` | Pin watch-list assets to the status bar. Two or more assets scroll automatically. | 将自选资产固定到状态栏。两个及以上会自动滚动切换。 |
| `settings.barAssetsToggle` | Show in status bar | 在状态栏显示 |
| `settings.barScrollInterval` | Status bar switch interval | 状态栏切换间隔 |
| `settings.barScrollIntervalDesc` | How long each asset stays visible (2-60 seconds) | 每个资产的停留时长（2–60 秒） |

移除：`settings.barCoin`、`settings.barCoinDesc`（下拉框已删，无其他引用）。

复用而非新增：`settings.unavailable`（"Unavailable from this data source" / "当前数据源不可用"）用于状态栏不可用态的工具提示。键名在 `settings.*` 命名空间下略显别扭，但文案语义精确，重复造一个 `panel.unavailable` 违反复用规则。

## 8. 版本与发布

- `manifest.json`：`1.1.0` → `1.2.0`（新增功能，向后兼容）
- `registry.json`：同版本号 + `lastUpdated` 更新为提交当日 `+08:00` 时间戳
- 两份 README 的设置项列表与默认配置 JSON 块同步

## 9. 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 裁剪盒改变了 `BarPill` 的 `parent`，可能影响它对 `parent.height` / `parent.width` 的依赖 | 状态栏部件高度塌陷 | `scrollClip` 用 `anchors.fill: parent` 保证与原来的 `root` 同尺寸；水平/垂直栏都要手动验证 |
| `Behavior on implicitWidth` 与 pill 自身瞬变宽度不同步 | 滑入 150ms 内轻微裁边 | 手动验证；不满意则移除 Behavior（§4.3 已写回退方案） |
| 工具提示是弹出层，裁剪不应影响它 | 提示被截断 | 手动验证四种状态的提示 |
| 无法在本环境跑 QML | 逻辑错误只能靠人工发现 | 静态检查 + 结构化手动验证清单（见 implement.md 第 8 步） |

## 10. 回滚

单次提交，`git revert` 即可。持久化层是纯增量：`barWatchList` / `barScrollInterval` 是新键，`barCoin` 语义兼容且始终有效值，回滚后 1.1.0 读 `barCoin` 正常工作，不会丢失或损坏用户配置。
