# 市场行情 Market Watch

Market Watch 是一个 Noctalia 插件，可以在状态栏和详情面板中显示加密货币、贵金属和美股
的实时行情。它不内置固定的币种表，而是按需向你所选的数据源解析标的，因此新上线的市场无需
更新插件即可支持；同时提供单资产价格提醒和极速涨跌提醒。

## 插件信息

| 项目 | 值 |
| --- | --- |
| 清单 id | `chengongliang/market-watch` |
| 版本 | 2.0.9 |
| 插件 API | 26 |
| 外部依赖 | `curl` |

入口说明：

- `service` — 无界面的数据引擎：标的解析、行情队列、提醒规则、图标缓存和运行时状态都由它
  管理，并通过插件的共享状态通道发布给其他入口。
- `bar` — 状态栏小部件：单个资产、涨跌配色和箭头。
- `watch` — 行情表格：每个自选资产的最新价、24 小时涨跌幅、最高价和最低价。
- `settings` — 设置面板：自选列表、状态栏资产、显示模式、价格提醒、极速提醒以及配置导入导出。

用命令行打开面板：

```sh
noctalia msg panel-toggle chengongliang/market-watch:watch
noctalia msg panel-toggle chengongliang/market-watch:settings
```

状态栏小部件左键点击打开行情面板，右键绑定到宿主提供的“小部件设置”对话框（详见“使用方法”）。
`service` 同时响应插件 IPC，例如：

```sh
noctalia msg plugin chengongliang/market-watch:service focused refresh-now
noctalia msg plugin chengongliang/market-watch:service focused force-refresh
noctalia msg plugin chengongliang/market-watch:service focused toggle-mode
noctalia msg plugin chengongliang/market-watch:service focused toggle-panel
noctalia msg plugin chengongliang/market-watch:service focused status
```

## 依赖要求

- `curl` — 所有网络请求都通过它完成：标的解析、每一条行情、图标搜索和图标下载。已在清单的
  `dependencies` 中声明。

此外需要支持插件 API 26 的 Noctalia 版本；插件会写入若干文件（见下文“状态与文件”）。除
`curl` 之外没有其他外部程序依赖。

## 使用方法

1. 在小部件选择器中把 **Market Watch** 添加到状态栏。
2. 打开设置面板（`noctalia msg panel-toggle chengongliang/market-watch:settings`），或在行情
   面板中点击齿轮按钮，然后搜索资产代码（例如 `btc`、`xau`、`aapl`）并点击结果加入自选列表。
3. 使用上下箭头调整顺序，使用垃圾桶按钮移除。若移除的正是当前状态栏资产，会自动改用列表首项。
4. 选择状态栏资产与显示模式，并可为每个资产设置可选的上限价和下限价，或启用极速涨跌提醒并
   勾选需要监控的资产。
5. 左键点击状态栏小部件打开行情表格，每行显示最新价、24 小时涨跌幅、最高价和最低价。
6. 在状态栏小部件上滚动滚轮，可在自选列表中依次切换状态栏显示的资产，顺序与设置面板
   中的顺序一致，首尾循环，一次操作即可翻遍全部资产；只添加一个资产时无从切换。
7. 若不想手动切换，可在设置面板中打开 **状态栏轮播**：小部件会按设定的*间隔*（2–60 秒，
   默认 5 秒）自动切换显示的资产。轮播范围是每一行左侧开关所**关注**的资产；一个都不关注时
   则轮播整个自选列表。可用轮播区的 `<` `>` 按钮手动切换，也可以直接用滚轮：轮播开启时，
   滚轮的一格会推动轮播本身（而不只是改一次显示），并重新计时，因此你的选择不会被紧接着的
   自动切换覆盖。轮播与面板是否打开无关，且自身不会发起任何网络请求。

轮播与滚轮共用同一份状态 `bar_coin`：轮播从不改写它，因此关闭轮播后状态栏会回到你最后一次
手动选择的资产。若当前资产不可交易而至少还有一个已关注资产可用，会自动跳过，状态栏不会停在
`--`；从自选列表移除的资产也会自动退出轮播。

在 Noctalia v5 中，状态栏手势属于用户配置。本插件提供四个默认绑定：`left = "none"`，使小部件
自身的点击处理函数打开行情面板；`right = "settings-open-widget"`；`scroll_up` 与
`scroll_down = "none"`，使滚轮事件交给小部件而不是被宿主消费。v4 的右键菜单（打开面板、
切换显示模式、设置、立即刷新）在 v5 中无法实现为右键菜单，因为上下文菜单 API 只属于面板；
对应功能改由面板的刷新/设置按钮以及上文列出的 IPC 事件提供。

## 设置项

第一组设置由宿主根据清单渲染。插件只能读取、无法写入，因此它们是配置中“静态”的一半：

