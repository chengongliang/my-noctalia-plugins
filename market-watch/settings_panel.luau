--!nonstrict
-- Market Watch settings panel - the v4 Settings.qml, rebuilt as a panel.
--
-- v5 has no settings script: the host renders the manifest's [[setting]] blocks and
-- `noctalia.getConfig` is read-only, so nothing the user edits here can be written
-- back as a setting. Everything runtime-mutable therefore moves into this panel and
-- is persisted by the service in pluginDataDir()/market.json:
--
--   watch list, bar_coin, display_mode, price_alerts, rapid_alert, carousel
--
-- The read-only settings (data source, market type, proxy, refresh interval, colour
-- scheme) stay in the host settings window; this panel names them so the user knows
-- where they live.
--
-- Every mutation is published on the `market.cmd` channel and the panel re-renders
-- from what the service echoes back in market.config, so the panel never holds
-- authoritative state - it only holds the search box and the export/import message.

local alerts = require("./lib/alerts.luau")

local PLUGIN_ID = "chengongliang/market-watch"

local config = nil
local watch = {}
local instruments = {}
local search_reply = nil
local config_message = nil
local health = nil

-- Search box state. ui.input is uncontrolled: `value` seeds the field once, so
-- clearing it needs a fresh `key` (the same trick wallhaven uses).
local search_text = ""
local search_key_generation = 0
local show_close_button = true

local command_seq = 0

local function send(command)
  command_seq = command_seq + 1
  command.nonce = tostring(noctalia.nowMs()) .. "-" .. tostring(command_seq)
  noctalia.state.set("market.cmd", command)
end

local function tr(key)
  return noctalia.tr(key)
end

local function price_field(value)
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function name_for(row)
  local symbol = row.symbol or ""
  local name = row.name or ""
  if name ~= "" and string.lower(name) ~= string.lower(symbol) then
    return symbol .. " (" .. name .. ")"
  end
  return symbol
end

local function alert_rule(id)
  local rules = (config and config.price_alerts) or {}
  return rules[id] or { enabled = false, upper_price = nil, lower_price = nil }
end

local function rapid_selected(id)
  local rapid = (config and config.rapid_alert) or {}
  for _, instrument_id in ipairs(rapid.instrument_ids or {}) do
    if instrument_id == id then
      return true
    end
  end
  return false
end

-- The followed subset arrives resolved (never empty while the watch list has entries):
-- an empty list in market.json means "rotate everything", and the service publishes the
-- effective set so the toggles here can simply ask whether the id is in it.
local function carousel_followed(id)
  local carousel = (config and config.carousel) or {}
  local ids = carousel.ids
  if type(ids) ~= "table" or #ids == 0 then
    return true
  end
  for _, instrument_id in ipairs(ids) do
    if instrument_id == id then
      return true
    end
  end
  return false
end

local function carousel_state()
  return (config and config.carousel)
    or { enabled = false, interval = 10, ids = {}, index = 0, entry = "" }
end

local function section(title, description, children)
  local body = {}
  table.insert(body, ui.label({ text = title, fontWeight = "bold", color = "on_surface" }))
  if description ~= nil and description ~= "" then
    table.insert(body, ui.label({ text = description, fontSize = 11, color = "on_surface_variant" }))
  end
  for _, child in ipairs(children) do
    table.insert(body, child)
  end
  return ui.column({ gap = 8 }, body)
end

local function labelled_input(label_text, field_key, value, placeholder, handler)
  return ui.column({ flexGrow = 1, gap = 2 }, {
    ui.label({ text = label_text, fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = field_key,
      value = value,
      placeholder = placeholder,
      onChange = handler,
    }),
  })
end

-- ── Watch list ──────────────────────────────────────────────────────────────

