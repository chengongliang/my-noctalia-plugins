# 分时图研究记录

日期：2026-11-03。只读代码检查和匿名市场数据 GET；未修改插件代码。

## 仓库证据

| 事实 | 位置 |
| --- | --- |
| watch 面板600×495，当前最低 API26 | `market-watch/plugin.toml:131`，根 manifest |
| 资产行当前没有点击 | `market-watch/panel.luau:11`、`:123` |
| panel 一秒 poll，signature 变化才 render，规避热重载后的 watch 失效 | `market-watch/panel.luau:313` |
| 报价是单个日 K / simple-price，无可用的日内曲线 | `market-watch/lib/providers.luau:330` |
| rapid_history 只为提醒收集，不可替代通用日内历史 | `market-watch/service.luau:816` |
| api_get 复用 argv curl/代理、截断和大小检查，decode 上限100KiB | `market-watch/service.luau:95`、`:622`、`:646`、`:693` |
| 普通请求 generation、500ms heartbeat、并发报价4 | `market-watch/service.luau:80`、`:180`、`:896` |
| 当前真实测试为 Lua5.4；v4 spec 中 Node/QML 指令已过时 | `market-watch/tests/providers_test.luau:1`、根 `AGENTS.md` |

## 官方 UI 能力

来源：[noctalia.d.luau](https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau)，本次副本在 `/tmp/market-watch-noctalia.d.luau`（临时文件，不作为任务长期依赖）。

- lines379–380：pointer callback 的 x/y 均为0..1字符串。
- lines401–424：row 支持 onClick，可键盘进入；可在同 panel 切换树。
- lines606–625：graph 只接受 normalized values/values2 和尺寸/样式，无时间 x 数组、坐标轴、原生 tooltip 或十字光标；pointer move/leave 从 API29 起可用。节点移除时 leave 应使用命名 handler。
- lines284–289：formatTime 使用 unix 秒和可选 timezone；省略 timezone 为系统本地。实际 pattern/时区输出在实现时验证。
- lines705–731：scroll 的 revealKey 需要 API33，本任务不使用它，也不承诺返回时精确恢复原滚动位置。
- runAsync argv 至少 API24，但只返回 boolean，没有进程取消句柄，因此离开后停止新请求，不要求取消在途 curl。
- [API版本文档](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/) 将 graph pointer 标为29，映射 Noctalia v5.0.1；最低要求按29声明，不能凭当前声明中存在较新 props 就使用它们。

## 历史接口与实测

300个五分钟点能覆盖约25小时，再按实际时间裁剪。选用准确 instrument.exchange_symbol，不在 UI 构造交易对。

| 来源 | 匿名 BTC 请求结果 | body字节 | 点数/跨度 |
| --- | --- | ---: | --- |
| HTX spot `period=5min&size=300` | HTTP200 | 41999 | 300 / 24.917h |
| HTX perpetual 同上 | HTTP200 | 44067 | 300 / 24.917h |
| Binance spot `interval=5m&limit=300` | HTTP200 | 51948 | 300 / 24.917h |
| Binance perpetual 同上 | HTTP200 | 41047 | 300 / 24.917h |
| CoinGecko bitcoin `market_chart?vs_currency=usd&days=1` | HTTP200 | 29721 | 288 / 23.908h，前几个间隔300s |
| OKX `bar=5m&limit=300` | HTTP403 | 17 | 未取得；不能声称运行成功 |

成功样本都低于64KiB quote guard 和100KiB decode cap，不保证所有资产响应均小于该值。CoinGecko响应含额外 market_caps/total_volumes，应在大小检查后只采用prices。

接口文档：

- [HTX spot](https://huobiapi.github.io/docs/spot/v1/en/#get-klines-candles)：5min、最大2000条。
- [HTX USDT swap](https://huobiapi.github.io/docs/usdt_swap/v1/en/#general-get-kline-data)：5min、最大2000条。
- [Binance spot](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/market)：5m、最大1000条；合约300条已实测成功。
- [OKX candles](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-candlesticks)：5m，默认100、最多300条，必须显式limit=300。
- [CoinGecko market_chart](https://docs.coingecko.com/demo/reference/coins-id-market-chart)：当前1d自动五分钟粒度；不要显式interval=5m（Enterprise限制）。本次无key成功，无依据强制新增凭证设置；匿名可用性和限流并无永久保证。

## 核对限制

现有 spec 多处仍指向 v4 文件/进程/API；实施必须用当前根 AGENTS 和 v5官方声明核对，保留跨边界原则。当前实际 shell 的 API级别、预算下图表分段/渲染表现、不同资产权限及OKX成功路径留到实施验证，失败应报告真实限制。