| 设置 | 类型 | 默认值 | 作用 |
| --- | --- | --- | --- |
| 数据源 | 选择 | `huobi` | 提供标的解析与行情：Huobi、Binance、OKX 或 CoinGecko。 |
| 市场类型 | 选择 | `spot` | 现货交易对或 USDT 永续合约；CoinGecko 只支持现货。 |
| 代理地址 | 字符串 | 空 | 可选 `http://host:port` 或 `socks5://host:port`，会传给每个 `curl` 调用。 |
| 刷新频率 | 整数，1-60 | 5 | 刷新周期（秒）；CoinGecko 最低为 10 秒。 |
| 红涨绿跌 | 布尔 | false | 涨为红色、跌为绿色，而非西式的绿涨红跌。 |

其余设置都在**设置面板**中编辑，并由 `service` 保存到 `pluginDataDir()/market.json`，因为
v5 插件无法写入设置：

- 自选资产列表（含顺序）和状态栏资产——初始值为内置的 btc、eth、bnb、sol、xrp，
  在此面板中可增删、调整顺序并搜索标的；
- 状态栏显示模式（完整文本或仅价格）；
- 每个资产的上限价与下限价提醒；
- 极速涨跌提醒：启用、波动阈值、观察窗口、冷却时间以及被监控的资产；
- 状态栏轮播：是否自动切换、间隔秒数，以及关注哪些资产（为空表示整个自选列表）。

配置导入导出使用 `~/Downloads/market-watch-config.json`。导出会写入该文件，导入会读取并
应用其中的运行时配置。导入旧版本导出的配置前，请将文件重命名为 `market-watch-config.json`
并放到 `~/Downloads/`。文件里的静态设置仅作参考，导入时插件会把这些键名提示出来，以便你在
宿主设置窗口中修改。

## 数据源

贵金属和美股以交易所上市的 USDT 永续合约形式出现（例如 HTX 上的 `AAPL-USDT`，或 OKX 上的
代币化股票永续），现货市场则只有加密货币交易对。

本插件不会下载整份合约目录，而是按需由资产名拼出符号，形状与 v4 的行情 URL 完全一致：

| 提供商 | 现货符号 | 永续符号 | 行情 | 可用性检查 |
| --- | --- | --- | --- | --- |
| Huobi | `btcusdt` | `BTC-USDT` | 日线 | 第一条行情 |
| Binance | `BTCUSDT` | `BTCUSDT` | 日线 | 单符号 `exchangeInfo?symbol=` |
| OKX | `BTC-USDT` | `BTC-USDT-SWAP` | 日线 | 单符号 `instruments?instId=` |
| CoinGecko | 币种 id，来自 `/search?query=` | 不支持 | 带 24 小时涨跌的 `simple/price` | `/search?query=` |

这是相对 v4 的有意改动：v4 用整份合约目录来解析自选列表，而 v5 的单个回调无法解析那么大的
响应体（仅 Huobi 现货目录就有约 1.4 MB，且子进程 stdout 在 1 MiB 处会被截断）。实际影响：

- 交易所不支持的符号会被标记为不可用：Binance、OKX 通过单符号接口确认，Huobi、CoinGecko 由
  第一条行情判定。
- 添加资产时的搜索不再遍历全部标的，而是改用小型搜索接口 —— CoinGecko 的 `/search?query=`
  与 TradingView 的符号搜索（后者也是找到代币化股票永续的途径）。输入经过防抖与缓存，不会
  每敲一个键就发一次请求。
- 已解析的标的信息（id、符号、名称、可用性）缓存在 `pluginDataDir()/instruments.json`，重启
  后无需重新解析或重新确认。

行情每次最多并发 4 个请求，失败的资产按指数退避重试（最多 5 分钟），期间界面上保留上一次的
有效价格并标记为过期。每次响应在解析前都会做大小检查，格式错误或过大的响应绝不会覆盖上一次
的有效价格。

## 提醒

- **价格提醒**：价格上穿上限或下穿下限时触发。首次采样只用于“布防”，因此启动时价格已经在
  阈值之外不会立刻提醒；等价格回到区间内后重新布防。
- **极速提醒**：把最新价与观察窗口内最早的样本比较。越过阈值只提醒一次，之后保持解除布防，
  直到价格回到区间内且冷却时间已过。
- 通知使用宿主的标准通知：v4 可以为每个提醒指定图标（上行、下行、铃铛），而 v5 的通知 API
  只接受标题和正文，因此方向信息改由文本表达。
- 提醒状态保存在内存中。插件重载时会重新布防，而不会为停机期间发生的穿越补发通知。

## 状态与文件

| 路径 | 写入方 | 内容 |
| --- | --- | --- |
| `pluginDataDir()/market.json` | `service` | 自选列表、状态栏资产、显示模式、两套提醒规则、状态栏轮播（开关、间隔、关注列表、当前序号）、模式版本号。 |
| `pluginDataDir()/instruments.json` | `service` | 在用标的的解析结果缓存。 |
| `pluginDataDir()/logos/<标的>.png 或 .svg` | `service` | 资产图标缓存。 |
| `pluginDataDir()/tradingview-logoids.json` | `service` | 已解析的 TradingView 图标 id，使符号搜索对每个资产最多执行一次。 |
| `~/Downloads/market-watch-config.json` | `settings` 面板 | 配置导出的目标文件，也是导入的来源。 |

