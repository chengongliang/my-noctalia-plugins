--!nonstrict
-- Hermes Agent launcher provider - the [[launcher_provider]] entry.
--
-- Port of LauncherProvider.qml. The v4 provider matched a user-configurable prefix
-- (`launcherPrefix`, default ">hermes"); in v5 the prefix is owned by the manifest
-- (`prefix = "hermes"`, shown as /hermes) and there is no setting for it, so that setting is
-- gone. Everything else is preserved:
--
--   <text>  -> one-shot prompt through the bridge (`hermes -z <text>`), then open the panel
--   (empty) -> a hint plus open / new session, and resume when a stored session exists
--
-- v4 results carried an `onActivate` closure; v5 dispatches on `id`, so the same ids are
-- handled in onActivate below. The rows are ordered by `score`, highest first.

local PANEL_ID = "chengongliang/hermes-agent:chat"

local cmdSeq = 0
local lastText = ""

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

-- Same nonce trick the widget and panel use: two identical one-shots in a row must still be
-- a distinct value so the service's hermes.cmd watcher fires again.
local function sendCmd(cmd)
  cmdSeq += 1
  cmd.n = cmdSeq
  noctalia.state.set("hermes.cmd", cmd)
end

-- The resumable session id the bridge keeps alongside the live one; v4's "Resume Latest"
-- used exactly this field.
local function storedSessionId()
  local state = noctalia.state.get("hermes.state")
  if type(state) ~= "table" then
    return ""
  end
  local session = state.session
  if type(session) ~= "table" then
    return ""
  end
  return type(session.stored_id) == "string" and session.stored_id or ""
end

function onQuery(query)
  local text = trim(query)
  lastText = text

  local rows = {}

  if text ~= "" then
    table.insert(rows, {
      id = "ask",
      title = noctalia.tr("launcher.ask"),
      subtitle = text,
      glyph = "send",
      score = 1000,
    })
  else
    table.insert(rows, {
      id = "hint",
      title = noctalia.tr("launcher.type_prompt"),
      subtitle = noctalia.tr("launcher.type_prompt_subtitle"),
      glyph = "message-circle",
      score = 1000,
    })
  end

  table.insert(rows, {
    id = "open",
    title = noctalia.tr("launcher.open_panel"),
    subtitle = noctalia.tr("launcher.open_panel_description"),
    glyph = "panel-right-open",
    score = 950,
  })

  table.insert(rows, {
    id = "new_session",
    title = noctalia.tr("launcher.new_session"),
    subtitle = noctalia.tr("launcher.new_session_description"),
    glyph = "plus",
    score = 900,
  })

  -- v4 hid this row unless a stored session existed; keep that so the list is honest.
  if storedSessionId() ~= "" then
    table.insert(rows, {
      id = "resume",
      title = noctalia.tr("launcher.resume_latest"),
      subtitle = noctalia.tr("launcher.resume_latest_description"),
      glyph = "history",
      score = 850,
    })
  end

  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == "ask" then
    if lastText == "" then
      return
    end
    sendCmd({ op = "oneshot", text = lastText })
    noctalia.togglePanel(PANEL_ID)
    return
  end

  if id == "open" then
    noctalia.togglePanel(PANEL_ID)
    return
  end

  if id == "new_session" then
    sendCmd({ op = "new_session" })
    noctalia.togglePanel(PANEL_ID)
    return
  end

  if id == "resume" then
    local stored = storedSessionId()
    if stored ~= "" then
      sendCmd({ op = "resume", session_id = stored })
    end
    noctalia.togglePanel(PANEL_ID)
  end
end
