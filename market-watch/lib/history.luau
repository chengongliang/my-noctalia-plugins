--!nonstrict
-- Pure chart math; only real source samples enter the graph or its hover readout.
local History = {}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function candle(point)
  return finite(point.open) and finite(point.high) and finite(point.low) and finite(point.close)
    and point.low > 0 and point.low <= math.min(point.open, point.close)
    and point.high >= math.max(point.open, point.close)
end

function History.state_key(id, timeframe)
  return "market.history:" .. id .. ((timeframe == nil or timeframe == "5m") and "" or ":" .. timeframe)
end

function History.prepare(points, now_ms, interval_ms, chart_type, window_ms)
  local window_start = now_ms - (finite(window_ms) and window_ms > 0 and window_ms or 86400000)
  local interval = finite(interval_ms) and interval_ms > 0 and interval_ms or 300000
  local by_time = {}
  for _, point in ipairs(type(points) == "table" and points or {}) do
    if type(point) == "table" and finite(point.timestamp_ms) and finite(point.price)
      and point.price > 0 and point.timestamp_ms >= window_start and point.timestamp_ms <= now_ms then
      by_time[point.timestamp_ms] = {
        timestamp_ms = point.timestamp_ms, price = point.price, confirmed = point.confirmed,
      }
      if candle(point) then
        local target = by_time[point.timestamp_ms]
        target.open, target.high, target.low, target.close = point.open, point.high, point.low, point.close
      end
    end
  end
  local cleaned = {}
  for _, point in pairs(by_time) do
    cleaned[#cleaned + 1] = point
  end
  table.sort(cleaned, function(a, b)
    return a.timestamp_ms < b.timestamp_ms
  end)

  local candles = {}
  for _, point in ipairs(cleaned) do
    if candle(point) then candles[#candles + 1] = point end
  end
  local use_candles = chart_type == "candle" and #candles > 0
  if use_candles then cleaned = candles end

  local result = {
    points = cleaned, segments = {}, interval_ms = interval,
    window_start = window_start, window_end = now_ms, has_gaps = false,
    chart_type = use_candles and "candle" or "line",
  }
  if #cleaned == 0 then
    return result
  end
  result.first_at = cleaned[1].timestamp_ms
  result.last_at = cleaned[#cleaned].timestamp_ms
  result.low, result.high = cleaned[1].price, cleaned[1].price
  for _, point in ipairs(cleaned) do
    result.low = math.min(result.low, use_candles and point.low or point.price)
    result.high = math.max(result.high, use_candles and point.high or point.price)
  end

  local segment
  for index, point in ipairs(cleaned) do
    -- Long holes are left blank instead of drawing a made-up price path across them.
    if segment == nil or point.timestamp_ms - cleaned[index - 1].timestamp_ms > interval * 1.5 then
      if segment ~= nil then
        result.has_gaps = true
      end
      segment = { points = {}, values = {}, start_at = point.timestamp_ms, end_at = point.timestamp_ms,
        low = result.low, high = result.high }
      result.segments[#result.segments + 1] = segment
    end
    segment.points[#segment.points + 1] = point
    local value = 0.5
    if result.high > result.low then
      value = (point.price - result.low) / (result.high - result.low)
    end
    segment.values[#segment.values + 1] = value
    segment.end_at = point.timestamp_ms
  end
  return result
end

-- Graph starts at input index 2; repeat the first sample so x=0 is the real start.
function History.graph_values(segment)
  local values = { segment.values[1], segment.values[1] }
  for _, value in ipairs(segment.values) do values[#values + 1] = value end
  return values
end

-- Match the host's Hermite curve, independent of the pointer's vertical position.
function History.price_at(segment, norm_x)
  local points = type(segment) == "table" and segment.points or nil
  local x = tonumber(norm_x)
  if type(points) ~= "table" or #points == 0 or not finite(x) then return nil end
  local position = math.max(0, math.min(1, x)) * (#points - 1)
  local left = math.floor(position) + 1
  local a, b = points[left], points[math.min(left + 1, #points)]
  local ratio = position - math.floor(position)
  local previous = points[math.max(1, left - 1)].price
  local following = points[math.min(left + 2, #points)].price
  if left + 2 > #points and #points >= 2 then
    following = points[#points].price + (points[#points].price - points[#points - 1].price) * 0.5
    following = math.max(segment.low, math.min(segment.high, following))
  end
  local m1, m2 = (b.price - previous) * 0.25, (following - a.price) * 0.25
  local t2, t3 = ratio * ratio, ratio * ratio * ratio
  return {
    timestamp_ms = a.timestamp_ms + (b.timestamp_ms - a.timestamp_ms) * ratio,
    price = (2 * t3 - 3 * t2 + 1) * a.price + (t3 - 2 * t2 + ratio) * m1
      + (-2 * t3 + 3 * t2) * b.price + (t3 - t2) * m2,
  }
end

function History.point_at(segment, norm_x)
  local points = type(segment) == "table" and segment.points or nil
  if type(points) ~= "table" or #points == 0 then
    return nil
  end
  local x = tonumber(norm_x)
  if not finite(x) then
    return nil
  end
  x = math.max(0, math.min(1, x))
  local index = math.floor(x * (#points - 1) + 0.5) + 1
  return points[index], index
end

return History
