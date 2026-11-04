# API与交互依据

权威定义/tmp/official-plugins/noctalia.d.luau：ui.graph仅支持values/values2、线宽、填充、API29规范化指针，无蜡烛/overlay属性；ui.row/column/box支持flexGrow、height、width和onHover，命名handler参数state/key。通过原生flex绘制，不新增伴随进程或SVG临时文件。

Context7 /noctalia-dev/noctalia图表文档确认：normY向下，与价格无关；应用应将normX映射到自己的序列。宿主每节点最多256子项，蜡烛必须分组。离线定义为准，不使用API40 pixelStream。

ui-ux-pro-max chart搜索：OHLC金融序列适合candlestick、悬停需可读OHLC；只有价格点时使用折线，禁止制造开高低收。
