# 执行计划：状态栏多币种滚动

前置：`design.md` 已定稿。所有步骤在 `chengongliang/状态栏多币种滚动支持` 分支上进行，最终合为一次提交。

## 进度

第 1–9 步已完成并通过静态验证。第 10 步（Noctalia Shell 手动验证）待执行——本环境没有运行中的 shell，
且启动它会接管用户桌面，未授权不执行。第 11 步待第 10 步之后。

### 实现期间的发现

- **修复了一个自引入缺陷**：`normalizeImportedConfig()` 最初写成「`config.barWatchList` 缺失时一律用
  `next.barCoin` 播种」。当导入的配置两个状态栏字段都没有时，`next.barCoin` 取的是当前运行值，
  会把正在轮播的多资产列表压缩成单条。已改为只在导入配置确实带了旧 `barCoin` 时才播种，
  两者皆无则保留当前 `barWatchList`。`applyConfig()` 有同样的写法，一并修正为同一套优先级。
- **`normalizeBarWatchList()` 增加了可选 `scope` 参数**（design.md 中未预见）。导入配置时
  `root.watchList` 尚未更新，必须显式传入待生效的 watchList，否则新导入的资产会被旧列表误过滤为空。
- **动画时长改用 `Style.animationFast`** 而非 design.md 里写的硬编码 160/200ms。该 token 在用户关闭动画或
  处于性能模式时返回 0，滚动会自动退化为瞬时切换，符合 shell 的全局动画设置。
- **`Behavior` 加了 `enabled: scrollAnimation.running` 门控**，只在切换过渡期间平滑 implicit 尺寸，
  避免启动时的 0 → N 首次布局也被动画化。同时对 `implicitHeight` 也加 Behavior 以覆盖垂直状态栏。
- **`assetView()` 增加了 `empty` 态**：`barWatchList` 为空时显示 `--` 而非永久 `...`。
- **发现一处既有 i18n 漂移（未修，超出范围）**：`i18n/*.json` 有 `menu.settings` 键，
  但 `Main.qml` 的内嵌兜底副本没有。该键当前无任何引用，属无害死键。

### 自动化验证补充

`normalizeBarWatchList` / `seedBarWatchList` / `syncBarCoin` / `normalizeImportedConfig` 是纯 JS，
可以从 `Main.qml` 里按大括号配对抽出真实函数体，在 Node 的 `vm` 里执行。据此写了一个校验脚本，
覆盖 design.md 的四条不变式与 §6 全部迁移矩阵，共 16 项断言全部通过——上面那个缺陷就是它抓出来的。
脚本目前只在 `/tmp/verify-bar-watchlist.js`，未纳入仓库（regex 抽取 QML 函数体较脆弱，是否常驻待定）。

## 步骤

### 1. Main.qml — 数据层 ✅

- [x] 新增 `property var barWatchList: []` 与 `property int barScrollInterval`（夹取 2–60，回退链 `cfg → defaults → 5`）
- [x] 新增 `seedBarWatchList()`、`normalizeBarWatchList(assets, scope)`、`syncBarCoin()`
- [x] `Component.onCompleted`：插入播种与规范化；删除原 barCoin 兜底三行
- [x] `resolveLegacyWatchList()`：循环内记录 `refMap`，循环后重映射 `barWatchList` 并 `syncBarCoin()`

**验证**：✅ `grep -n "barCoin" market-watch/Main.qml` — 无渲染读点，只剩声明、播种、派生赋值、导出/持久化。

### 2. Main.qml — 配置进出 ✅

- [x] `exportConfig()` 增加两个新字段
- [x] `normalizeImportedConfig()`：`next` 初值 + 两条校验 + 子集约束（按导入后的 watchList）
- [x] `applyConfig()`：provider 切换重映射抽成 `remapReference()` 复用；顺序为 watchList → barWatchList → barCoin
- [x] `persistCurrentSettings()` 写入两个新字段，`barCoin` 写 `barWatchList[0]`

**验证**：✅ 16 项 Node 断言通过（含 5 项专测导入路径）。

**回滚点 A**：已通过。

### 3. manifest.json ✅

- [x] `defaultSettings` 增加 `"barWatchList": ["btc"]`、`"barScrollInterval": 5`
- [x] `version`: `1.1.0` → `1.2.0`

**验证**：✅ `jq empty market-watch/manifest.json`

### 4. i18n（四处同改）✅

- [x] `i18n/en.json`：新增 5 键，移除 `barCoin` / `barCoinDesc`
- [x] `i18n/zh-CN.json`：同上
- [x] `Main.qml` 内嵌 en 兜底副本
- [x] `Main.qml` 内嵌 zh-CN 兜底副本

**验证**：✅ 双语键集合一致；✅ Python 脚本确认内嵌兜底副本与 JSON 的 `settings` 段键与文案逐条相同。

### 5. BarWidget.qml — 状态解析 ✅

- [x] 移除 `barCoin`、`isLoading`、`errorMsg`、`coinData` 四个属性绑定
- [x] 新增 `barAssets`、`scrollIntervalMs`、`currentIndex`、`currentAsset`、`currentView`
- [x] 新增 `assetView(reference)`，含 `empty` 态
- [x] `text` / `suffix` / `tooltipText` / 颜色全部改读 `currentView`

