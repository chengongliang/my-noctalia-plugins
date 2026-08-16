# 执行计划：状态栏多币种滚动

前置：`design.md` 已定稿。所有步骤在 `chengongliang/状态栏多币种滚动支持` 分支上进行，最终合为一次提交。

## 步骤

### 1. Main.qml — 数据层

- [ ] 新增 `property var barWatchList: []` 与 `property int barScrollInterval`（夹取 2–60，回退链 `cfg → defaults → 5`）
- [ ] 新增 `seedBarWatchList()`、`normalizeBarWatchList(list)`、`syncBarCoin()`（签名见 design.md §3.2）
- [ ] `Component.onCompleted`：在 `watchList = normalizeWatchList(watchList)` 之后插入播种与规范化；删除原「barCoin 不在 watchList 就取 watchList[0]」的三行（`Main.qml:231-234`）
- [ ] `resolveLegacyWatchList()`：循环内记录 `refMap`，循环后重映射 `barWatchList` 并 `syncBarCoin()`；删除原 barCoin 兜底分支（`Main.qml:1292-1297`）

**验证**：`grep -n "barCoin" market-watch/Main.qml` — 确认 `barCoin` 只剩属性声明、`syncBarCoin()` 内赋值、导出/持久化三类读点，没有任何渲染读点。

### 2. Main.qml — 配置进出

- [ ] `exportConfig()` 增加 `barWatchList`、`barScrollInterval`
- [ ] `normalizeImportedConfig()`：`next` 初值加两个新字段；`Array.isArray(config.barWatchList)` 与 `typeof config.barScrollInterval === "number"`（夹取 2–60 后 `Math.round`）两条校验；末尾把原 barCoin 兜底替换为 `next.barWatchList = normalizeBarWatchList(next.barWatchList)`
- [ ] `applyConfig()`：provider 切换时对 `config.barWatchList` 套用与 `watchList` 相同的前缀重映射；`root.barScrollInterval` 夹取赋值；顺序必须是 **先定 `watchList`，再 `normalizeBarWatchList()`，最后 `syncBarCoin()`**
- [ ] `persistCurrentSettings()` 写入两个新字段，`barCoin` 写 `root.barWatchList[0]`

**验证**：`node -e` 无法覆盖 QML；改为人工对读——确认四个函数里 `barWatchList` 的每一次赋值都经过 `normalizeBarWatchList()`（design.md 不变式单点保证）。

**回滚点 A**：此时插件行为应与改动前完全一致（`barWatchList` 已存在但无人渲染）。可用 `qs -c noctalia-shell` 先跑一次确认没跑坏现有功能。

### 3. manifest.json

- [ ] `defaultSettings` 增加 `"barWatchList": ["btc"]`、`"barScrollInterval": 5`
- [ ] `version`: `1.1.0` → `1.2.0`

**验证**：`jq empty market-watch/manifest.json`

### 4. i18n（四处同改）

- [ ] `market-watch/i18n/en.json`：新增 5 键，移除 `barCoin` / `barCoinDesc`
- [ ] `market-watch/i18n/zh-CN.json`：同上
- [ ] `Main.qml` 内嵌 en 兜底副本（`Main.qml:63-104`）：同上
- [ ] `Main.qml` 内嵌 zh-CN 兜底副本（`Main.qml:139-180`）：同上

文案见 design.md §7。键名在各 JSON 对象内保持字母序（现有文件是排好序的）。

**验证**：
```bash
jq -S '.settings | keys' market-watch/i18n/en.json > /tmp/en-keys.json
jq -S '.settings | keys' market-watch/i18n/zh-CN.json > /tmp/zh-keys.json
diff /tmp/en-keys.json /tmp/zh-keys.json && echo "locale keys aligned"
```
再人工确认 `Main.qml` 两份内嵌副本与对应 JSON 的键集合一致。

### 5. BarWidget.qml — 状态解析

- [ ] 移除 `barCoin`、`isLoading`、`errorMsg`、`coinData` 四个属性绑定
- [ ] 新增 `barAssets`、`scrollIntervalMs`、`currentIndex`、`currentAsset`
- [ ] 新增 `assetView(reference)`（design.md §4.1），保留 `const t = tick` 触发重算的既有模式
- [ ] `BarPill` 的 `text` / `suffix` / `tooltipText` / `customBackgroundColor` / `customTextIconColor` 全部改为读 `assetView(currentAsset)`，按 design.md §4.2 渲染表实现

