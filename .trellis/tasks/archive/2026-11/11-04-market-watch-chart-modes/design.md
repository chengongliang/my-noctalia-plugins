# 设计

数据边界：provider历史点保留timestamp_ms/price并可含open/high/low/close。仅有限正数且low<=open/close<=high才可作为蜡烛。History.prepare按模式计算共同纵向范围并保留OHLC。

设置：runtime.chart_type取line或candle，store是唯一持久化所有者。service命令set_chart_type验证枚举、保存、发布market.config.chart_type；自定义设置面板下拉切换。无新外部命令/网络端点。

绘图：保留ui.graph曲线。原生API29无candlestick或叠层画布；蜡烛使用原生flex行/列、spacer和box组合，每根价格区间按共同范围计算flex权重；分组保证单节点子项<=256。最高/最低价采用图上方紧凑浮动读数，不预留左轴列。曲线hover只读取x对应样本、蜡烛hover显示OHLC。命名leave/hover回调避免重绘后的失效闭包。

修改边界：providers/history/panel负责图表；store/service/settings_panel负责设置；tests/翻译/README/manifest/catalog/spec同步。保留既有请求调度与行情提醒；无需新增依赖或提高API。
