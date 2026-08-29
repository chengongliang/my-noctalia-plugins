# 整合多币种滚动与告警通知

## Goal

在当前 `chengongliang/状态栏多币种滚动支持` 分支中整合 `main` 上已实现的告警通知，使 `market-watch` 同时保留状态栏多资产滚动和价格/急涨急跌告警，且配置、文档、翻译与发布元数据一致。

## Background

- 共同基线是 `ad7bfdac1b694f8cd29e69d77d51a52b2363b2ce`。
- 当前分支在基线上有两个提交：`1f552a6` 实现多币种滚动，`fb5a7fb` 记录 Trellis 进度。
- `main` 在基线的另一条线上包含 `bcbec3b` 告警实现，以及合并提交 `be62c3f`。该合并提交只纳入了多币种任务资料，没有纳入 `1f552a6` 的代码。
- 预合并显示 `README.md`、`README_CN.md`、`Settings.qml` 和 `registry.json` 有文本冲突；`Main.qml`、i18n 和 manifest 可自动合并，但仍需进行语义审查。
- 两边 manifest 都是 `1.2.0`，却各自代表不同的向后兼容功能集。整合后应按新增功能将版本升为 `1.3.0`，并同步 registry。

## Requirements

- 用一次真实 Git 合并保留两条开发历史，不以整文件覆盖的方式丢失任一侧功能。
- 保留多币种状态栏能力：`barWatchList`、`barScrollInterval`、单资产静态显示、多资产上下滚动、旧 `barCoin` 兼容与导入/导出持久化。
- 保留告警能力：精确 instrument ID 的价格上下限、急涨急跌阈值/时间窗/冷却/资产选择、仅新鲜报价触发、通知本地化、保存和导入/导出。
- `Settings.qml` 的合并结果必须同时提供状态栏资产选择/切换间隔与两类告警设置，并继续遵循编辑副本 + `saveSettings()` 持久化模式。
- manifest 的 `defaultSettings` 必须同时包含滚动和告警的所有默认键。
- 英文、简体中文和 `Main.qml` 内嵌翻译必须同时包含两套功能的文案，不添加 `tr()` 后备用字符串。
- README 必须同时说明多币种滚动与告警行为。
- 版本升至 `1.3.0`，`registry.json` 的版本与 `lastUpdated` 在同一改动中同步。

## Acceptance Criteria

- [x] `git merge main` 的冲突全部解决，工作树中不存在未合并路径或冲突标记。
- [x] `BarWidget.qml` 仍以 `barWatchList` 轮播，告警整合不会退化单资产/多资产和逐资产错误状态行为。
- [x] `Main.qml` 同时保留滚动配置迁移与 `AlertEngine`/`ToastService` 告警调用，告警仍只从新鲜成功报价路径评估。
- [x] `Settings.qml` 可以编辑、校验并保存 `barWatchList`、`barScrollInterval`、`priceAlerts` 和 `rapidAlert`；导入/导出不丢任一组字段。
- [x] `manifest.json` 和 `registry.json` 均为 `1.3.0`，所有 JSON 可解析，两个 locale 的键集一致。
- [x] `node market-watch/tests/AlertEngine.test.js` 和 `node market-watch/tests/MarketProviders.test.js` 通过。
- [x] 多币种配置迁移/导入导出的现有逻辑验证通过，`git diff --check` 和 QML 语法检查通过。
- [x] 在可用的 Noctalia Shell 中实测：一个资产静态、多资产滚动、设置重启持久化、价格上/下限通知、急涨/急跌通知，以及 stale/error 行情不误报。

## Out of Scope

- 新增行情提供商、新告警类型或修改既定告警触发语义。
- 重新设计面板、状态栏动画或设置页的视觉样式。
- 将与本次合并无关的既有待办项一并扩大实现。
