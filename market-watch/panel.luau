--!nonstrict
-- Market Watch detail panel - the v4 Panel.qml, ported to the declarative API.
--
-- Geometry is host-owned now: width/height/placement/position come from the
-- [[panel]] entry in plugin.toml (and stay user-adjustable in the host), so the
-- v4 contentPreferredWidth/Height * Style.uiScaleRatio computation is gone.
--
-- The v4 "center vs click" panel_position setting is dropped for the same reason:
-- placement, position and open-near-click are host-injected panel settings.
--
-- History is requested only by the visible detail view; the service keeps ownership
-- of provider access so it shares the same proxy, validation and instrument identity.

local providers = require("./lib/providers.luau")
local history = require("./lib/history.luau")

local PLUGIN_ID = "chengongliang/market-watch"
local PANEL_SETTINGS = PLUGIN_ID .. ":settings"

-- Table geometry.
--
-- v4 hard-coded column widths totalling 632 px, which happened to fill the 680 px panel
-- it declared. The v5 host owns the panel width - it is a user-overridable setting, and a
-- floating panel is routinely laid out wider than the manifest asks for - so a fixed
-- total leaves the table marooned on the left with dead space beside it. Every column is
-- therefore a container with a *minimum* width, and the asset column flexes to absorb
-- whatever slack the host's width leaves; the numbers stay right-aligned against the
-- panel edge instead of drifting.
--
-- The widths deliberately live on the row containers and never on the labels. A label's
-- own `width` is not honoured inside a flex row here, which is precisely what made the
-- header drift out of line with the data: the data rows led with two containers (logo,
-- asset) that did reserve their width, while every header cell was a bare label that
-- shrank to its text, bunching the headings together over the wrong columns.
local COL_LOGO = 32
local COLS = {
  { key = "coin", min = 84, flex = 1, align = "start" },
  { key = "price", min = 104, align = "end" },
  { key = "change", min = 88, align = "end" },
  { key = "high", min = 92, align = "end" },
  { key = "low", min = 92, align = "end" },
}
local ROW_GAP = 6
local HISTORY_REFRESH_MS = 30000

local config = nil
local watch = {}
local quotes = {}
local statuses = {}
local logos = {}
local health = nil
local busy = true
local show_close_button = true
-- The rise/fall palette is mode-dependent; refreshed on every poll so a theme switch is
-- picked up. See providers.price_color.
local dark_mode = true
-- The last drawing, so a poll that changes nothing visible does not rebuild the table.
local rendered_signature = nil
local opened = false
local selected_id = nil
local selected_timeframe = "5m"
local selected_source = nil
local selected_market = nil
local selected_proxy = nil
local selected_epoch = nil
local history_snapshot = nil
local prepared = nil
local prepared_signature = nil
local pointer_handlers = {}
local hover_point = nil
local hover_candle_key = nil
local next_history_at = 0
local pending_since = nil
local pending_revision = nil
local render
local select_asset

local command_seq = 0

local function send(command)
  -- Every command carries a nonce so two identical clicks in a row still register
  -- as a state change (the host may coalesce equal values).
  command_seq = command_seq + 1
  command.nonce = tostring(noctalia.nowMs()) .. "-" .. tostring(command_seq)
  noctalia.state.set("market.cmd", command)
end

local function fallback_badge(symbol)
  -- v4's getCoinIcon: the first two letters of the bare symbol, upper-cased.
  local text = tostring(symbol or "")
  if #text < 2 then
    return string.upper(text)
  end
  return string.upper(text:sub(1, 2))
end

local function name_for(row)
  local symbol = row.symbol or ""
  local name = row.name or ""
  if name ~= "" and string.lower(name) ~= string.lower(symbol) then
    return symbol .. " (" .. name .. ")"
  end
  return symbol
end

-- One table cell. The container carries the column width (containers do honour it) and the
-- label fills that container and aligns its own text inside it, so the header and the data
-- rows are built from a single geometry definition and cannot drift apart.
local function text_cell(index, text, props)
  local spec = COLS[index]
  local cell = { minWidth = spec.min, align = "center" }
  if spec.flex ~= nil then
    cell.flexGrow = spec.flex
  end
  local label = {
    text = text,
    flexGrow = 1,
    maxLines = 1,
    textAlign = spec.align,
  }
  if props ~= nil then
    for key, value in pairs(props) do
      label[key] = value
    end
  end
  return ui.row(cell, { ui.label(label) })
