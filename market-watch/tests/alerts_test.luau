--!nonstrict
-- Alert engine tests - the v4 tests/AlertEngine.test.js assertions.
--
-- Run from the plugin directory:
--   lua5.4 tests/alerts_test.luau
--
-- lib/alerts.luau is host-free and clock-free (the caller passes `now`), so the
-- only stub needed is `noctalia.log`.

local noctalia = {
  log = function(message)
    print(message)
  end,
}

local function script_dir()
  local script = arg and arg[0] or "tests/alerts_test.luau"
  local dir = script:match("^(.*)[/\\][^/\\]*$")
  return dir or "."
end

local dir = script_dir()
local alerts = dofile(dir .. "/../lib/alerts.luau")

local failures = 0

local function check(condition, label)
  if condition then
    return
  end
  failures = failures + 1
  print("FAIL: " .. label)
end

local function check_equal(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print("FAIL: " .. label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
end

-- ── Price thresholds: first sample arms, fresh crossings fire ────────────────

local rule = alerts.normalize_price_alert({ enabled = true, upper_price = "110", lower_price = "90" })
check_equal(rule.upper_price, 110, "string prices are coerced")
check_equal(rule.lower_price, 90, "string prices are coerced")

local checked = alerts.evaluate_price_alert(rule, 100, nil)
check_equal(#checked.triggers, 0, "the first sample never fires")
check_equal(checked.state.initialized, true, "the first sample arms the rule")

-- Starting above the threshold must not fire either: only a crossing does.
local beyond_baseline = alerts.evaluate_price_alert(rule, 120, nil)
check_equal(#beyond_baseline.triggers, 0, "a session starting beyond the bound never fires")

checked = alerts.evaluate_price_alert(rule, 111, checked.state)
check_equal(#checked.triggers, 1, "crossing the upper bound fires")
check_equal(checked.triggers[1].direction, "upper", "the trigger names the upper bound")
check_equal(checked.triggers[1].threshold, 110, "the trigger carries the threshold")

-- Staying beyond the bound must not fire again.
checked = alerts.evaluate_price_alert(rule, 112, checked.state)
check_equal(#checked.triggers, 0, "staying beyond the bound does not re-fire")

-- Coming back inside re-arms the rule.
checked = alerts.evaluate_price_alert(rule, 100, checked.state)
check_equal(#checked.triggers, 0, "returning inside the band does not fire")
check_equal(checked.state.upper_triggered, false, "returning inside re-arms the upper bound")

checked = alerts.evaluate_price_alert(rule, 89, checked.state)
check_equal(#checked.triggers, 1, "crossing the lower bound fires")
check_equal(checked.triggers[1].direction, "lower", "the trigger names the lower bound")

-- ── Normalisation and validation ────────────────────────────────────────────

local malformed = alerts.normalize_price_alert({ enabled = true, upper_price = -1, lower_price = "nope" })
check_equal(malformed.upper_price, nil, "a negative price normalises to nil")
check_equal(malformed.lower_price, nil, "a non-numeric price normalises to nil")
check_equal(alerts.is_price_alert_valid({ upper_price = 90, lower_price = 100 }), false, "an inverted range is invalid")
check_equal(alerts.is_price_alert_valid({ upper_price = 100, lower_price = 90 }), true, "a normal range is valid")
check_equal(alerts.is_price_alert_valid({ upper_price = 100 }), true, "a single bound is valid")

local invalid_range = alerts.evaluate_price_alert({ enabled = true, upper_price = 90, lower_price = 100 }, 95, { initialized = true })
check_equal(#invalid_range.triggers, 0, "an invalid range never fires")
check_equal(invalid_range.state.initialized, true, "an invalid range still stores its state")

local empty_map = alerts.normalize_price_alerts(nil)
check_equal(next(empty_map), nil, "nil price alerts normalise to an empty map")
check_equal(alerts.normalize_price_alerts({ [""] = { enabled = true } })[""], nil, "blank instrument ids are dropped")
check_equal(alerts.normalize_price_alerts({ ["a:b:c"] = { enabled = true, upper_price = 5 } })["a:b:c"].upper_price, 5, "priced rules survive normalisation")

-- ── Rapid-move detector: window, cooldown and arming ────────────────────────

local rapid_rule = alerts.normalize_rapid_alert({
  enabled = true,
  threshold_percent = 5,
  window_minutes = 5,
  cooldown_minutes = 10,
  instrument_ids = { "huobi:spot:BTCUSDT", "huobi:spot:BTCUSDT", "" },
})
check_equal(#rapid_rule.instrument_ids, 1, "instrument ids are trimmed, de-duplicated and dropped when blank")
check_equal(rapid_rule.threshold_percent, 5, "threshold default is preserved")
check_equal(rapid_rule.window_minutes, 5, "window is rounded to whole minutes")
check_equal(rapid_rule.cooldown_minutes, 10, "cooldown is rounded to whole minutes")

check_equal(alerts.is_rapid_alert_selected(rapid_rule, "huobi:spot:BTCUSDT"), true, "the selected instrument is monitored")
check_equal(alerts.is_rapid_alert_selected(rapid_rule, "huobi:spot:ETHUSDT"), false, "other instruments are not monitored")
check_equal(alerts.is_rapid_alert_selected({ enabled = false, instrument_ids = { "x" } }, "x"), false, "a disabled rule selects nothing")

-- A single sample can never move.
local rapid_state = alerts.evaluate_rapid_move({ { at = 0, price = 100 } }, rapid_rule, nil, 300000)
check_equal(rapid_state.trigger, nil, "one sample cannot trigger")

-- +6% inside the window fires a rise.
rapid_state = alerts.evaluate_rapid_move(
  { { at = 0, price = 100 }, { at = 300000, price = 106 } },
  rapid_rule,
  rapid_state.state,
  300000
)
check_equal(rapid_state.trigger ~= nil and rapid_state.trigger.direction, "rise", "a +6% move fires a rise")
check_equal(rapid_state.trigger.change_percent, 6, "the trigger carries the observed change")

-- Still rising, still disarmed: no repeat.
rapid_state = alerts.evaluate_rapid_move(
  { { at = 0, price = 100 }, { at = 300000, price = 106 }, { at = 310000, price = 107 } },
  rapid_rule,
  rapid_state.state,
  310000
)
check_equal(rapid_state.trigger, nil, "a continuing rise does not re-fire")

-- The window rolled forward and only one sample is left in it.
rapid_state = alerts.evaluate_rapid_move(
  { { at = 300000, price = 106 }, { at = 700000, price = 100 } },
  rapid_rule,
  rapid_state.state,
  700000
)
check_equal(rapid_state.trigger, nil, "a move outside the window is ignored")

-- −6% fires a fall (fresh state: the direction is tracked independently).
local fall_state = alerts.evaluate_rapid_move({ { at = 0, price = 100 } }, rapid_rule, nil, 0)
fall_state = alerts.evaluate_rapid_move(
  { { at = 0, price = 100 }, { at = 300000, price = 94 } },
  rapid_rule,
  fall_state.state,
  300000
)
check_equal(fall_state.trigger ~= nil and fall_state.trigger.direction, "fall", "a -6% move fires a fall")

-- Cooldown: the same direction cannot fire again inside cooldown_minutes, and can
-- once the cooldown has elapsed since the previous trigger.
local cooldown_rule = alerts.normalize_rapid_alert({
  enabled = true,
  threshold_percent = 5,
  window_minutes = 5,
  cooldown_minutes = 10,
  instrument_ids = { "x" },
})
local cooldown_state = alerts.evaluate_rapid_move(
  { { at = 0, price = 100 }, { at = 60000, price = 106 } },
  cooldown_rule,
  nil,
  60000
)
check_equal(cooldown_state.trigger ~= nil, true, "the first excursion fires a rise")
check_equal(cooldown_state.state.last_rise_at, 60000, "the trigger time is recorded")

-- A sub-threshold move back inside the band rearms the rise without firing.
cooldown_state = alerts.evaluate_rapid_move(
  { { at = 60000, price = 106 }, { at = 120000, price = 104 } },
  cooldown_rule,
  cooldown_state.state,
  120000
)
check_equal(cooldown_state.trigger, nil, "a sub-threshold move fires nothing")
check_equal(cooldown_state.state.armed_rise, true, "a sub-threshold move rearms the rise")

-- A second +5.8% excursion 2 minutes after the first, well inside the 10 minute
-- cooldown: the rise stays disarmed.
cooldown_state = alerts.evaluate_rapid_move(
  { { at = 120000, price = 104 }, { at = 180000, price = 110 } },
  cooldown_rule,
  cooldown_state.state,
  180000
)
check_equal(cooldown_state.trigger, nil, "the cooldown suppresses a second excursion")
check_equal(cooldown_state.state.armed_rise, false, "a suppressed excursion stays disarmed")

-- Re-arm, then cross again once the cooldown has elapsed (10 minutes after the
-- first trigger at t=60000).
cooldown_state = alerts.evaluate_rapid_move(
  { { at = 180000, price = 110 }, { at = 240000, price = 108 } },
  cooldown_rule,
  cooldown_state.state,
  240000
)
check_equal(cooldown_state.state.armed_rise, true, "a sub-threshold move rearms after a suppression")
cooldown_state = alerts.evaluate_rapid_move(
  { { at = 620000, price = 100 }, { at = 660000, price = 120 } },
  cooldown_rule,
  cooldown_state.state,
  660000
)
check_equal(cooldown_state.trigger ~= nil and cooldown_state.trigger.direction, "rise", "the rule fires again once the cooldown elapsed")

-- ── Sample hygiene ──────────────────────────────────────────────────────────

check_equal(#alerts.trim_samples({ { at = 0, price = 1 }, { at = 1000, price = 2 } }, 61000, 1), 1, "trim_samples drops out-of-window samples")
check_equal(#alerts.trim_samples({ { at = 0, price = 1 } }, nil, 1), 0, "trim_samples without a clock keeps nothing")
check_equal(#alerts.valid_samples({ { at = 0, price = 0 }, { at = "x", price = 1 }, { at = 5, price = "-2" }, { at = 7, price = "3" } }), 1, "valid_samples drops unparsable samples")
check_equal(alerts.valid_samples({ { at = 20, price = 2 }, { at = 10, price = 1 } })[1].at, 10, "valid_samples sorts oldest first")
check_equal(alerts.normalize_rapid_alert({}).threshold_percent, 5, "the rapid threshold defaults to 5%")
check_equal(alerts.normalize_rapid_alert({ threshold_percent = 0.05 }).threshold_percent, 0.1, "the rapid threshold is clamped from below")
check_equal(alerts.normalize_rapid_alert({ threshold_percent = 500 }).threshold_percent, 100, "the rapid threshold is clamped from above")
check_equal(alerts.normalize_rapid_alert({ window_minutes = 0 }).window_minutes, 1, "the window is clamped from below")
check_equal(alerts.normalize_rapid_alert({ window_minutes = 99999 }).window_minutes, 1440, "the window is clamped from above")
check_equal(alerts.normalize_rapid_alert({ cooldown_minutes = 0 }).cooldown_minutes, 1, "the cooldown is clamped from below")
check_equal(alerts.normalize_rapid_alert({ cooldown_minutes = 99999 }).cooldown_minutes, 1440, "the cooldown is clamped from above")
check_equal(alerts.normalize_rapid_alert({ threshold_percent = "2.5" }).threshold_percent, 2.5, "a fractional threshold survives")
check_equal(alerts.normalize_rapid_alert({ enabled = "yes" }).enabled, false, "only a real boolean enables the rule")
check_equal(alerts.normalize_price_alert({ enabled = 1 }).enabled, false, "only a real boolean enables a price alert")

if failures > 0 then
  print("alerts: " .. failures .. " check(s) failed")
  os.exit(1)
end

print("alerts: price-crossing, cooldown, rolling-window, normalisation and clamps passed")