**验证**：✅ `grep -n "isLoading\|errorMsg\|barCoin" market-watch/BarWidget.qml` 无输出。

### 6. BarWidget.qml — 轮播与动画 ✅

- [x] 插入 `scrollClip` 裁剪盒（`anchors.fill`、`clip`、implicit 尺寸转发、双向 Behavior）
- [x] `root` implicit 尺寸转发 `scrollClip`
- [x] 轮播 `Timer`（`running: barAssets.length > 1`）与 `SequentialAnimation`
- [x] `onBarAssetsChanged` 复位处理
- [x] 右键菜单「立即刷新」保持遍历 `watchList`

**验证**：✅ `grep -c "BarPill {"` 为 1。

### 7. Settings.qml ✅

- [x] 新增 `editBarWatchList`、`editBarScrollInterval`；移除 `editBarCoin`
- [x] 删除 `barCoin` 的 `NComboBox` 与 `buildBarCoinModel()`
- [x] 行内插入 `NIconButton`（`pin` / `unpin`），新增 `isBarAsset()` / `toggleBarAsset()`
- [x] `toggleCoin(coin, false)` 同步剔除 `editBarWatchList`
- [x] 新增 `settings.barAssets` 小节标题 + 说明 + 间隔 `NLabel` + `NSlider`（2–60）
- [x] `saveSettings()` 与 `syncFromMainInstance()` 同步两个新字段

**验证**：✅ `grep -n "editBarCoin\|buildBarCoinModel"` 无输出；✅ `effectiveMarketType` 仍只有一份定义。

### 8. 文档与 registry ✅

- [x] `market-watch/README.md` 设置项 + 默认配置块
- [x] `market-watch/README_CN.md` 同步
- [x] `registry.json`：版本 `1.2.0`，`lastUpdated` = `2026-08-16T16:03:06+08:00`

**验证**：✅ `jq empty registry.json`；✅ 版本号两处一致。

### 9. 静态检查（全量）✅

```
jq empty（5 个 JSON）                            ✅
node market-watch/tests/MarketProviders.test.js   ✅ 4 providers + TradingView
git diff --check                                  ✅
qmllint 语法（3 个 QML 文件）                      ✅ 0 syntax errors
```

> qmllint 只能做语法检查：Noctalia Shell 没有 qmldir 文件，`qs.*` 模块无法解析，拿不到类型检查。

### 10. 手动验证（Noctalia Shell）⬜ 待执行

`qs -c noctalia-shell`，逐项勾：

**轮播**
- [ ] 只勾 1 个资产 → 静态显示，无滚动
- [ ] 勾 3 个资产 → 按自选顺序上下滚动，动画连续可读
- [ ] 运行中把间隔从 5 秒改到 2 秒并保存 → 立即生效，无需重启
- [ ] 运行中取消勾选当前正在显示的资产 → 不崩溃，索引正确归位

**状态**
- [ ] 正常报价：`BTC 45,230 ↑` / compact 模式 `45,230 ↑`
- [ ] 断网后某资产失败 → 只有它那一帧显示 `⚠`，其余资产照常显示价格
- [ ] 选一个当前数据源不支持的旧资产 → 显示 `✕`，提示为「当前数据源不可用」
- [ ] 冷启动瞬间 → 显示 `...`

**交互不变**
- [ ] 左键开面板（center 与 click 两种位置）
- [ ] 右键菜单四项均可用
- [ ] 工具提示随当前显示资产切换

**布局**
- [ ] 水平状态栏：滚动不撑宽，邻居部件不抖
- [ ] 垂直状态栏（左/右）：pill 朝向正确，滚动正常
- [ ] 明/暗主题各看一遍
- [ ] 重点观察：滑入的约 150ms 内是否有裁边（design.md §4.3 记了回退方案）

**持久化**
- [ ] 保存 → 重启 shell → `barWatchList` 与 `barScrollInterval` 保持
- [ ] 导出配置 → 检查 JSON 含两个新字段 → 改动后导入 → 生效且经过范围校验
- [ ] 用一份只有 `barCoin: "eth"` 的旧配置启动 → 状态栏显示 ETH（升级兼容）

### 11. 收尾 ⬜

- [ ] 走 Phase 3.3 更新 spec（`BarPill` 裁剪/动画结论 → `.trellis/spec/plugins/qml-components.md`）
- [ ] Phase 3.4 提交

## 审查门

| 门 | 时机 | 状态 |
| --- | --- | --- |
| G1 | 第 2 步后 | ✅ 数据层不变式单点保证，16 项断言通过 |
| G2 | 第 7 步后 | ✅ 通读 diff，抓出并修复导入路径缺陷 |
| G3 | 第 10 步后 | ⬜ 待手动验证 |

## 回滚点

- **A（第 2 步后）**：已通过
- **B（第 9 步后）**：改动完整但未提交，`git stash` 保留 ← **当前位置**
- **提交后**：单次提交，`git revert` 即可；持久化层纯增量，用户配置不受损（design.md §10）