图标的解析顺序与 v4 相同：先看提供商元数据，再做 CoinGecko 精确匹配，最后做不带类型过滤的
TradingView 符号搜索（这样才能覆盖代币化股票永续）。失败的查询最多每分钟重试一次。v4 会把
图标裁成圆形；`ui.image` 只能设置圆角，因此用半径近似原来的圆形遮罩，没有图标时回退为两字母
文字标记。TradingView 的图标是 SVG：若系统恰好安装了 `rsvg-convert` 会先栅格化，否则直接显示
SVG，若宿主无法解码则仍回退到文字标记。

## 从 v4 迁移

行情引擎、各提供商适配器和提醒规则都是按行为逐条移植的，包括符号语法、数值钳制、首次采样
布防规则和滚动窗口冷却。以下用户可见部分因 v5 移除或替换了相应机制而必须调整：

| v4 | v5 |
| --- | --- |
| 自定义 `Settings.qml` 页面 | 一个 `[[panel]]`（`settings`）加上宿主渲染的清单设置。 |
| `language` 设置与随包 `i18n/*.json` | 翻译跟随系统语言；插件提供 `translations/en.json` 与 `translations/zh-Hans.json`。 |
| `panelPosition`（居中/点击处） | 由宿主提供的面板放置方式、位置和“在点击处打开”，按面板单独设置。 |
| 四项右键菜单 | 手势绑定、IPC 事件与面板按钮；状态栏没有上下文菜单 API。 |
| 提醒图标（`arrow-up`、`arrow-down`、`bell-ringing`） | 仅文本通知。 |
| 圆形图标遮罩（`OpacityMask`） | `ui.image` 圆角，或两字母文字标记。 |
| `priceAlerts`、`rapidAlert`、`watchList`、`barCoin`、`displayMode` 作为插件设置 | 运行时状态保存在 `pluginDataDir()/market.json`，在设置面板中编辑。 |
| `barCoin` 在多个小部件实例间共享 | 保持不变：仍然是全局的单个状态栏资产，因为没有按实例设置的能力。 |
| `watchListSchemaVersion` 迁移标记 | 保留在 `market.json` 中；符号解析完成后立即把裸符号改写为提供商标的 id。 |
| 依赖整份合约目录的解析 | v5 中不可行（单个回调最多解析约 100 KB，捕获的 stdout 上限 1 MiB），改为按需拼符号，见[数据源](#数据源)。 |
| 搜索全部标的 | 改由 CoinGecko 与 TradingView 的搜索接口回答，因此只能搜到这些接口收录的品种。 |
| 目录请求失败会让面板一直停在“加载中” | 现在没有目录这一步，插件级错误只剩缺少 `curl`，其余都是逐标的的状态。 |
| 状态栏轮播：`barWatchList` + `barScrollInterval`，由 `Timer` 与上滑/淡出的 `NumberAnimation` 驱动 | 已移植为状态栏轮播（`carousel_ids` + `carousel_interval`）：按 2–60 秒间隔轮换已关注的资产。两点差异：上滑动画未复刻，因为 v5 没有动画原语——效果等同于 v4 在动画时长被设为 0 时的瞬时切换；关注集合为空时轮换整个自选列表，而不是什么都不轮换。 |
| 完全没有滚轮处理（`BarWidget.qml`、`Main.qml`、`Panel.qml` 中均无） | **v5 新增：** 滚轮可切换状态栏资产，轮播开启时则步进轮播。 |

导出的配置文件两种写法都兼容：移植版的蛇形命名，或 v4 的驼峰命名。

## 开发说明

提供商与提醒模块不依赖宿主 API，可直接用普通 Lua 解释器运行，因此 v4 的测试数据仍然有效：

```sh
lua5.4 tests/alerts_test.luau
lua5.4 tests/providers_test.luau
```

两套测试沿用 v4 的断言，并读取 `tests/fixtures/` 中未修改的固定数据，覆盖四个提供商的行情报文、
两个单符号确认报文、Huobi 永续目录的符号往返、由 CoinGecko 原始列表数据推导出的币种 id 解析、
TradingView 搜索与图标回退、价格格式化、穿越与冷却逻辑以及归一化的边界钳制。

service 同样写在 Lua 5.4 兼容的子集里，因此可以用模拟宿主在离线状态下配合同一批固定数据执行，
行情队列、防抖、退避与大小保护就是这样在没有真实 shell 的情况下验证的。

```sh
noctalia plugins lint .
python3 .github/workflows/validate-plugins.py
```

## 许可证

MIT，见仓库根目录的 LICENSE 文件。
