# 实施清单

状态：in_progress；用户已于 2026-11-03 审核本版规划并回复“开始”。代码、独立审查及离线验证已完成；用户于2026-11-04确认提交计划，功能提交为 `3eed570`。运行验收边界见 `verification.md`。

## 顺序

1. [x] 重新核对 `AGENTS.md`、最新代码/版本、官方 example/timer 及 `noctalia.d.luau`；使用 trellis-before-dev 和 ponytail。v4 spec 内容依 design 中的优先级处理，不能照搬。
2. [x] 为四个 provider 增加历史 URL 和 parse_history，新增代表性离线 fixtures。验证交易所现货/合约、准确 instrument id、时间单位、升序去重、上游错误与异常数据。
3. [x] 实现 `lib/history.luau` 的24小时裁剪、精度识别、连续段、价格归一化和 hover 索引。用小型 Lua 测试覆盖恒价、空/单点、乱序、重复、缺口、未来/非有限值和跨日期。
4. [x] service 接入 history_request 和按 id 分隔的 state，复用 curl/代理/body guard；覆盖请求去重、失败保留、epoch 隔离、超时恢复、移除资产清理。不添加后台历史周期。
5. [x] panel 接入点击详情、返回/重开、30秒可见刷新、手动刷新、读数及本地时间；增加命名 leave handler，保留状态签名和现有标题栏行为。
6. [x] 用离线 mock host 驱动真实 service/panel：成功、启动失败、损坏/截断/超限、无历史、刷新失败、过期回调、代理/来源切换、重复点击、关闭后时间推进。测试请求数量和最终显示状态，避免只复制实现。
7. [x] 补齐 en/zh-Hans、双 README、最低 API29 和功能版本；重新生成 catalog；检查所有新增 noctalia/ui/panel API、props 与官方声明一致。
8. [x] 静态/离线检查和独立 trellis-check 已通过。已尝试实际 shell 验证；锁屏遮挡画面，完整运行验收未完成，详见 `verification.md`。
9. [x] 记录证据和未能执行的运行检查；必要时更新直接相关的 v5 spec 契约。向用户给出变更与验证结果；本任务不包含部署或发布。

## 必跑命令

在仓库根目录：

```sh
noctalia plugins lint .
python3 .github/workflows/validate-plugins.py
python3 .github/workflows/update-catalog.py
git diff --check
```

在 `market-watch/`：

```sh
lua5.4 tests/providers_test.luau
lua5.4 tests/alerts_test.luau
lua5.4 tests/history_test.luau
lua5.4 tests/history_service_test.luau
lua5.4 tests/history_panel_test.luau
```

service/panel mock 的最终命令由实际测试文件确定，写入 README；用可控时钟验证可见性与30秒周期，不能依赖真实等待和外网结果。

## 运行验收

以下为原生宿主验收，未勾选表示尚未完成，不能由离线 mock 测试替代。网络成功路径和测试环境还原证据详见 `verification.md`。

- [ ] 当前 shell 支持 API29，插件实际可加载，未出现未知 API/prop 日志。
- [ ] 列表→不同资产→返回→关闭重开；每种标题栏按钮可用，键盘可进入资产。
- [ ] 明暗主题、两种涨跌颜色；600×495与宿主调整后的几何，hover 首尾和中间点。
- [ ] 本地日期/时区标识、跨午夜；实测来源时间与 hover 值一致。
- [ ] 停留超过30秒发生一次周期请求；返回/关闭后无新历史请求，已有回调不打开详情。
- [ ] 断网前后、慢响应、手动重试、来源/市场/代理切换、快速切换及删除资产。
- [ ] HTX/Binance 两种市场、CoinGecko；OKX使用可用网络/代理验成功路径。无法执行的条目逐项标明。
- [ ] 原行情、状态栏轮播、提醒、配置保存及导入导出没有被历史更新触发或改变。

## 高风险文件与回退点

`service.luau` 仅扩展历史命令和专有 state/epoch，避免重排已有报价/提醒队列；`panel.luau` 保持列表原布局分支；`lib/providers.luau` 不改变已有 quote parser 语义。历史缓存只在内存，回退无需迁移配置。

## 激活前检查

- [x] 用户已在本版 PRD/design/implement 最终审阅之后明确批准实施。
- [x] `implement.jsonl` 与 `check.jsonl` 均为真实 spec/research 引用，任务 validate 通过。
- [x] 无新增产品取舍；若最终设计改变已确认范围，先返回规划审核。