end

local function logo_cell(row)
  local path = logos[row.id]
  if path ~= nil and path ~= "" then
    -- v4 masked the logo into a circle (OpacityMask); ui.image only rounds
    -- corners, so radius = half the box is the closest equivalent.
    return ui.row({ minWidth = COL_LOGO, align = "center", justify = "center" }, {
      ui.image({ path = path, width = 24, height = 24, radius = 12, fit = "contain" }),
    })
  end
  return ui.row({ minWidth = COL_LOGO, align = "center", justify = "center" }, {
    ui.label({ text = fallback_badge(row.symbol), color = "on_surface_variant" }),
  })
end

local function data_row(row)
  local quote = quotes[row.id]
  local state = statuses[row.id]
  local stale = state ~= nil and state.status == "stale"
  local has_data = quote ~= nil

  local price_color = stale and "on_surface_variant"
    or providers.price_color(
      quote ~= nil and quote.is_rising,
      config ~= nil and config.red_rises,
      has_data,
      dark_mode
    )

  return ui.row({
    key = row.id,
    align = "center",
    gap = ROW_GAP,
    onClick = function() select_asset(row.id) end,
  }, {
    logo_cell(row),
    text_cell(1, name_for(row), { color = "on_surface", fontWeight = "medium" }),
    text_cell(2, providers.format_price(quote ~= nil and quote.close), { color = price_color }),
    text_cell(3, providers.format_change(quote ~= nil and quote.change), { color = price_color }),
    text_cell(4, providers.format_price(quote ~= nil and quote.high), {
      fontSize = 12,
      color = "on_surface_variant",
    }),
    text_cell(5, providers.format_price(quote ~= nil and quote.low), {
      fontSize = 12,
      color = "on_surface_variant",
    }),
  })
end

local function header_row()
  -- The logo column stays empty here. It used to be a 1 px `ui.box`, but a box is painted
  -- (it draws its fill), so the header carried a stray 32 px dash above the logos. An
  -- empty container reserves the same width and paints nothing.
  local cells = { ui.row({ minWidth = COL_LOGO }, {}) }
  for index, spec in ipairs(COLS) do
    cells[index + 1] = text_cell(index, noctalia.tr("panel." .. spec.key), {
      fontSize = 11,
      fontWeight = "bold",
      color = "on_surface_variant",
    })
  end
  return ui.row({ align = "center", gap = ROW_GAP, key = "table_header" }, cells)
end

local function status_box()
  local health_error = (health and health.error) or ""
  if busy ~= true and health_error == "" then
    return nil
  end

  -- v4 prefixed the status line with its own markers; keep them.
  -- A plugin-wide error outranks the loading text: it will not resolve by waiting.
  local text = health_error ~= "" and ("⚠️ " .. health_error)
    or (busy == true and ("⏳ " .. noctalia.tr("panel.loading")) or "")
  local color = health_error ~= "" and "error" or "on_surface_variant"

  return ui.row({
    key = "status",
    fill = "surface_variant/0.35",
    radius = 8,
    padding = 10,
    align = "center",
  }, {
    ui.label({ text = text, color = color, flexGrow = 1, textAlign = "center" }),
  })
end

