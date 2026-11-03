# 技术设计：Market Watch 分时详情

## 依据和边界

以当前 Luau/v5 实现及根目录 `AGENTS.md` 为准。现有 `.trellis/spec/plugins/` 多处仍描述 v4/QML；其中资产标识、归一化、代理、异步失效和错误保留原则继续适用，不能照搬旧 API、文件名或 registry 流程。

复用 `service.luau` 的网络和共享状态所有权，不增加后台历史轮询器。`panel.luau` 决定什么时候需要数据，service 只处理显式历史请求。解析归 `lib/providers.luau`，纯图表数学归 `lib/history.luau`，UI 不接触上游字段。

```text
watch 行点击 → panel 选择完整 instrument id
  → market.cmd(history_request) → service/api_get/curl（沿用代理）
  → providers.parse_history → history 净化/裁剪
  → market.history:<完整 id> → panel 每秒读取 → ui.graph + 外围读数
```

## 数据契约

新增 `Providers.history_url(provider, market_type, instrument)` 和
`Providers.parse_history(provider, response, instrument)`。纯函数保持 Lua 5.4 可运行。
返回有序的真实点 `{ timestamp_ms, price }`，及实际采样间隔、时间语义；过滤非法值，按毫秒排序去重。交易所使用 candle close，时间是该五分钟区间的起点，UI 标明五分钟区间/收盘价含义；CoinGecko 使用原始价格时间戳。未结束 candle 会随刷新更新，不标作最终收盘。

历史模块只处理已归一化点：按请求完成时刻裁剪最近 24 小时，保留实际覆盖范围；计算共同价格上下界、0..1 值、时间段宽度和悬停索引。拒绝 NaN、无穷、非正价格、无效时间及明显未来数据。少于两个有效点显示不足以绘图；恒价数组置于垂直中间，显示真实恒定价格。

| 来源 | 请求 | 时间/价格字段 |
| --- | --- | --- |
| HTX spot | 原历史 K 线端点，`period=5min&size=300` | `id` 秒 → 毫秒，`close` |
| HTX perpetual | 原 linear-swap 历史端点，同参数，完整 `contract_code` | 同上 |
| Binance spot/perpetual | 各自 klines 端点，`interval=5m&limit=300` | 数组首项毫秒，close 第五项 |
| OKX spot/perpetual | candles，`bar=5m&limit=300`，完整 `instId` | 数组首项毫秒，close 第五项；保留确认语义 |
| CoinGecko | `/coins/<id>/market_chart?vs_currency=usd&days=1`，省略 `interval` | `prices` 中的毫秒/价格二元组 |

## 请求、状态和隔离

- 面板新增只读 command：`{ op = "history_request", id, nonce }`。沿用 `market.cmd` 现有通道，每个请求有唯一 nonce。
- service 使用 `instrument_for` 和当前 watch rows 验证完整 id；必须属于当前来源、市场和自选列表，pending/unavailable 资产不拼猜测 URL。
- 每个完整 id 独立发布 `market.history:<id>`：`{ id, source, market_type, epoch, revision, status, points, interval_ms, first_at, last_at, updated_at, error_code }`。status 为 loading/ready/stale/error/unavailable；已有 points 的刷新不清空曲线。
- 内存只保留当前 watch list 对应历史；移除资产和切换来源/市场时清除相关 state key；不写历史文件、不修改 runtime 配置 schema。
- 历史专用 epoch 在来源、市场、代理变更时递增，旧回调不能写入。不要为代理切换随意修改现有报价 generation 的语义。
- 同 id 同 epoch 请求去重；释放槽位时核对请求 token，防止旧回调清理新请求。失败、超时、启动失败、异常和预算中断均不能永远占用槽位，复用服务现有超时恢复原则。
- `api_get` 复用 argv 和代理。历史 body 限制不超过现有 100 KiB decode 上限，检查截断、退出状态、空体、上游错误以及 decode 失败；不通过放宽全局保护解决大响应。
- history 只发布自己的 key；不触发报价、logo、提醒、持久化或全量 publish。曲线响应不能喂给提醒引擎。

## 详情生命周期

panel 本地维护 `selected_id`、是否打开、下次刷新时刻和 hover point。`onOpen` 清空选择，显示列表；行点击进入详情并发起请求。保持现有每秒读取 state、签名变化时才 render 的模式，不依赖 state.watch。

进入即请求，即使有内存旧图也后台更新；成功后每 30 秒到期请求，失败后维持同样节奏，不紧密重试。手动刷新复用同一去重路径并重设周期。返回/`onClose` 清空详情定时状态，不再发请求；已运行的 curl 可以完成并缓存，UI 不重新进入详情。下次打开从列表开始。来源/市场变更或资产被移除时退出旧详情；代理变更立即使旧请求失效，仍在详情则重新请求。颜色和普通报价刷新不导致历史重载。

## UI 与图表限制

- 复用原 `watch` panel，整行 `ui.row.onClick`；可用键盘进入。顶部保留返回、刷新、设置和遵循宿主配置的关闭入口，明确当前资产/来源/市场。
- `ui.graph` 仅有 normalized values，没有轴/tooltip/crosshair；时间刻度、真实价格上下界、采样信息、成功更新时间及悬停读数通过相邻 label 呈现。布局适配当前 600×495 及宿主调整后的大小。
- 图形横向按等间距样本绘制；悬停选取相应真实点，永远不把数组索引换算成虚构时间。对间距异常/停盘缺口拆成连续段，按实际时间跨度布局分段 graph 和空白间隔，不跨长缺口连线；所有段共用价格上下界，不插值创造历史点。
- 连续段内部存在轻微时间抖动时仍用原始点时间显示，并标注实际采样精度。两点画线，单点用明确文本反馈，不误画成全天走势。
- `noctalia.formatTime` 使用默认本地 timezone；显示日期时间及 `%Z`/`%z` 时区标识，验证跨午夜、夏令时和时区更改。
- hover callback 参数是字符串，先转数值并夹紧；命名 `onPointerLeave` 清空 hover，以接受节点移除时的 teardown leave。hover 只在点索引改变时重绘，避免每次指针事件构建整棵树。
- 所有新增字符串放入两种 nested translations，使用 `tr`；价格格式和涨跌配色复用 providers，默认摘要保持明确标签，不把交易所日 K 涨跌值重新定义为滚动窗口涨跌。

## 兼容、交付和回退

`plugin.toml` 最低 API 29；按实际当前版本选择下一个功能版本，同步两个 README 及生成的 `catalog.toml`。不新增外部进程依赖，新增的历史网络请求在 README 中逐个说明。无新增凭证设置、历史落盘或配置迁移。

验证通过后若需回退，移除历史 command/state/UI 分支和新增 history 模块，恢复 manifest/catalog；不会丢失原有配置。API 29 宿主运行验证和 OKX 网络成功路径需在实施中确认，未通过时明确报告，不把静态验证称为运行验证。