local function search_section()
  local children = {
    ui.input({
      key = "watch_search_" .. tostring(search_key_generation),
      value = search_text,
      placeholder = tr("settings.search_placeholder"),
      onChange = "onSearchChange",
    }),
  }

  table.insert(children, ui.label({
    text = tr("settings.search_note"),
    fontSize = 11,
    color = "on_surface_variant",
  }))

  if search_text ~= "" then
    -- The reply carries display fields, not just ids: results are built on demand
    -- now, so a freshly searched instrument may not be in market.instruments yet.
    local results = (search_reply and search_reply.results) or {}
    table.insert(children, ui.label({
      text = tr("settings.search_results"),
      fontSize = 11,
      color = "on_surface_variant",
    }))

    if #results == 0 then
      table.insert(children, ui.label({
        text = search_reply ~= nil and search_reply.pending == true
            and tr("settings.search_pending")
          or tr("settings.search_empty"),
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end

    for _, result in ipairs(results) do
      local id = result.id
      local label = name_for({ symbol = result.symbol, name = result.name })
      table.insert(children, ui.button({
        key = "result_" .. tostring(id),
        text = label,
        glyph = "plus",
        variant = "ghost",
        contentAlign = "start",
        onClick = function()
          send({ op = "add_watch", ref = id })
          -- A fresh key clears the field, and the empty query clears the results.
          search_text = ""
          search_key_generation = search_key_generation + 1
          send({ op = "search", query = "" })
        end,
      }))
    end
  end

  return ui.column({ gap = 8 }, children)
end

local function watch_section()
  local rows = {}
  local total = #watch

  for index, row in ipairs(watch) do
    local unavailable = row.available == false
    local label = name_for(row)
    if unavailable then
      label = label .. " (" .. tr("settings.unavailable") .. ")"
    end

    -- Fixed-width arrow/trash buttons keep every row aligned, exactly like v4's
    -- NIconButton row, and stay keyboard reachable through the tab order.
    table.insert(rows, ui.row({ key = "watch_" .. tostring(row.id), align = "center", gap = 6 }, {
      -- Follow toggle: this is the carousel's subset, so it belongs on the row it
      -- applies to rather than in a separate list that could drift out of order.
      ui.toggle({
        key = "follow_" .. tostring(row.id),
        checked = carousel_followed(row.id),
        onChange = function()
          send({ op = "set_carousel", toggle_id = row.id })
        end,
      }),
      ui.label({ text = label, flexGrow = 1, color = unavailable and "on_surface_variant" or "on_surface" }),
      ui.button({
        key = "up_" .. tostring(row.id),
        glyph = "arrow-up",
        variant = "ghost",
        tooltip = tr("settings.move_up"),
        enabled = index > 1,
        onClick = function()
          send({ op = "move_watch", id = row.id, delta = -1 })
        end,
      }),
      ui.button({
        key = "down_" .. tostring(row.id),
        glyph = "arrow-down",
        variant = "ghost",
        tooltip = tr("settings.move_down"),
        enabled = index < total,
        onClick = function()
          send({ op = "move_watch", id = row.id, delta = 1 })
        end,
      }),
      ui.button({
        key = "remove_" .. tostring(row.id),
        glyph = "trash",
        variant = "ghost",
        tooltip = tr("settings.remove"),
        onClick = function()
          send({ op = "remove_watch", id = row.id })
        end,
      }),
    }))
  end

  if #rows == 0 then
    table.insert(rows, ui.label({ text = tr("settings.watch_empty"), fontSize = 11, color = "on_surface_variant" }))
  end

  return ui.column({ gap = 6 }, rows)
end

-- ── Bar ─────────────────────────────────────────────────────────────────────

local function bar_section()
  local options = {}
  local bar_index = 0
  for index, row in ipairs(watch) do
    table.insert(options, row.symbol)
    if config ~= nil and config.bar_coin == row.id then
      bar_index = index - 1
    end
  end

  local display_options = { tr("settings.display_mode_full"), tr("settings.display_mode_compact") }
  local display_index = (config ~= nil and config.display_mode == "compact") and 1 or 0

  -- ui.select has no empty state: with nothing watched, point at the watch list.
  local bar_coin_control = #options == 0
      and ui.label({ text = tr("settings.watch_empty"), fontSize = 11, color = "on_surface_variant" })
    or ui.select({
      key = "bar_coin",
      options = options,
      selectedIndex = bar_index,
      onChange = function(index, _text)
        local row = watch[(tonumber(index) or 0) + 1]
        if row ~= nil then
          send({ op = "set_bar_coin", id = row.id })
        end
      end,
    })

  return ui.column({ gap = 10 }, {
    ui.column({ gap = 2 }, {
      ui.label({ text = tr("settings.bar_coin"), fontSize = 11, color = "on_surface_variant" }),
      bar_coin_control,
    }),
    ui.column({ gap = 2 }, {
      ui.label({ text = tr("settings.display_mode"), fontSize = 11, color = "on_surface_variant" }),
      ui.select({
        key = "display_mode",
        options = display_options,
        selectedIndex = display_index,
        onChange = function(index, _text)
          local wanted = (tonumber(index) or 0) == 1 and "compact" or "text"
          if config == nil or config.display_mode ~= wanted then
            send({ op = "toggle_display_mode" })
          end
        end,
      }),
    }),
  })
end

-- ── Bar carousel ────────────────────────────────────────────────────────────
-- New capability, not a v4 restoration: v4 could only show one fixed asset. The
-- service owns the timing; this section only edits the runtime state it publishes.

local function carousel_section()
  local carousel = carousel_state()
  local enabled = carousel.enabled == true
  local total = #(carousel.ids or {})

  return ui.column({ gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.toggle({
        key = "carousel_enabled",
        checked = enabled,
        onChange = function(value)
          send({ op = "set_carousel", enabled = value == "true" })
        end,
      }),
      ui.label({ text = tr("settings.carousel_enabled"), flexGrow = 1, color = "on_surface" }),
    }),
    -- The interval input is uncontrolled, so the effective (clamped) value is echoed
    -- beside it, exactly like the rapid-alert fields: typing 1 lands on 3 and says so.
    ui.row({ align = "center", gap = 8 }, {
      labelled_input(
        tr("settings.carousel_interval") .. " (" .. tr("settings.seconds") .. ")",
        "carousel_interval",
        tostring(carousel.interval),
        "",
        function(value)
          send({ op = "set_carousel", interval = value })
        end
      ),
      ui.label({
        text = tostring(carousel.interval) .. tr("settings.seconds"),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.button({
        key = "carousel_prev",
        glyph = "chevron-left",
        variant = "ghost",
        tooltip = tr("settings.carousel_prev"),
        enabled = enabled,
        onClick = function()
          send({ op = "set_carousel", step = -1 })
        end,
      }),
      ui.button({
        key = "carousel_next",
        glyph = "chevron-right",
        variant = "ghost",
        tooltip = tr("settings.carousel_next"),
        enabled = enabled,
        onClick = function()
          send({ op = "set_carousel", step = 1 })
        end,
      }),
      ui.label({
        text = tr("settings.carousel_now")
          .. ": "
          .. ((carousel.entry or "") ~= "" and carousel.entry or tr("panel.no_data"))
          .. "  "
          .. tostring(math.max(0, carousel.index or 0))
          .. "/"
          .. tostring(total),
        fontSize = 11,
        color = "on_surface_variant",
        flexGrow = 1,
      }),
    }),
    ui.label({ text = tr("settings.carousel_follow_hint"), fontSize = 11, color = "on_surface_variant" }),
  })
end

-- ── Price alerts ────────────────────────────────────────────────────────────

local function price_alerts_section()
  local rows = {}

  for _, row in ipairs(watch) do
    local rule = alert_rule(row.id)
    local valid = alerts.is_price_alert_valid(rule)
    local children = {
      ui.row({ align = "center", gap = 8 }, {
        ui.toggle({
          key = "pa_enabled_" .. tostring(row.id),
          checked = rule.enabled == true,
          onChange = function(value)
            send({ op = "set_price_alert", id = row.id, enabled = value == "true" })
          end,
        }),
        ui.label({
          text = name_for(row) .. "  " .. tr("settings.price_alert_enabled"),
          flexGrow = 1,
          color = "on_surface",
        }),
      }),
      ui.row({ gap = 8 }, {
        labelled_input(tr("settings.upper_price"), "pa_upper_" .. tostring(row.id), price_field(rule.upper_price), tr("settings.price_placeholder"), function(value)
          send({ op = "set_price_alert", id = row.id, upper = value })
        end),
        labelled_input(tr("settings.lower_price"), "pa_lower_" .. tostring(row.id), price_field(rule.lower_price), tr("settings.price_placeholder"), function(value)
          send({ op = "set_price_alert", id = row.id, lower = value })
        end),
      }),
    }

    -- v4 showed the same validation message when the lower bound was not below the
    -- upper one; the engine ignores an invalid range but keeps its state.
    if not valid then
      table.insert(children, ui.label({
        text = tr("settings.invalid_price_range"),
        fontSize = 11,
        color = "error",
      }))
    end

    table.insert(rows, ui.column({
      key = "price_alert_" .. tostring(row.id),
      gap = 6,
      fill = "surface_variant/0.25",
      radius = 8,
      padding = 8,
    }, children))
  end

  return ui.column({ gap = 8 }, rows)
end

-- ── Rapid alert ─────────────────────────────────────────────────────────────

local function rapid_section()
  local rapid = (config and config.rapid_alert)
    or { enabled = false, threshold_percent = 5, window_minutes = 5, cooldown_minutes = 30, instrument_ids = {} }

  local toggles = {}
  for _, row in ipairs(watch) do
    table.insert(toggles, ui.row({ key = "rapid_" .. tostring(row.id), align = "center", gap = 8 }, {
      ui.toggle({
        key = "rapid_toggle_" .. tostring(row.id),
        checked = rapid_selected(row.id),
        onChange = function()
          send({ op = "set_rapid_alert", toggle_instrument = row.id })
        end,
      }),
      ui.label({ text = name_for(row), flexGrow = 1, color = "on_surface" }),
    }))
  end

  return ui.column({ gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.toggle({
        key = "rapid_enabled",
        checked = rapid.enabled == true,
        onChange = function(value)
          send({ op = "set_rapid_alert", enabled = value == "true" })
        end,
      }),
      ui.label({ text = tr("settings.rapid_alert"), flexGrow = 1, color = "on_surface" }),
    }),
    -- The inputs are uncontrolled, so the effective (clamped) value is echoed
    -- beside them: typing 999 lands on 100 and the label says so.
    ui.label({
      text = tostring(rapid.threshold_percent)
        .. tr("settings.percent")
        .. " / "
        .. tostring(rapid.window_minutes)
        .. " "
        .. tr("settings.minutes")
        .. " / "
        .. tostring(rapid.cooldown_minutes)
        .. " "
        .. tr("settings.minutes"),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.row({ gap = 8 }, {
      labelled_input(tr("settings.rapid_threshold") .. " (" .. tr("settings.percent") .. ")", "rapid_threshold", tostring(rapid.threshold_percent), "", function(value)
        send({ op = "set_rapid_alert", threshold_percent = value })
      end),
      labelled_input(tr("settings.rapid_window") .. " (" .. tr("settings.minutes") .. ")", "rapid_window", tostring(rapid.window_minutes), "", function(value)
        send({ op = "set_rapid_alert", window_minutes = value })
      end),
      labelled_input(tr("settings.rapid_cooldown") .. " (" .. tr("settings.minutes") .. ")", "rapid_cooldown", tostring(rapid.cooldown_minutes), "", function(value)
        send({ op = "set_rapid_alert", cooldown_minutes = value })
      end),
    }),
    ui.label({ text = tr("settings.rapid_coins"), fontSize = 11, color = "on_surface_variant" }),
    ui.column({ gap = 4 }, toggles),
  })
end

-- ── Config file ─────────────────────────────────────────────────────────────

local function config_section()
  local children = {
    ui.label({ text = tr("settings.config_path"), fontSize = 11, color = "on_surface_variant" }),
    ui.row({ gap = 8 }, {
      ui.button({ key = "export", text = tr("settings.export"), onClick = "onExportClicked" }),
      ui.button({ key = "import", text = tr("settings.import"), onClick = "onImportClicked" }),
    }),
  }

  if config_message ~= nil then
    local text = tr(config_message.key)
    if (config_message.detail or "") ~= "" then
      text = text .. " - " .. config_message.detail
    end
    table.insert(children, ui.label({
      text = text,
      fontSize = 11,
      color = config_message.error == true and "error" or "primary",
    }))
  end

  return ui.column({ gap = 8 }, children)
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function render()
  local body = {
    ui.row({ align = "center", gap = 8, key = "settings_header" }, {
      ui.glyph({ name = "settings", size = 18, color = "primary" }),
      ui.label({ text = tr("panel.settings"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    }),
    ui.label({ text = tr("settings.static_note"), fontSize = 11, color = "on_surface_variant" }),
    ui.separator(),
  }

  if show_close_button then
    table.insert(body[1].children, ui.button({
      key = "close",
      glyph = "close",
      variant = "ghost",
      tooltip = tr("panel.close"),
      onClick = "onCloseClicked",
    }))
  end

  if health ~= nil and health.error ~= "" then
    table.insert(body, ui.label({ text = health.error, color = "error" }))
  end

  table.insert(body, ui.scroll({ key = "settings_body", flexGrow = 1, gap = 16 }, {
    section(tr("settings.watch_list"), tr("settings.watch_list_tip"), {
      search_section(),
      watch_section(),
    }),
    ui.separator(),
    section(tr("settings.bar"), tr("settings.bar_coin_desc"), { bar_section() }),
    ui.separator(),
    section(tr("settings.carousel"), tr("settings.carousel_desc"), { carousel_section() }),
    ui.separator(),
    section(tr("settings.price_alerts"), tr("settings.price_alerts_desc"), { price_alerts_section() }),
    ui.separator(),
    section(tr("settings.rapid_alert"), tr("settings.rapid_alert_desc"), { rapid_section() }),
    ui.separator(),
    section(tr("settings.config_mgmt"), "", { config_section() }),
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

noctalia.state.watch("market.instruments", function(value)
  instruments = value or {}
  render()
end)

noctalia.state.watch("market.health", function(value)
  health = value
  render()
end)

noctalia.state.watch("market.search", function(value)
  search_reply = value
  render()
end)

noctalia.state.watch("market.config_message", function(value)
  config_message = value
  render()
end)

-- ── Events ──────────────────────────────────────────────────────────────────

function onSearchChange(value)
  search_text = value or ""
  send({ op = "search", query = search_text })
end

function onExportClicked()
  send({ op = "export_config" })
end

function onImportClicked()
  send({ op = "import_config" })
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  -- Read on every open: it does not reload when the shell setting changes, and
  -- only an explicit false hides the button (the host's own convention).
  show_close_button = noctalia.getSetting("shell.show_close_buttons") ~= false
  -- Re-ask for the current results (the reply is a cache from a previous open) and
  -- drop a stale export/import message.
  config_message = nil
  render()
  send({ op = "search", query = search_text })
end
