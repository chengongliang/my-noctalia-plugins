# 增加状态栏多币种滚动支持

## Goal

让 `market-watch` 状态栏小部件能依次展示多个资产的最新行情：从已有自选资产列表中勾选出一个「状态栏子集」，当子集超过一条时在原有占位区域内以上下滚动动画切换，并允许用户调整切换间隔。

## Confirmed Repository Facts

- `market-watch/Main.qml` 已拥有共享行情状态、`watchList`、`barCoin`、`refreshInterval` 和 `marketData`，并通过 `pluginApi.mainInstance` 提供给状态栏组件。
- `Main.qml` 已有 per-instrument 的 `quoteStates[id]`（`ready` / `loading` / `stale` / `error` 与 `errorCode`），当前 `BarWidget.qml` 没有使用，只读全局 `isLoading` / `errorMessage`。
- `Main.qml` 内嵌了一份 `translations` 兜底副本（en 与 zh-CN），与 `i18n/*.json` 并存；新增文案必须同时改这四处。
- `market-watch/BarWidget.qml` 当前只读取单个 `barCoin`，没有滚动状态或切换定时器。
- `market-watch/Settings.qml` 已采用编辑副本后统一 `saveSettings()` 的模式；现有 `refreshInterval` 是行情请求刷新频率（1–60 秒），不能与状态栏视觉切换间隔混用。
- `manifest.json` 的 `metadata.defaultSettings` 是持久化设置的默认值；`registry.json` 需要在版本变更时同步。
- 插件有英文和简体中文 locale，所有新增用户可见文字都必须加入两种翻译。
- 插件测试目前以 `MarketProviders.test.js`、JSON 校验和 `git diff --check` 为主，QML 行为需要 Noctalia Shell 手动验证。
- `barCoin` 目前只被 `BarWidget.qml`、`Settings.qml` 的下拉框和 `Main.qml` 的导入导出读取；`Panel.qml` 不使用它。

## Resolved Decisions

- **资产来源（2026-08-16 确认）**：新增独立字段 `barWatchList`，但它必须是 `watchList` 的子集；轮播顺序跟随 `watchList` 的排序，不单独排序。理由：行情抓取逻辑（`refreshMarketData` 只遍历 `watchList`）无需改动，不会出现「状态栏在显示但没人抓数据」的资产。
- **编辑交互**：不新增独立的搜索/排序控件；在设置页现有自选列表每一行追加一个「状态栏显示」开关。原有的 `barCoin` 下拉框被该开关取代并移除。
- **`barCoin` 去留**：保留为派生兼容字段，持久化时写入 `barWatchList[0]`，供导入导出与旧版本回滚使用；`BarWidget.qml` 不再读取它。
- **切换间隔**：新增 `barScrollInterval`，单位秒，范围 2–60，默认 5。

## Requirements

- 状态栏使用 `barWatchList` 决定轮播内容；该列表是 `watchList` 的子集，顺序由 `watchList` 决定，去重后逐个展示。
- 只有一条有效资产时保持静态展示，不启动滚动定时器；多条有效资产时在同一状态栏占位区域内垂直滚动切换，避免横向撑宽状态栏（宽度变化需平滑过渡）。
- 新增独立的状态栏切换间隔设置 `barScrollInterval`（秒），只控制视觉切换，不改变行情网络刷新频率。
- 每个资产按自身状态渲染：有报价（含 `stale`）优先显示已有最新价；加载中、无数据、错误和不可用（`errorCode === "unavailable"`）各有明确占位，单条资产失败不得让整个小部件变成错误态。
- 状态栏现有左键打开面板、右键菜单、显示模式、颜色和面板位置行为保持不变；工具提示对应当前正在显示的资产。
- 新设置遵循 `cfg → defaults → hardcoded` 回退链，可在设置页编辑并通过 `saveSettings()` 持久化；导入/导出配置和 `applyConfig()` 运行时应用也要保留这两个字段。
- 升级兼容：旧配置没有 `barWatchList` 时，从既有 `barCoin` 播种为单元素列表，保证升级后状态栏显示的资产不变。
- 从 `watchList` 移除某资产时，必须同步从 `barWatchList` 移除；`barWatchList` 被清空时回退为 `[watchList[0]]`。
- 更新 manifest 默认设置、两种 locale（含 `Main.qml` 内嵌兜底副本）、两份 README 配置说明，并按仓库规则同步插件版本和 registry 时间戳。

## Acceptance Criteria

- [ ] `barWatchList` 只有 1 条时，状态栏静态显示该资产，切换定时器 `running === false`。
- [ ] `barWatchList` 有 2 条或以上时，状态栏在同一占位区域内按 `watchList` 顺序上下滚动切换；修改切换间隔后无需重启即可生效。
- [ ] 状态栏切换间隔在设置页可见、可调（2–60 秒）、可保存；重启后值仍存在，且不改变 `refreshInterval`。
- [ ] 设置页自选列表每行有「状态栏显示」开关；取消勾选某资产的自选身份时，它同时从状态栏列表消失；全部取消后保存，`barWatchList` 回退为 `[watchList[0]]`。
- [ ] 当前资产的报价、加载中、错误、不可用四种状态都能各自渲染；其中一条资产报错时，其余资产轮播到时仍显示正常价格。
- [ ] 切换后工具提示对应当前资产，`text`/`compact` 显示模式、右键菜单、左键开面板行为不变。
- [ ] 旧配置（有 `barCoin`、无 `barWatchList`）升级后状态栏显示的资产与升级前一致；全新安装按 manifest 默认值运行。
- [ ] 配置导入/导出包含 `barWatchList` 与 `barScrollInterval`，且导入时经过子集约束与范围校验。
- [ ] `jq empty market-watch/manifest.json hermes-agent/manifest.json registry.json`、`node market-watch/tests/MarketProviders.test.js` 和 `git diff --check` 通过。
- [ ] 完成一次 Noctalia Shell 手动验证（`qs -c noctalia-shell`），覆盖水平栏与垂直栏、明暗主题、保存后重启。

## Out Of Scope

- 状态栏轮播顺序独立于面板排序。
- 鼠标滚轮手动切换资产（`BarPill` 已有 `wheel` 信号，留待后续）。
- 面板 `Panel.qml` 的任何行为变更。
