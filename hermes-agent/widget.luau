--!nonstrict
-- Hermes Agent bar widget - the [[widget]] entry.
--
-- Port of the v4 BarWidget.qml. The pill is a status indicator: the Hermes icon, a small
-- status-coloured dot, and the status word (icon only on a vertical bar).
--
-- Everything comes from the bridge service over noctalia.state - the widget never talks to
-- HTTP itself. The service publishes:
--   hermes.state    the snapshot (hermes.status, session.running, summary.gateway.status)
--   hermes.bridge   { status = "online"|"offline", error }
--
-- v4 built the pill from raw Qt items and an NIcon fallback. The declarative tree here has
-- no way to detect a failed image load, so the icon is always the shipped asset and the
-- per-status glyph set (power / loader / bell-ringing / ...) is not rendered; the status is
-- carried by the dot colour and the status word instead.
--
-- Bar gestures are user configuration in v5: plugin.toml binds `left = "none"` so
-- onClick() fires, and `right = "settings-open-widget"` for this widget's settings. That
-- right-click replaces the v4 NPopupContextMenu, whose entries (open, new session,
-- interrupt, refresh, start gateway) all live in the chat panel now.

local PANEL_ID = "chengongliang/hermes-agent:chat"
local ICON = "assets/hermes-icon.png"
local ICON_SIZE = 18
local DOT_SIZE = 7

local state = nil
local bridge = { status = "offline", error = "" }
local hideWhenIdle = false
local vertical = false
local ticksSeen = 0

local STATUS_KEY = {
  offline = "status.offline",
  idle = "status.idle",
  busy = "status.busy",
  attention = "status.attention",
  degraded = "status.degraded",
  error = "status.error",
  unknown = "status.unknown",
}

-- Palette roles where one exists, literal shades for the two v4 warning colours (the store
-- has no amber/orange role).
local STATUS_COLOR = {
  offline = "error",
  error = "error",
  idle = "primary",
  busy = "primary",
  attention = "#f59e0b",
  degraded = "#f97316",
  unknown = "on_surface",
}

local function derivedStatus()
  local bridgeStatus = type(bridge) == "table" and tostring(bridge.status or "offline") or "offline"
  if bridgeStatus ~= "online" then
    return "offline"
  end
  local hermes = type(state) == "table" and state.hermes or nil
  local hermesStatus = type(hermes) == "table" and tostring(hermes.status or "unknown") or "unknown"
  if hermesStatus ~= "unknown" then
    return hermesStatus
  end
  -- Bridge up but Hermes has not reported a lifecycle status yet (no session has run and no
  -- status hook fired): fall back to the gateway, where a running gateway means idle.
  local summary = type(state) == "table" and state.summary or nil
  local gateway = type(summary) == "table" and summary.gateway or nil
  local gatewayStatus = type(gateway) == "table" and tostring(gateway.status or "") or ""
  if gatewayStatus == "running" then
    return "idle"
  end
  return "unknown"
end

local function statusText(status)
  return noctalia.tr(STATUS_KEY[status] or "status.unknown")
end

-- v4 hid the word for idle/unknown (and always on a vertical bar) and used "!" for the
-- needs-attention state.
local function displayText(status)
  if vertical or status == "idle" or status == "unknown" then
    return ""
  end
  if status == "attention" then
    return "!"
  end
  return statusText(status)
end

local function modelLabel()
  local hermes = type(state) == "table" and state.hermes or nil
  if type(hermes) == "table" then
    return tostring(hermes.model or "")
  end
  return ""
end

local function bridgeError()
  if type(bridge) == "table" and type(bridge.error) == "string" then
    return bridge.error
  end
  return ""
end

local function tooltipText(status)
  local text = noctalia.tr("widget.tooltip", { status = statusText(status) })
  local model = modelLabel()
  if model ~= "" then
    text = text .. noctalia.tr("widget.tooltip_model", { model = model })
  end
  local err = bridgeError()
  if err ~= "" then
    text = text .. noctalia.tr("widget.tooltip_error", { error = err })
  end
  return text
end

local function render()
  -- Refresh the orientation once the host has ticked at least once; a state watch can fire
  -- before the first update(), and isVertical() is only meaningful for a placed widget.
  if ticksSeen > 0 then
    vertical = barWidget.isVertical()
  end

  local status = derivedStatus()

  -- v4 collapsed the pill to zero size; setVisible is the v5 equivalent.
  if hideWhenIdle and status == "idle" then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setTooltip(tooltipText(status))

  local color = STATUS_COLOR[status] or "on_surface"
  local text = displayText(status)

  local icon = ui.image({ path = ICON, width = ICON_SIZE, height = ICON_SIZE, fit = "contain" })
  local dot = ui.box({ width = DOT_SIZE, height = DOT_SIZE, radius = 4, fill = color })

  if vertical then
    barWidget.render(ui.column({ align = "center", gap = 2 }, { icon, dot }))
    return
  end

  local children = { icon, dot }
  if text ~= "" then
    table.insert(children, ui.label({ text = text, color = color, fontWeight = "semibold" }))
  end
  barWidget.render(ui.row({ gap = 5, align = "center" }, children))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function update()
  ticksSeen += 1
  if ticksSeen == 1 then
    -- Render on the first tick with the host's default cadence, then relax: the state
    -- watches below deliver live changes, so this tick only refreshes configuration.
    noctalia.setUpdateInterval(5000)
  end

  hideWhenIdle = noctalia.getConfig("hideWhenIdle") == true
  render()
end

noctalia.state.watch("hermes.bridge", function(value)
  bridge = type(value) == "table" and value or { status = "offline", error = "" }
  render()
end)

noctalia.state.watch("hermes.state", function(value)
  state = type(value) == "table" and value or nil
  render()
end)