-- Everything render() draws, folded into one string. A quiet market costs one poll and one
-- compare per tick instead of a rebuilt table, and a quote moving inside the same
-- formatting bucket produces no redraw at all.
local function display_signature()
  local parts = {
    tostring(dark_mode),
    tostring(show_close_button),
    tostring(busy),
    tostring(health and health.error or ""),
    tostring(config and config.refresh_interval),
    tostring(config and config.source),
    tostring(config and config.market_type),
    tostring(config and config.red_rises),
    tostring(config and config.chart_type),
    tostring(selected_id),
    selected_timeframe,
    tostring(history_snapshot and history_snapshot.epoch),
    tostring(history_snapshot and history_snapshot.revision),
    tostring(history_snapshot and history_snapshot.status),
    tostring(history_snapshot and history_snapshot.error_code),
    tostring(pending_since ~= nil),
    tostring(hover_point and hover_point.timestamp_ms),
    tostring(hover_point and hover_point.price),
    noctalia.formatTime("%Z %z"),
  }
  if selected_id ~= nil then
    for _, row in ipairs(watch) do
      if row.id == selected_id then
        parts[#parts + 1] = tostring(row.symbol) .. "\30" .. tostring(row.name) .. "\30" .. tostring(logos[selected_id])
        break
      end
    end
    return table.concat(parts, "\31")
  end
  for _, row in ipairs(watch) do
    local quote = quotes[row.id]
    local status = statuses[row.id]
    parts[#parts + 1] = table.concat({
      tostring(row.id),
      tostring(row.symbol),
      tostring(row.name),
      tostring(logos[row.id]),
      tostring(quote and quote.close),
      tostring(quote and quote.change),
      tostring(quote and quote.high),
      tostring(quote and quote.low),
      tostring(quote and quote.is_rising),
      tostring(status and status.status),
    }, "\30")
  end
  return table.concat(parts, "\31")
end

local function selected_row()
  for _, row in ipairs(watch) do
    if row.id == selected_id then
      return row
    end
  end
  return nil
end

local function local_time(timestamp_ms, pattern)
  return noctalia.formatTime(pattern or (selected_timeframe == "5m" and "%m-%d %H:%M %Z" or "%Y-%m-%d %H:%M %Z"), math.floor(timestamp_ms / 1000))
end

local function chart_id()
  return selected_id .. (selected_timeframe == "5m" and "" or "-" .. selected_timeframe)
end

local function detail_message()
  if history_snapshot == nil then
    return noctalia.tr("panel.loading"), "on_surface_variant"
  end
  if history_snapshot.status == "stale" then
    return noctalia.tr("history.update_failed"), "error"
  end
  if history_snapshot.status == "loading" or pending_since ~= nil then
    return noctalia.tr("panel.loading"), "on_surface_variant"
  end
  if history_snapshot.status == "unavailable" then
    return noctalia.tr("settings.unavailable"), "on_surface_variant"
  end
  if history_snapshot.error_code == "no-data" then
    return noctalia.tr("history.no_data"), "on_surface_variant"
  end
  if history_snapshot.status == "error" then
    return noctalia.tr("history.load_failed"), "error"
  end
  return nil
end