**验证**：`grep -n "isLoading\|errorMsg\|barCoin" market-watch/BarWidget.qml` 应无输出。

### 6. BarWidget.qml — 轮播与动画

- [ ] 在 `root` 与 `BarPill` 之间插入 `scrollClip`（`anchors.fill: parent`、`clip: true`、implicit 尺寸转发、`Behavior on implicitWidth`）
- [ ] `root` 的 implicit 尺寸改为转发 `scrollClip`
- [ ] 新增轮播 `Timer`（`running: barAssets.length > 1`）与 `SequentialAnimation`（design.md §4.3）
- [ ] 新增 `onBarAssetsChanged` 复位处理（停动画、`y=0`、`opacity=1`、越界索引归零）
- [ ] 右键菜单「立即刷新」保持遍历 `watchList` 不变（子集已被覆盖）

**验证**：`grep -c "BarPill" market-watch/BarWidget.qml` 应为 1——确认没有引入第二个 pill 实例。

### 7. Settings.qml

- [ ] 新增 `editBarWatchList`、`editBarScrollInterval`；移除 `editBarCoin`
- [ ] 删除 `barCoin` 的 `NComboBox`（`Settings.qml:117-126`）与 `buildBarCoinModel()`（`Settings.qml:442-455`）
- [ ] 自选列表行内插入 `NIconButton` 开关（`pin` / `unpin`），新增 `isBarAsset()` / `toggleBarAsset()`
- [ ] `toggleCoin(coin, false)` 分支同步剔除 `editBarWatchList`
- [ ] 自选列表下方新增 `settings.barAssetsTip` 说明文本 + 间隔 `NLabel` + `NSlider`（2–60）
- [ ] `saveSettings()` 的 `nextConfig` 加 `barWatchList`（按 `normalizedWatchList` 顺序过滤，空则 `[normalizedWatchList[0]]`）、`barScrollInterval`，`barCoin` 改为派生值
- [ ] `syncFromMainInstance()` 同步两个新字段，移除 `editBarCoin`

**验证**：`grep -n "editBarCoin\|buildBarCoinModel" market-watch/Settings.qml` 应无输出。

### 8. 文档与 registry

- [ ] `market-watch/README.md`：设置项列表把 "Status Bar Asset" 改为状态栏轮播资产 + 切换间隔两条；默认配置 JSON 块加两个新字段
- [ ] `market-watch/README_CN.md`：同步
- [ ] `registry.json`：`market-watch` 版本 → `1.2.0`，`lastUpdated` → 提交当日 `+08:00` 时间戳

**验证**：`jq empty registry.json`；`grep -n "1.2.0" market-watch/manifest.json registry.json` 两处都命中。

### 9. 静态检查（全量）

```bash
jq empty market-watch/manifest.json hermes-agent/manifest.json registry.json
jq empty market-watch/i18n/en.json market-watch/i18n/zh-CN.json
node market-watch/tests/MarketProviders.test.js
git diff --check
```

四条全绿才进第 10 步。

### 10. 手动验证（Noctalia Shell）

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

**持久化**
- [ ] 保存 → 重启 shell → `barWatchList` 与 `barScrollInterval` 保持
- [ ] 导出配置 → 检查 JSON 含两个新字段 → 改动后导入 → 生效且经过范围校验
- [ ] 用一份只有 `barCoin: "eth"` 的旧配置启动 → 状态栏显示 ETH（升级兼容）

### 11. 收尾

- [ ] 走 Phase 3.3 更新 spec（若 §4.4 的 `BarPill` 裁剪/动画结论值得沉淀，写入 `.trellis/spec/plugins/qml-components.md`）
- [ ] Phase 3.4 提交

## 审查门

| 门 | 时机 | 内容 |
| --- | --- | --- |
| G1 | 第 2 步后 | 数据层不变式是否单点保证；现有功能未回归（回滚点 A） |
| G2 | 第 7 步后 | 全部代码改动完成，进静态检查前通读一遍 diff |
| G3 | 第 10 步后 | 手动验证清单是否全绿；未绿项必须在提交说明中写明 |

## 回滚点

- **A（第 2 步后）**：只有数据层增量，行为无变化，直接 `git checkout -- market-watch/Main.qml` 即可退回
- **B（第 9 步后）**：改动完整但未提交，`git stash` 保留
- **提交后**：单次提交，`git revert` 即可；持久化层纯增量，用户配置不受损（design.md §10）
