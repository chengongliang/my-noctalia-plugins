--!nonstrict
-- Alert rules - a 1:1 port of the v4 AlertEngine.js.
--
-- Two independent rules live here:
--   * a per-instrument upper/lower price threshold that fires on a fresh crossing
--     and re-arms itself once the price comes back inside the band, and
--   * a rapid rise/fall detector over a rolling window with a cooldown.
--
-- Deliberately free of every host API (no `noctalia.*`): the same bytes run in
-- the shell's Luau VM and under a plain `lua5.4 tests/alerts_test.luau` harness,
-- which is how the port is verified. For the same reason this file sticks to
-- Lua 5.4 syntax - no `+=`, no string interpolation, no if-then-else
-- expressions - and the module returns a table instead of defining globals.
--
-- Key names are snake_case here (the v4 file used camelCase). Translation from
-- the legacy names happens once, in the config importer (lib/store.luau).

local Alerts = {}

-- JS Number(value): numbers and numeric strings only. nil, booleans and tables
-- are not usable numbers, and NaN/Infinity are rejected the way
-- Number.isFinite does in the original.
local function to_number(value)
  local kind = type(value)
  if kind ~= "number" and kind ~= "string" then
    return nil
  end
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return number
end
Alerts.to_number = to_number

-- v4 used String(id || "").trim() to normalise a JSON object key.
local function to_key(value)
  if value == nil then
    return ""
  end
  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end
Alerts.to_key = to_key

-- v4 guarded every nested payload with `typeof value === "object" && !Array.isArray(value)`.
-- JSON decoding cannot tell {} (empty array) from {} (empty object), so an array is
-- detected by its first integer index instead; the empty table is treated as an object,
-- which matches how the original handled {}.
local function is_object(value)
  if type(value) ~= "table" then
    return false
  end
  return value[1] == nil
end
Alerts.is_object = is_object

function Alerts.as_positive_number(value)
  local number = to_number(value)
  if number == nil or number <= 0 then
    return nil
  end
  return number
end

function Alerts.clamp_number(value, minimum, maximum, fallback)
  local number = to_number(value)
  if number == nil then
    return fallback
  end
  return math.max(minimum, math.min(maximum, number))
end

function Alerts.normalize_price_alert(value)
  local source = is_object(value) and value or {}
  return {
    enabled = source.enabled == true,
    upper_price = Alerts.as_positive_number(source.upper_price),
    lower_price = Alerts.as_positive_number(source.lower_price),
  }
end

function Alerts.normalize_price_alerts(value)
  local result = {}
  if not is_object(value) then
    return result
  end

  for id, rule in pairs(value) do
    local key = to_key(id)
    if key ~= "" then
      result[key] = Alerts.normalize_price_alert(rule)
    end
  end
  return result
end

-- A rule is valid unless both prices are set and the lower one is not below the
-- upper one; an invalid range never fires but still records its crossing state.
function Alerts.is_price_alert_valid(value)
  local rule = Alerts.normalize_price_alert(value)
  return rule.upper_price == nil
    or rule.lower_price == nil
    or rule.lower_price < rule.upper_price
end

function Alerts.normalize_rapid_alert(value)
  local source = is_object(value) and value or {}
  local ids = {}
  local seen = {}
  local raw_ids = type(source.instrument_ids) == "table" and source.instrument_ids or {}

  for _, id in ipairs(raw_ids) do
    local key = to_key(id)
    if key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(ids, key)
    end
  end

  return {
    enabled = source.enabled == true,
    -- The percentage keeps its fractional part; the time bounds are whole minutes.
    threshold_percent = Alerts.clamp_number(source.threshold_percent, 0.1, 100, 5),
    window_minutes = math.floor(Alerts.clamp_number(source.window_minutes, 1, 1440, 5) + 0.5),
    cooldown_minutes = math.floor(Alerts.clamp_number(source.cooldown_minutes, 1, 1440, 30) + 0.5),
    instrument_ids = ids,
  }
end

function Alerts.is_rapid_alert_selected(rule, instrument_id)
  local normalized = Alerts.normalize_rapid_alert(rule)
  if not normalized.enabled then
    return false
  end
  -- v4 compared String(instrumentId || "") without trimming.
  local wanted = instrument_id == nil and "" or tostring(instrument_id)
  for _, id in ipairs(normalized.instrument_ids) do
    if id == wanted then
      return true
    end
  end
  return false
end

