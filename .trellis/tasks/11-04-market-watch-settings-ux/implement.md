# Settings UX — Implementation Plan

## Before Implementation

- [x] 获得用户对最新交互方案的明确确认，移除 PRD 中已解决的问题并做最终收敛检查。
- [x] 读取当前 Trellis 工作流及相关 v5、提醒、复用规范；保持其他工作区改动不变。
- [x] 根据当前 auto dispatch 模式准备 spec/research 上下文；已获实施批准。

## Work

1. 在现有 mock host 测试风格中加入分类切换与多资产场景，适配图表设置测试的入口。
2. 重组固定导航和当前页布局，保留所有既有设置入口与服务命令。
3. 将价格提醒改成单资产编辑，并测试切换、删除、重排、空列表和外部配置变化。
4. 增加极速监控本地过滤与选择计数，验证过滤不改变配置且切回后保留选择。
5. 同步两种翻译与 README 使用路径，并把设置面板默认高度收紧为 620；不改版本、数据格式或底层提醒行为。

## Automated Verification

从仓库根目录执行，先跑修改相关测试，再回归已有测试：

```bash
(cd market-watch && lua5.4 tests/settings_panel_test.luau)
(cd market-watch && lua5.4 tests/chart_settings_test.luau)
(cd market-watch && for test in tests/*_test.luau; do lua5.4 "$test" || exit; done)
noctalia plugins lint .
python3 .github/workflows/validate-plugins.py
git diff --check
```

补充检查新增翻译键的英文/中文完整性、所有新使用的 API 属性、没有新增配置写入或命令类型。

## Manual Verification

- [ ] 0、1、12、50 资产下，导航、关闭按钮、搜索和列表滚动均可用。
- [ ] 实际界面中面板保持紧凑高度，不拉满整屏；缓存/本地开发插件副本刷新后生效。
- [ ] 价格提醒快速切换与编辑不会串资产；轮询不打断当前输入。
- [ ] 极速列表搜索、选择、清空筛选后，监控集合和计数一致。
- [ ] 添加、关注、排序、删除、图表、状态栏、轮播和导入导出功能均可达且正常。
- [ ] 浅色/深色、英文/中文、键盘 Tab、不同屏幕可用高度下无裁切或不可达按钮。
- [ ] 关闭重开、插件重载、旧配置导入后已保存内容不变；不覆盖用户实际配置来造测试数据。

没有可用的真实 Noctalia 会话时，如实列出未执行的运行检查，不能用离线测试冒充视觉验收。

## Completion Boundary

完成代码与质量检查后再提交结果；不自动提交、发布、部署或归档其他任务。仅本任务引入的文件变更属于回滚范围。
