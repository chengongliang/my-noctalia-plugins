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
-- Rows are read-only, exactly as in v4: clicking a symbol did nothing there and
-- nothing is wired here either.

local providers = require("./lib/providers.luau")

local PLUGIN_ID = "chengongliang/market-watch"
local PANEL_SETTINGS = PLUGIN_ID .. ":settings"

-- Column widths lifted from v4's table (logical px, Icons/scaled by the host).
local COL_LOGO = 32
local COL_COIN = 80
local COL_PRICE = 140
local COL_CHANGE = 110
local COL_HIGH = 120
local COL_LOW = 120
local ROW_GAP = 6

local config = nil
local watch = {}
local quotes = {}
local statuses = {}
local logos = {}
local health = nil
local busy = true
local show_close_button = true

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

local function header_cell(text, width)
  return ui.label({
    text = text,
    width = width,
    fontSize = 11,
    fontWeight = "bold",
    color = "on_surface_variant",
  })
end

local function logo_cell(row)
  local path = logos[row.id]
  if path ~= nil and path ~= "" then
    -- v4 masked the logo into a circle (OpacityMask); ui.image only rounds
    -- corners, so radius = half the box is the closest equivalent.
    return ui.row({ width = COL_LOGO, align = "center", justify = "center" }, {
      ui.image({ path = path, width = 24, height = 24, radius = 12, fit = "contain" }),
    })
  end
  return ui.row({ width = COL_LOGO, align = "center", justify = "center" }, {
    ui.label({ text = fallback_badge(row.symbol), color = "on_surface_variant" }),
  })
end

local function data_row(row)
  local quote = quotes[row.id]
  local state = statuses[row.id]
  local stale = state ~= nil and state.status == "stale"
  local has_data = quote ~= nil

  local price_color = stale and "on_surface_variant"
    or providers.price_color(quote ~= nil and quote.is_rising, config ~= nil and config.red_rises, has_data)

  return ui.row({ key = row.id, align = "center", gap = ROW_GAP }, {
    logo_cell(row),
    ui.row({ width = COL_COIN }, {
      ui.label({ text = name_for(row), color = "on_surface", fontWeight = "medium", maxLines = 1 }),
    }),
    ui.label({
      text = providers.format_price(quote ~= nil and quote.close),
      width = COL_PRICE,
      color = price_color,
    }),
    ui.label({
      text = providers.format_change(quote ~= nil and quote.change),
      width = COL_CHANGE,
      color = price_color,
    }),
    ui.label({
      text = providers.format_price(quote ~= nil and quote.high),
      width = COL_HIGH,
      fontSize = 12,
      color = "on_surface_variant",
    }),
    ui.label({
      text = providers.format_price(quote ~= nil and quote.low),
      width = COL_LOW,
      fontSize = 12,
      color = "on_surface_variant",
    }),
  })
end

local function header_row()
  return ui.row({ align = "center", gap = ROW_GAP, key = "table_header" }, {
    ui.box({ width = COL_LOGO, height = 1 }),
    header_cell(noctalia.tr("panel.coin"), COL_COIN),
    header_cell(noctalia.tr("panel.price"), COL_PRICE),
    header_cell(noctalia.tr("panel.change"), COL_CHANGE),
    header_cell(noctalia.tr("panel.high"), COL_HIGH),
    header_cell(noctalia.tr("panel.low"), COL_LOW),
  })
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

local function render()
  local columns = { header_row() }

  for _, row in ipairs(watch) do
    table.insert(columns, data_row(row))
  end

  local body = {
    ui.row({ align = "center", gap = 8, key = "header" }, {
      ui.glyph({ name = "chart-line", size = 18, color = "primary" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({
          text = noctalia.tr("panel.refresh")
            .. ": "
            .. tostring(config ~= nil and config.refresh_interval or 5)
            .. " "
            .. noctalia.tr("settings.seconds"),
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

  if show_close_button then
    table.insert(body[1].children, ui.button({
      key = "close",
      glyph = "close",
      variant = "ghost",
      tooltip = noctalia.tr("panel.close"),
      onClick = "onCloseClicked",
    }))
  end

  local status = status_box()
  if status ~= nil then
    table.insert(body, status)
  end

  -- The table is hidden while loading or while the plugin reports a problem, so the
  -- status box is the only thing on screen then (v4 toggled the same two blocks).
  if busy ~= true and ((health == nil) or health.error == "") then
    table.insert(body, ui.scroll({ key = "table", flexGrow = 1, gap = ROW_GAP }, columns))
  end

  table.insert(body, ui.label({
    key = "footer",
    text = noctalia.tr("panel.data_from")
      .. ": "
      .. noctalia.tr("data_source." .. tostring(config ~= nil and config.source or "huobi")),
    fontSize = 11,
    color = "on_surface_variant",
    textAlign = "center",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
end

-- ── State ───────────────────────────────────────────────────────────────────

noctalia.state.watch("market.config", function(value)
  config = value
  render()
end)

noctalia.state.watch("market.watch", function(value)
  watch = value or {}
  render()
end)

noctalia.state.watch("market.quotes", function(value)
  quotes = value or {}
  render()
end)

noctalia.state.watch("market.status", function(value)
  statuses = value or {}
  render()
end)

noctalia.state.watch("market.logos", function(value)
  logos = value or {}
  render()
end)

noctalia.state.watch("market.health", function(value)
  health = value
  render()
end)

noctalia.state.watch("market.busy", function(value)
  busy = value ~= false
  render()
end)

-- ── Events ──────────────────────────────────────────────────────────────────

function onRefreshClicked()
  -- v4's refresh button refetched every watched instrument without forcing, so
  -- the per-instrument backoff still applied.
  send({ op = "refresh_all" })
end

function onSettingsClicked()
  noctalia.togglePanel(PANEL_SETTINGS)
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  -- Read on every open: it does not reload when the shell setting changes.
  -- Only an explicit false hides the button (the host's own convention).
  show_close_button = noctalia.getSetting("shell.show_close_buttons") ~= false
  render()
end
