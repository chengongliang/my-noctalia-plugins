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

  return ui.row({ key = row.id, align = "center", gap = ROW_GAP }, {
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
    tostring(config and config.red_rises),
  }
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

local function render()
  dark_mode = noctalia.isDarkMode()

  local rows = {}
  for _, row in ipairs(watch) do
    table.insert(rows, data_row(row))
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
      .. noctalia.tr("data_source." .. tostring(config ~= nil and config.source or "huobi")),
    fontSize = 11,
    color = "on_surface_variant",
    textAlign = "center",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
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

panel.setWantsSecondTicks(true)

-- ── Events ──────────────────────────────────────────────────────────────────

function update()
  poll_state()
  if display_signature() == rendered_signature then
    return
  end
  render()
end

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
  -- Take the live snapshot before the first paint: without it the first frame would draw
  -- the defaults and wait for a service publish that may be a whole refresh_interval away.
  poll_state()
  render()
end

-- Switching between a light and a dark palette changes which rise/fall shades apply.
-- update() polls and folds the theme into the display signature, so a re-theme repaints on
-- the next tick without a callback.