local function candle_plot()
  local pieces, group = {}, {}
  local span = prepared.window_end - prepared.window_start
  local cursor, group_start, group_end = prepared.window_start, nil, nil
  local range = prepared.high - prepared.low
  local body_w = #prepared.points <= 60 and 4 or (#prepared.points <= 120 and 3 or 2)
  local function add_part(children, weight, width, color)
    if weight <= 0 then return end
    if color ~= nil then
      children[#children + 1] = ui.box({ height = 0, flexGrow = weight, width = width, fill = color })
    else
      children[#children + 1] = ui.spacer({ height = 0, flexGrow = weight })
    end
  end
  local function flush()
    if #group == 0 then return end
    pieces[#pieces + 1] = ui.row({ width = 0, flexGrow = (group_end - group_start) / span, gap = 0, align = "stretch" }, group)
    group, group_start, group_end = {}, nil, nil
  end
  for index, point in ipairs(prepared.points) do
    local start_at = math.max(cursor, point.timestamp_ms)
    local end_at = math.min(prepared.window_end, point.timestamp_ms + prepared.interval_ms)
    if start_at > cursor then
      flush()
      pieces[#pieces + 1] = ui.spacer({ width = 0, flexGrow = (start_at - cursor) / span })
    end
    if end_at > start_at then
      local color = providers.price_color(point.close >= point.open, config.red_rises, true, dark_mode)
      local top, bottom = math.max(point.open, point.close), math.min(point.open, point.close)
      local children = {}
      if range > 0 then
        add_part(children, prepared.high - point.high, nil, nil)
        add_part(children, point.high - top, 1, color)
        if top > bottom then
          add_part(children, top - bottom, body_w, color)
        else
          children[#children + 1] = ui.box({ height = 1, width = body_w, fill = color })
        end
        add_part(children, bottom - point.low, 1, color)
        add_part(children, point.low - prepared.low, nil, nil)
      else
        children = {
          ui.spacer({ height = 0, flexGrow = 1 }),
          ui.box({ height = 1, width = body_w, fill = color }),
          ui.spacer({ height = 0, flexGrow = 1 }),
        }
      end
      group_start, group_end = group_start or start_at, end_at
      group[#group + 1] = ui.column({
        key = "history-candle-" .. chart_id() .. "-" .. tostring(index), width = 0,
        flexGrow = end_at - start_at, gap = 0, align = "center", onHover = "onCandleHover",
      }, children)
      -- The host accepts at most 256 direct children; a full day has ~288 candles.
      if #group >= 64 then flush() end
    end
    cursor = math.max(cursor, end_at)
  end
  flush()
  if cursor < prepared.window_end then
    pieces[#pieces + 1] = ui.spacer({ width = 0, flexGrow = (prepared.window_end - cursor) / span })
  end
  local groups = {}
  for first = 1, #pieces, 64 do
    local children, weight = {}, 0
    for index = first, math.min(first + 63, #pieces) do
      children[#children + 1] = pieces[index]
      weight = weight + pieces[index].props.flexGrow
    end
    groups[#groups + 1] = ui.row({ width = 0, flexGrow = weight, gap = 0, align = "stretch" }, children)
  end
  return groups
end

local function chart_body()
  local point = hover_point or prepared.points[#prepared.points]
  local currency = string.upper(providers.quote_currency(config.source))
  local interval_minutes = math.floor(prepared.interval_ms / 6000 + 0.5) / 10

  -- Price, change and rise/fall metrics
  local ref_open = hover_point and (hover_point.open or hover_point.price)
    or (prepared.points[1] and (prepared.points[1].open or prepared.points[1].price) or point.price)
  local curr_close = hover_point and (hover_point.close or hover_point.price)
    or (prepared.points[#prepared.points] and (prepared.points[#prepared.points].close or prepared.points[#prepared.points].price) or point.price)
  local is_rising = curr_close >= ref_open
  local color = providers.price_color(is_rising, config.red_rises, true, dark_mode)

  local change_amt = curr_close - ref_open
  local change_pct = ref_open > 0 and (change_amt / ref_open * 100) or 0
  local sign = change_amt >= 0 and "+" or ""
  local change_badge_text = sign .. providers.to_string(change_amt) .. " (" .. sign .. string.format("%.2f", change_pct) .. "%)"
  local badge_bg = is_rising and (dark_mode and "#39c38c26" or "#0a5c391a")
    or (dark_mode and "#ff704b26" or "#9c23181a")
  if config ~= nil and config.red_rises == true then
    badge_bg = is_rising and (dark_mode and "#ff704b26" or "#9c23181a")
      or (dark_mode and "#39c38c26" or "#0a5c391a")
  end

  local pieces = {}
  local cursor = prepared.window_start
  local span = prepared.window_end - prepared.window_start
  for index, segment in ipairs(prepared.chart_type == "line" and prepared.segments or {}) do
    if segment.start_at > cursor then
      table.insert(pieces, ui.spacer({ width = 0, flexGrow = (segment.start_at - cursor) / span }))
    end
    if #segment.points >= 2 then
      if pointer_handlers[index] == nil then
        local target_id, target_chart = selected_id, prepared
        pointer_handlers[index] = function(x, _y)
          if not opened or selected_id ~= target_id or prepared ~= target_chart then return end
          local next_point = history.price_at(segment, x)
          if next_point ~= nil and (hover_point == nil
            or next_point.timestamp_ms ~= hover_point.timestamp_ms or next_point.price ~= hover_point.price) then
            hover_point = next_point
            render()
          end
        end
      end
      table.insert(pieces, ui.graph({
        key = "history-" .. chart_id() .. "-" .. tostring(index),
        width = 0,
        flexGrow = (segment.end_at - segment.start_at) / span,
        values = history.graph_values(segment),
        color = color,
        lineWidth = 2,
        fillOpacity = 0.15,
        onPointerMove = pointer_handlers[index],
        onPointerLeave = "onHistoryPointerLeave",
      }))
    end
    cursor = segment.end_at
  end
  if cursor < prepared.window_end then
    table.insert(pieces, ui.spacer({ width = 0, flexGrow = (prepared.window_end - cursor) / span }))
  end
  if prepared.chart_type == "candle" then pieces = candle_plot() end

  local detail = noctalia.tr("history.interval", { minutes = string.format("%g", interval_minutes) })
    .. " · " .. noctalia.formatTime("%Z %z") .. " · " .. currency
  if prepared.chart_type == "candle" then
    local open_val = hover_point and hover_point.open or (prepared.points[1] and (prepared.points[1].open or prepared.points[1].price))
    local high_val = hover_point and hover_point.high or prepared.high
    local low_val = hover_point and hover_point.low or prepared.low
    local close_val = hover_point and hover_point.close or (prepared.points[#prepared.points] and (prepared.points[#prepared.points].close or prepared.points[#prepared.points].price))
    detail = noctalia.tr("history.ohlc", {
      open = providers.to_string(open_val),
      high = providers.to_string(high_val),
      low = providers.to_string(low_val),
      close = providers.to_string(close_val),
    })
  elseif config.chart_type == "candle" then
    detail = noctalia.tr("history.line_fallback") .. " · " .. detail
  end

  local nodes = {
    -- 1. TradingView-style price header: large rise/fall colored price + change badge
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        key = "history-readout",
        text = noctalia.tr("history.sample", {
          time = local_time(point.timestamp_ms), price = providers.to_string(point.price), currency = currency,
        }),
        fontSize = 18, fontWeight = "bold", color = color, maxLines = 1, baseline = "textFixedHeight",
      }),
      ui.box({
        paddingHorizontal = 8, paddingVertical = 2, radius = 4, fill = badge_bg,
      }, {
        ui.label({
          text = change_badge_text,
          fontSize = 12, fontWeight = "bold", color = color, maxLines = 1, baseline = "textFixedHeight",
        }),
      }),
    }),

    -- 2. TradingView-style HUD legend bar (OHLC or interval)
    ui.row({
      fill = "surface_variant/0.25", radius = 6, paddingHorizontal = 8, paddingVertical = 4,
      align = "center", justify = "space_between", gap = 8,
    }, {
      ui.label({
        text = detail,
        fontSize = 11, fontWeight = "medium", color = "on_surface_variant", maxLines = 1, baseline = "textFixedHeight",
      }),
      ui.label({
        text = hover_point ~= nil and local_time(point.timestamp_ms, selected_timeframe == "5m" and "%H:%M" or "%Y-%m-%d %H:%M")
          or (prepared.chart_type == "candle" and noctalia.tr(selected_timeframe == "5m" and "history.day_window" or "history.timeframes." .. selected_timeframe)
            or noctalia.tr("chart.line")),
        fontSize = 10, fontWeight = "bold", color = "primary", baseline = "textFixedHeight",
      }),
    }),
  }

  -- 3. High / Low chart bounds right above the plot (only needed for line charts; in candle mode the HUD already shows high/low)
  if prepared.chart_type ~= "candle" then
    table.insert(nodes, ui.row({ key = "history-bounds", justify = "space_between", align = "center", paddingHorizontal = 4 }, {
      ui.label({ text = noctalia.tr("history.high", { price = providers.to_string(prepared.high) }), fontSize = 11, fontWeight = "medium", color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("history.low", { price = providers.to_string(prepared.low) }), fontSize = 11, fontWeight = "medium", color = "on_surface_variant" }),
    }))
  end

  -- 4. Chart canvas card with subtle container styling
  table.insert(nodes, ui.row({
    key = "history-plot", flexGrow = 1, minHeight = 110, gap = 0, align = "stretch",
    fill = "surface_variant/0.12", radius = 6, paddingHorizontal = 2, paddingVertical = 2,
  }, pieces))

  -- 5. Time axis
  table.insert(nodes, ui.row({ justify = "space_between", paddingHorizontal = 4, gap = 8 }, {
    ui.label({ text = local_time(prepared.window_start), fontSize = 11, color = "on_surface_variant" }),
    ui.label({ text = local_time(prepared.window_end), fontSize = 11, color = "on_surface_variant" }),
  }))

  return nodes
end

local function detail_body(body)
  local buttons = {
    ui.label({ text = noctalia.tr("history.timeframe"), fontSize = 11, color = "on_surface_variant" }),
  }
  for _, timeframe in ipairs(providers.HISTORY_TIMEFRAMES) do
    local enabled = timeframe == "5m" or config.source ~= "coingecko"
    table.insert(buttons, ui.button({
      key = "history-timeframe-" .. timeframe,
      text = noctalia.tr("history.timeframes." .. timeframe),
      height = 24,
      fontSize = 11,
      variant = timeframe == selected_timeframe and "secondary" or "ghost",
      enabled = enabled,
      tooltip = not enabled and noctalia.tr("history.timeframe_unavailable") or nil,
      onClick = function() onHistoryTimeframeChanged(timeframe) end,
    }))
  end
  table.insert(body, ui.row({ key = "history-timeframes", align = "center", gap = 4 }, buttons))
  local drawable = prepared ~= nil and prepared.chart_type == "candle" and #prepared.points > 0
  for _, segment in ipairs(prepared and prepared.segments or {}) do
    if #segment.points >= 2 then drawable = true; break end
  end
  if drawable then
    for _, node in ipairs(chart_body()) do table.insert(body, node) end
  else
    table.insert(body, ui.spacer({ flexGrow = 1 }))
  end
  local message, color = detail_message()
  if message == nil and not drawable then
    message, color = noctalia.tr("history.no_data"), "on_surface_variant"
  end
  if message ~= nil then
    table.insert(body, ui.label({ text = message, color = color, fontSize = 12, maxLines = 2 }))
  end
  if history_snapshot ~= nil and (history_snapshot.status == "error" or history_snapshot.status == "unavailable") then
    table.insert(body, ui.button({
      text = noctalia.tr("history.retry"), onClick = "onRefreshClicked", enabled = pending_since == nil,
    }))
  end
end

render = function()
  dark_mode = noctalia.isDarkMode()

  local rows = {}
  if selected_id == nil then
    for _, row in ipairs(watch) do table.insert(rows, data_row(row)) end
  end
  local row = selected_row()

  local asset_logo = selected_id ~= nil and logos[selected_id]
  local leading_icon = (asset_logo ~= nil and asset_logo ~= "")
    and ui.image({ path = asset_logo, width = 20, height = 20, radius = 10, fit = "contain" })
    or ui.glyph({ name = "chart-line", size = 18, color = "primary" })

  local subtitle_text
  if selected_id ~= nil then
    local src = noctalia.tr("data_source." .. tostring(config ~= nil and config.source or "huobi"))
    local mkt = config ~= nil and config.market_type == "perpetual" and noctalia.tr("market_type.perpetual") or noctalia.tr("market_type.spot")
    subtitle_text = src .. " · " .. mkt .. " · " .. noctalia.tr("history.title")
  else
    subtitle_text = noctalia.tr("panel.refresh")
      .. ": "
      .. tostring(config ~= nil and config.refresh_interval or 5)
      .. " "
      .. noctalia.tr("settings.seconds")
  end

  local body = {
    ui.row({ align = "center", gap = 8, key = "header" }, {
      leading_icon,
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = row and name_for(row) or noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
        ui.label({
          text = subtitle_text,
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      -- v4's header had refresh (honouring the backoff), settings and close.
      ui.button({
        key = "refresh",
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh_now"),
        onClick = "onRefreshClicked",
      }),
      ui.button({
        key = "settings",
        glyph = "settings",
        variant = "ghost",
        tooltip = noctalia.tr("panel.settings"),
        onClick = "onSettingsClicked",
      }),
    }),
  }

  if selected_id ~= nil then
    table.insert(body[1].children, 1, ui.button({
      key = "history-back", glyph = "arrow-left", variant = "ghost",
      tooltip = noctalia.tr("history.back"), onClick = "onBackClicked",
    }))
  end

  if show_close_button then
    table.insert(body[1].children, ui.button({
      key = "close",
      glyph = "close",
      variant = "ghost",
      tooltip = noctalia.tr("panel.close"),
      onClick = "onCloseClicked",
    }))
  end

  if selected_id ~= nil then
    detail_body(body)
  else
    local status = status_box()
    if status ~= nil then table.insert(body, status) end
  end

  -- The table is hidden while loading or while the plugin reports a problem, so the
  -- status box is the only thing on screen then (v4 toggled the same two blocks).
  if selected_id == nil and busy ~= true and ((health == nil) or health.error == "") then
    -- The headings sit outside the scroll region: inside it they scroll away with the
    -- rows, leaving a column of unlabelled numbers once the list is longer than the
    -- panel. They are a DIRECT sibling of the scroll, which is what every official
    -- plugin does - wrapping the scroll in another flex column stops the host bounding
    -- its height, and an unbounded scroll region has nothing to scroll.
    table.insert(body, header_row())
    table.insert(body, ui.scroll({
      key = "table",
      flexGrow = 1,
      gap = ROW_GAP,
    }, rows))
  end

  table.insert(body, ui.label({
    key = "footer",
    text = noctalia.tr("panel.data_from")
      .. ": "
      .. noctalia.tr("data_source." .. tostring(config ~= nil and config.source or "huobi"))
      .. (selected_id ~= nil and (" · " .. noctalia.tr("market_type." .. tostring(config.market_type))) or ""),
    fontSize = 11,
    color = "on_surface_variant",
    textAlign = "center",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, body))
  -- Commit only after the tree was handed over: a render the host's CPU budget aborts is
  -- then retried on the next tick instead of freezing the panel on stale content.
  rendered_signature = display_signature()
end

-- ── State ───────────────────────────────────────────────────────────────────
--
-- State is POLLED, not subscribed. `noctalia.state.watch` looked like the natural fit but
-- the host's subscriptions can die for good after a hot reload of this file - the file
-- watcher does one on every save, and a plugin update does one too - while the service
-- keeps publishing normally; the entry then freezes on its last drawing with nothing in
-- the log. The bar widget hit exactly that and was moved to polling (see widget.luau); a
-- panel must not depend on the broken hook either.
--
-- Polling also fixes the first open. A panel runtime is created on first open, and watch
-- never replays the current value, so a panel opened between two service publishes used to
-- render the busy/empty defaults and stay blank until the next publish - up to the whole
-- refresh_interval (31 s with a slow setting). A poll at open (onOpen) renders the real
-- snapshot immediately.
--
-- The polling tick is one second while the panel is open (panel.setWantsSecondTicks), and a
-- tree is rebuilt only when the drawing actually changes - see display_signature().
local function poll_state()
  config = noctalia.state.get("market.config")
  watch = noctalia.state.get("market.watch") or {}
  quotes = noctalia.state.get("market.quotes") or {}
  statuses = noctalia.state.get("market.status") or {}
  logos = noctalia.state.get("market.logos") or {}
  health = noctalia.state.get("market.health")
  -- `false` is a meaningful stored value, so an `or` default would swallow it.
  busy = noctalia.state.get("market.busy") ~= false
  dark_mode = noctalia.isDarkMode()
end

local function clear_detail()
  selected_id, selected_source, selected_market, selected_proxy = nil, nil, nil, nil
  selected_epoch = nil
  history_snapshot, prepared, prepared_signature, hover_point = nil, nil, nil, nil
  hover_candle_key = nil
  pointer_handlers = {}
  next_history_at, pending_since, pending_revision = 0, nil, nil
end

local function poll_history()
  local snapshot = noctalia.state.get(history.state_key(selected_id, selected_timeframe))
  if snapshot ~= nil and (snapshot.id ~= selected_id or snapshot.source ~= selected_source
    or snapshot.market_type ~= selected_market or snapshot.epoch ~= config.history_epoch
    or (snapshot.timeframe or "5m") ~= selected_timeframe) then
    snapshot = nil
  end
  history_snapshot = snapshot
  if pending_since ~= nil and snapshot ~= nil and snapshot.status ~= "loading"
    and tostring(snapshot.revision) ~= pending_revision then
    pending_since, pending_revision = nil, nil
  end
  local signature = snapshot ~= nil and table.concat({
    tostring(snapshot.epoch), tostring(snapshot.revision), tostring(snapshot.updated_at),
    tostring(config.chart_type), selected_timeframe,
  }, ":") or ""
  if signature ~= prepared_signature then
    prepared_signature = signature
    prepared = snapshot ~= nil and history.prepare(snapshot.points or {}, snapshot.updated_at or noctalia.nowMs(), snapshot.interval_ms, config.chart_type, snapshot.window_ms) or nil
    pointer_handlers, hover_point = {}, nil
    hover_candle_key = nil
  end
end

local function request_history()
  if not opened or selected_id == nil then return end
  local now = noctalia.nowMs()
  -- Allow recovery if a host-aborted callback left a pending snapshot behind.
  if pending_since ~= nil and now - pending_since < 60000 then return end
  pending_since = now
  pending_revision = tostring(history_snapshot and history_snapshot.revision)
  next_history_at = now + HISTORY_REFRESH_MS
  send({ op = "history_request", id = selected_id, timeframe = selected_timeframe })
end

select_asset = function(id)
  if not opened then return end
  poll_state()
  clear_detail()
  selected_id = id
  if selected_row() == nil or config == nil then clear_detail(); return end
  if config.source == "coingecko" then selected_timeframe = "5m" end
  selected_source, selected_market, selected_proxy = config.source, config.market_type, config.proxy_url
  selected_epoch = config.history_epoch
  poll_history()
  request_history()
  render()
end

panel.setWantsSecondTicks(true)

-- ── Events ──────────────────────────────────────────────────────────────────

function update()
  if not opened then return end
  poll_state()
  if selected_id ~= nil then
    if config == nil or config.source ~= selected_source or config.market_type ~= selected_market or selected_row() == nil then
      clear_detail()
    else
      if config.proxy_url ~= selected_proxy or config.history_epoch ~= selected_epoch then
        selected_proxy, selected_epoch = config.proxy_url, config.history_epoch
        pending_since, pending_revision, next_history_at = nil, nil, 0
      end
      poll_history()
      if noctalia.nowMs() >= next_history_at then request_history() end
    end
  end
  if display_signature() == rendered_signature then
    return
  end
  render()
end

function onRefreshClicked()
  if not opened then return end
  if selected_id ~= nil then
    request_history()
    render()
    return
  end
  -- v4's refresh button refetched every watched instrument without forcing, so
  -- the per-instrument backoff still applied.
  send({ op = "refresh_all" })
end

function onHistoryTimeframeChanged(timeframe)
  if not opened or selected_id == nil or timeframe == selected_timeframe
    or providers.history_interval_ms(timeframe) == nil then return end
  poll_state()
  if config == nil or config.source ~= selected_source or config.market_type ~= selected_market or selected_row() == nil then
    clear_detail()
    render()
    return
  end
  if config.source == "coingecko" and timeframe ~= "5m" then return end
  selected_timeframe = timeframe
  pending_since, pending_revision, next_history_at = nil, nil, 0
  prepared_signature = nil
  poll_history()
  request_history()
  render()
end

function onSettingsClicked()
  noctalia.togglePanel(PANEL_SETTINGS)
end

function onCloseClicked()
  onClose()
  panel.close()
end

function onOpen(_context)
  opened = true
  clear_detail()
  selected_timeframe = "5m"
  -- Read on every open: it does not reload when the shell setting changes.
  -- Only an explicit false hides the button (the host's own convention).
  show_close_button = noctalia.getSetting("shell.show_close_buttons") ~= false
  -- Take the live snapshot before the first paint: without it the first frame would draw
  -- the defaults and wait for a service publish that may be a whole refresh_interval away.
  poll_state()
  render()
end

function onClose()
  opened = false
  clear_detail()
end

function onBackClicked()
  if not opened then return end
  clear_detail()
  render()
end

function onHistoryPointerLeave()
  if hover_point == nil then return end
  hover_point = nil
  if opened and selected_id ~= nil then render() end
end

function onCandleHover(state, key)
  if not opened or selected_id == nil or prepared == nil or prepared.chart_type ~= "candle" then return end
  if state == "true" then
    local index = tonumber(key:match("%-(%d+)$"))
    if index == nil or key ~= "history-candle-" .. chart_id() .. "-" .. tostring(index) then return end
    if prepared.points[index] == nil or hover_candle_key == key then return end
    hover_candle_key, hover_point = key, prepared.points[index]
  elseif key == hover_candle_key then
    hover_candle_key, hover_point = nil, nil
  else
    return
  end
  render()
end

-- Switching between a light and a dark palette changes which rise/fall shades apply.
-- update() polls and folds the theme into the display signature, so a re-theme repaints on
-- the next tick without a callback.
