# 分时图验证记录

日期：2026-11-03。分支：`feat/market-watch-intraday-chart`。工作版本：2.1.0，最低 plugin API 29。

## 已通过

最终代码上的命令全部退出 0：

| 命令 | 结果 |
| --- | --- |
| `lua5.4 tests/providers_test.luau` | 行情源、代码构造、检索与格式回归通过 |
| `lua5.4 tests/alerts_test.luau` | 提醒、冷却、滚动窗口与归一化回归通过 |
| `lua5.4 tests/history_test.luau` | 48项通过，含各来源解析与图表数学 |
| `lua5.4 tests/history_service_test.luau` | 41项通过，直接驱动真实 service 的 mock host |
| `lua5.4 tests/history_panel_test.luau` | 直接驱动真实 panel；导航、悬停、刷新、失败保留、配置隔离与纵轴精度通过 |
| `noctalia plugins lint .` | 0 errors，0 warnings |
| `python3 .github/workflows/validate-plugins.py` | 2个插件通过 |
| `python3 .github/workflows/update-catalog.py` | 已生成2个插件；保留 API26 的旧版回退项 |
| `git diff --check` | 通过 |

五个 Lua 测试命令在 `market-watch/` 执行，其余在仓库根目录执行。独立审查另验证7个相关 Luau 文件的 `luac5.4 -p` 语法和14个 history 翻译键的双语完整性。仓库没有独立类型检查命令；语法检查不代表类型检查。

独立审查修复了纵轴精度问题：1000.1～1000.9 不再都显示为1000，真实面板回归确认两端原始价格分别显示。未留下其他确认的代码缺陷。API与props对照 `/tmp/official-plugins/noctalia.d.luau`，未使用超出 API29 的新增能力。

## 网络与宿主边界

- 研究阶段匿名 BTC 请求实测：HTX现货/合约、Binance现货/合约、CoinGecko成功，响应约30～52KiB，可取得约24小时历史。它们不是所有资产、所有代理配置的保证。
- 当前网络 OKX 返回 HTTP403，其成功路径尚未实测；适配器有离线响应测试。
- 当前宿主为 Noctalia5.4.1 / Niri。面板打开和关闭 IPC 返回 `ok`。双输出截图均被锁屏覆盖，且未获得测试驱动成功标记，因此不能据此认定新代码已在原生宿主成功加载或显示。
- 原生布局、明暗主题、实际指针悬停、键盘操作、30秒原生请求周期与网络故障交互仍需解锁后的手动验收。对应逻辑已有受控时钟的真实脚本 mock 测试，不能替代视觉验证。
- 没有改变主题、插件来源、启用配置或用户数据文件。

## 临时安装还原

为宿主冒烟尝试，临时替换了已安装插件的7个文件，并只在安装副本追加测试驱动。测试结束后关闭面板，恢复所有原文件；原先不存在的 `lib/history.luau` 已移除。每个恢复文件均通过 SHA256 与备份一致性检查。仓库文件没有追加测试驱动，已安装版本没有永久升级。

本机还原证据：`/tmp/market-watch-runtime-smoke-q_e_glcm/restored.txt`；备份清单位于同目录 `manifest.json`。截图仅证明锁屏遮挡，不作为界面验收证据。

## 交付状态

实现与离线质量门禁完成。用户于2026-11-04选择 Q1 A，确认提交计划；已创建本地功能提交 `3eed570`，未推送、未发布。按 Trellis finish-work 归档并记录会话，完整原生宿主验收仍未完成，以上运行边界保持有效。
