# Settings UX — Design

## Boundary

本次问题位于设置面板的信息组织，不在 service 或存储层。保留现有分区函数与服务命令，只调整当前分类的组合、列表滚动与价格提醒的渲染数量。

预计修改：

- `market-watch/settings_panel.luau`：分类导航、资产列表布局、单资产提醒编辑、极速监控筛选。
- `market-watch/plugin.toml`：设置面板由 `height = "fill"` 改为固定 `620`，避免高屏拉满并保留内部滚动。
- `market-watch/translations/en.json`、`market-watch/translations/zh-Hans.json`：分类、筛选标签、计数及空状态。
- `market-watch/tests/chart_settings_test.luau`：进入显示分类后执行原有图表设置断言。
- `market-watch/tests/settings_panel_test.luau`：覆盖新增交互及状态边界，复用现有 mock-host 测试风格，不增加测试框架。
- `market-watch/README.md`：更新设置操作路径。

不修改 `service.luau`、`lib/store.luau`、提醒引擎、manifest 或 catalog。

## Layout

- 根节点：固定标题和关闭按钮、四个分类按钮、当前页内容。
- 资产：固定搜索区 + 占剩余空间的自选列表滚动区；搜索结果继续使用原服务结果，不另建搜索后端。
- 显示：一个滚动容器内保留状态栏、图表、轮播分区。
- 提醒：固定价格/极速两种模式入口；价格模式选择资产后仅展示一个编辑卡片，极速模式固定参数与本地筛选、滚动监控列表。
- 配置：导入导出按钮、状态消息及宿主设置说明。健康错误仍作为跨分类可见提示。
- 面板默认高度固定为 620；宽度、placement、position 不变。宿主已有的用户覆盖仍按宿主规则生效。

## State And Data Flow

- 临时状态仅包括当前分类、提醒模式、选中资产 ID 和极速列表筛选文本；现有添加资产搜索状态继续独立保存。
- 本地交互立即重绘，并进入 `display_signature()`，避免轮询覆盖或漏掉 UI 更新。
- 配置仍由 `market.cmd` → service → `market.config` 回流；分类、模式和筛选不能发送配置命令。
- 对资产选择使用完整 ID，不用位置或 symbol 作为身份；列表变化时校正选择，空列表不渲染编辑器。
- 输入控件沿用资产 ID 区分 key；切换资产重建对应输入，不复用另一资产的未受控文本。
- 筛选采用本地 symbol/name 的不区分大小写、字面量子串匹配，不执行模式匹配、不改变监控集合。
- 不增加键盘捕获或自动抢焦点；固定列表 key 保证同一资产重绘时控件可复用。

## Verified Platform Constraints

已检查 `/tmp/official-plugins/noctalia.d.luau` 和 `example/panel.luau`：

- 分类按钮可用 `ui.button` 的 `selected`、`variant`、`onClick`；不存在需要引入的通用 tabs 控件。
- `ui.select` 为受控选择，`selectedIndex` 为 0-based，回调 index 为字符串。
- `ui.input.value` 在当前实现中作为初值使用；保持稳定 key，切资产时用资产 ID 分离输入实例。
- `ui.toggle` 回调值是字符串 `"true"` / `"false"`。
- 使用既有 `ui.column` / `ui.row` / `ui.scroll`，每个可滚动区域都必须受剩余空间约束，不能把完整列表嵌入无界容器。
- 开始实施前逐项核对新增 props；不假设支持 CSS、原生多选 select、折叠面板或焦点管理 API。

仓库部分 `.trellis/spec/plugins/` 仍记录 v4 QML；冲突时遵循根 `AGENTS.md` 的 v5 规则、现有 Luau 代码和官方类型定义。

## Risks And Rollback

- 离线树测试无法证明宿主滚动、焦点、主题和长文本布局，必须保留实际 Noctalia 验证。
- 用户快速输入和切页时可能涉及原有服务命令回流时序；测试确认不误发资产 ID，不在本任务重构服务通道。
- 搜索结果本身可能占用较多高度；手测时确认不会挤掉自选列表，必要时只对结果区做有界滚动。
- 回滚仅撤销本任务的界面、翻译、测试和文档改动，用户数据无需迁移；不得还原他人的工作区修改。

## Review Status

用户已确认最新交互方案并授权实施。PRD 已收敛，无阻塞问题；按本设计实施，不扩大到服务或持久化层。
