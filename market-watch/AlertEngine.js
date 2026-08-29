function asPositiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function clampNumber(value, minimum, maximum, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(minimum, Math.min(maximum, number));
}

function normalizePriceAlert(value) {
  const source = value && typeof value === "object" && !Array.isArray(value) ? value : ({});
  return {
    enabled: source.enabled === true,
    upperPrice: asPositiveNumber(source.upperPrice),
    lowerPrice: asPositiveNumber(source.lowerPrice)
  };
}

function normalizePriceAlerts(value) {
  const result = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return result;

  Object.keys(value).forEach(id => {
    const key = String(id || "").trim();
    if (key !== "") result[key] = normalizePriceAlert(value[id]);
  });
  return result;
}

function isPriceAlertValid(value) {
  const rule = normalizePriceAlert(value);
  return rule.upperPrice === null || rule.lowerPrice === null || rule.lowerPrice < rule.upperPrice;
}

function normalizeRapidAlert(value) {
  const source = value && typeof value === "object" && !Array.isArray(value) ? value : ({});
  const ids = [];
  const seen = {};
  const rawIds = Array.isArray(source.instrumentIds) ? source.instrumentIds : [];
  rawIds.forEach(id => {
    const key = String(id || "").trim();
    if (key !== "" && !seen[key]) {
      seen[key] = true;
      ids.push(key);
    }
  });

  return {
    enabled: source.enabled === true,
    thresholdPercent: clampNumber(source.thresholdPercent, 0.1, 100, 5),
    windowMinutes: Math.round(clampNumber(source.windowMinutes, 1, 1440, 5)),
    cooldownMinutes: Math.round(clampNumber(source.cooldownMinutes, 1, 1440, 30)),
    instrumentIds: ids
  };
}

function isRapidAlertSelected(rule, instrumentId) {
  const normalized = normalizeRapidAlert(rule);
  return normalized.enabled && normalized.instrumentIds.indexOf(String(instrumentId || "")) >= 0;
}

function evaluatePriceAlert(rule, price, previousState) {
  const normalized = normalizePriceAlert(rule);
  const currentPrice = asPositiveNumber(price);
  const previous = previousState && typeof previousState === "object" ? previousState : ({});
  const upperReached = normalized.upperPrice !== null && currentPrice !== null && currentPrice >= normalized.upperPrice;
  const lowerReached = normalized.lowerPrice !== null && currentPrice !== null && currentPrice <= normalized.lowerPrice;
  const state = {
    initialized: currentPrice !== null,
    upperTriggered: upperReached,
    lowerTriggered: lowerReached
  };
  const triggers = [];

  if (!normalized.enabled || currentPrice === null || !isPriceAlertValid(normalized)) return { state: state, triggers: triggers };
  if (!previous.initialized) return { state: state, triggers: triggers };

  if (upperReached && !previous.upperTriggered) {
    triggers.push({ direction: "upper", threshold: normalized.upperPrice });
  }
  if (lowerReached && !previous.lowerTriggered) {
    triggers.push({ direction: "lower", threshold: normalized.lowerPrice });
  }
  return { state: state, triggers: triggers };
}

function validSamples(samples) {
  if (!Array.isArray(samples)) return [];
  return samples
    .filter(sample => sample && Number.isFinite(Number(sample.at)) && asPositiveNumber(sample.price) !== null)
    .map(sample => ({ at: Number(sample.at), price: Number(sample.price) }))
    .sort((a, b) => a.at - b.at);
}

function evaluateRapidMove(samples, rule, previousState, now) {
  const normalized = normalizeRapidAlert(rule);
  const currentTime = Number.isFinite(Number(now)) ? Number(now) : Date.now();
  const previous = previousState && typeof previousState === "object" ? previousState : ({});
  const state = {
    initialized: previous.initialized === true,
    armedRise: previous.armedRise !== false,
    armedFall: previous.armedFall !== false,
    lastRiseAt: Number(previous.lastRiseAt || 0),
    lastFallAt: Number(previous.lastFallAt || 0)
  };
  const result = { state: state, trigger: null, changePercent: null };
  const entries = validSamples(samples);
  if (!normalized.enabled || entries.length < 2) {
    state.initialized = entries.length > 0;
    return result;
  }

  const cutoff = currentTime - normalized.windowMinutes * 60 * 1000;
  const inWindow = entries.filter(sample => sample.at >= cutoff);
  if (inWindow.length < 2) {
    state.initialized = true;
    return result;
  }

  const baseline = inWindow[0];
  const current = inWindow[inWindow.length - 1];
  if (baseline.price <= 0 || current.price <= 0) {
    state.initialized = true;
    return result;
  }

  const changePercent = (current.price - baseline.price) / baseline.price * 100;
  result.changePercent = changePercent;
  const threshold = normalized.thresholdPercent;
  const cooldownMs = normalized.cooldownMinutes * 60 * 1000;

  if (changePercent >= threshold) {
    if (state.armedRise && (state.lastRiseAt === 0 || currentTime - state.lastRiseAt >= cooldownMs)) {
      result.trigger = { direction: "rise", changePercent: changePercent };
      state.lastRiseAt = currentTime;
      state.armedRise = false;
    } else if (state.lastRiseAt > 0 && currentTime - state.lastRiseAt < cooldownMs) {
      state.armedRise = false;
    }
  } else {
    state.armedRise = true;
  }

  if (changePercent <= -threshold) {
    if (state.armedFall && (state.lastFallAt === 0 || currentTime - state.lastFallAt >= cooldownMs)) {
      result.trigger = { direction: "fall", changePercent: changePercent };
      state.lastFallAt = currentTime;
      state.armedFall = false;
    } else if (state.lastFallAt > 0 && currentTime - state.lastFallAt < cooldownMs) {
      state.armedFall = false;
    }
  } else {
    state.armedFall = true;
  }

  state.initialized = true;
  return result;
}

function trimSamples(samples, now, windowMinutes) {
  const entries = validSamples(samples);
  const cutoff = Number(now) - Math.max(1, Number(windowMinutes) || 1) * 60 * 1000;
  return entries.filter(sample => sample.at >= cutoff);
}