-- Returns { state, triggers }. The state carries the crossing flags that make the
-- next call fire only on a fresh crossing; triggers is ordered upper-then-lower and
-- can hold two entries when both bounds are crossed by the same price.
function Alerts.evaluate_price_alert(rule, price, previous_state)
  local normalized = Alerts.normalize_price_alert(rule)
  local current_price = Alerts.as_positive_number(price)
  local previous = is_object(previous_state) and previous_state or {}

  local upper_reached = normalized.upper_price ~= nil
    and current_price ~= nil
    and current_price >= normalized.upper_price
  local lower_reached = normalized.lower_price ~= nil
    and current_price ~= nil
    and current_price <= normalized.lower_price

  local state = {
    initialized = current_price ~= nil,
    upper_triggered = upper_reached,
    lower_triggered = lower_reached,
  }
  local triggers = {}

  if not normalized.enabled or current_price == nil or not Alerts.is_price_alert_valid(normalized) then
    return { state = state, triggers = triggers }
  end

  -- The first sample only arms the rule: without it, restarting the shell while the
  -- price sits beyond a threshold would fire immediately.
  if previous.initialized ~= true then
    return { state = state, triggers = triggers }
  end

  if upper_reached and previous.upper_triggered ~= true then
    table.insert(triggers, { direction = "upper", threshold = normalized.upper_price })
  end
  if lower_reached and previous.lower_triggered ~= true then
    table.insert(triggers, { direction = "lower", threshold = normalized.lower_price })
  end

  return { state = state, triggers = triggers }
end

-- Samples must carry a finite `at` and a positive `price`; both are coerced to
-- numbers and the result is sorted oldest-first.
function Alerts.valid_samples(samples)
  local entries = {}
  if type(samples) ~= "table" then
    return entries
  end

  for _, sample in ipairs(samples) do
    if type(sample) == "table" then
      local at = to_number(sample.at)
      local price = Alerts.as_positive_number(sample.price)
      if at ~= nil and price ~= nil then
        table.insert(entries, { at = at, price = price })
      end
    end
  end

  table.sort(entries, function(a, b)
    return a.at < b.at
  end)
  return entries
end

-- Returns { state, trigger, change_percent }. `now` is the caller's clock in
-- milliseconds (the service passes noctalia.nowMs(), never os.time()).
function Alerts.evaluate_rapid_move(samples, rule, previous_state, now)
  local normalized = Alerts.normalize_rapid_alert(rule)
  local current_time = to_number(now)
  if current_time == nil then
    current_time = os.time() * 1000
  end
  local previous = is_object(previous_state) and previous_state or {}

  local state = {
    initialized = previous.initialized == true,
    -- Armed unless explicitly disarmed: a missing (first-run) state starts armed.
    armed_rise = previous.armed_rise ~= false,
    armed_fall = previous.armed_fall ~= false,
    last_rise_at = to_number(previous.last_rise_at) or 0,
    last_fall_at = to_number(previous.last_fall_at) or 0,
  }
  local result = { state = state, trigger = nil, change_percent = nil }
  local entries = Alerts.valid_samples(samples)

  if not normalized.enabled or #entries < 2 then
    state.initialized = #entries > 0
    return result
  end

  local cutoff = current_time - normalized.window_minutes * 60 * 1000
  local in_window = {}
  for _, sample in ipairs(entries) do
    if sample.at >= cutoff then
      table.insert(in_window, sample)
    end
  end

  if #in_window < 2 then
    state.initialized = true
    return result
  end

  local baseline = in_window[1]
  local current = in_window[#in_window]
  if baseline.price <= 0 or current.price <= 0 then
    state.initialized = true
    return result
  end

  local change_percent = (current.price - baseline.price) / baseline.price * 100
  result.change_percent = change_percent

  local threshold = normalized.threshold_percent
  local cooldown = normalized.cooldown_minutes * 60 * 1000

  if change_percent >= threshold then
    if state.armed_rise and (state.last_rise_at == 0 or current_time - state.last_rise_at >= cooldown) then
      -- Fires once per move, then stays disarmed while the price keeps rising.
      result.trigger = { direction = "rise", change_percent = change_percent }
      state.last_rise_at = current_time
      state.armed_rise = false
    elseif state.last_rise_at > 0 and current_time - state.last_rise_at < cooldown then
      state.armed_rise = false
    end
  else
    -- Back inside the band: the rule re-arms for the next excursion.
    state.armed_rise = true
  end

  if change_percent <= -threshold then
    if state.armed_fall and (state.last_fall_at == 0 or current_time - state.last_fall_at >= cooldown) then
      result.trigger = { direction = "fall", change_percent = change_percent }
      state.last_fall_at = current_time
      state.armed_fall = false
    elseif state.last_fall_at > 0 and current_time - state.last_fall_at < cooldown then
      state.armed_fall = false
    end
  else
    state.armed_fall = true
  end

  state.initialized = true
  return result
end

-- Drop samples older than the rolling window. A nil `now` yields nothing, which
-- mirrors the NaN comparison in the original (it filtered everything out).
function Alerts.trim_samples(samples, now, window_minutes)
  local now_number = to_number(now)
  if now_number == nil then
    return {}
  end

  local entries = Alerts.valid_samples(samples)
  local minutes = math.max(1, to_number(window_minutes) or 1)
  local cutoff = now_number - minutes * 60 * 1000

  local kept = {}
  for _, sample in ipairs(entries) do
    if sample.at >= cutoff then
      table.insert(kept, sample)
    end
  end
  return kept
end

return Alerts
