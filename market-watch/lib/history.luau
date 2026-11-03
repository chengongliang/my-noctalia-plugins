--!nonstrict
-- Pure chart math; only real source samples enter the graph or its hover readout.
local History = {}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function History.prepare(points, now_ms, interval_ms)
  local window_start = now_ms - 86400000
  local interval = finite(interval_ms) and interval_ms > 0 and interval_ms or 300000
  local by_time = {}
  for _, point in ipairs(type(points) == "table" and points or {}) do
    if type(point) == "table" and finite(point.timestamp_ms) and finite(point.price)
      and point.price > 0 and point.timestamp_ms >= window_start and point.timestamp_ms <= now_ms then
      by_time[point.timestamp_ms] = {
        timestamp_ms = point.timestamp_ms, price = point.price, confirmed = point.confirmed,
      }
    end
  end
  local cleaned = {}
  for _, point in pairs(by_time) do
    cleaned[#cleaned + 1] = point
  end
  table.sort(cleaned, function(a, b)
    return a.timestamp_ms < b.timestamp_ms
  end)

  local result = {
    points = cleaned, segments = {}, interval_ms = interval,
    window_start = window_start, window_end = now_ms, has_gaps = false,
  }
  if #cleaned == 0 then
    return result
  end
  result.first_at = cleaned[1].timestamp_ms
  result.last_at = cleaned[#cleaned].timestamp_ms
  result.low, result.high = cleaned[1].price, cleaned[1].price
  for _, point in ipairs(cleaned) do
    result.low = math.min(result.low, point.price)
    result.high = math.max(result.high, point.price)
  end

  local segment
  for index, point in ipairs(cleaned) do
    -- Long holes are left blank instead of drawing a made-up price path across them.
    if segment == nil or point.timestamp_ms - cleaned[index - 1].timestamp_ms > interval * 1.5 then
      if segment ~= nil then
        result.has_gaps = true
      end
      segment = { points = {}, values = {}, start_at = point.timestamp_ms, end_at = point.timestamp_ms }
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
