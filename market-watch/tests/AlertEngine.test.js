const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const sourcePath = path.join(__dirname, "..", "AlertEngine.js");
const source = fs.readFileSync(sourcePath, "utf8") + `
this.api = { normalizePriceAlert, normalizePriceAlerts, isPriceAlertValid, normalizeRapidAlert, isRapidAlertSelected, evaluatePriceAlert, evaluateRapidMove, trimSamples };
`;
const context = {};
vm.runInNewContext(source, context, { filename: sourcePath });
const api = context.api;

const rule = api.normalizePriceAlert({ enabled: true, upperPrice: "110", lowerPrice: "90" });
let checked = api.evaluatePriceAlert(rule, 100, null);
assert.deepStrictEqual(JSON.parse(JSON.stringify(checked.triggers)), []);
assert.strictEqual(checked.state.initialized, true);
const beyondBaseline = api.evaluatePriceAlert(rule, 120, null);
assert.deepStrictEqual(JSON.parse(JSON.stringify(beyondBaseline.triggers)), []);

checked = api.evaluatePriceAlert(rule, 111, checked.state);
assert.strictEqual(checked.triggers.length, 1);
assert.strictEqual(checked.triggers[0].direction, "upper");

checked = api.evaluatePriceAlert(rule, 112, checked.state);
assert.deepStrictEqual(JSON.parse(JSON.stringify(checked.triggers)), []);
checked = api.evaluatePriceAlert(rule, 100, checked.state);
assert.deepStrictEqual(JSON.parse(JSON.stringify(checked.triggers)), []);
checked = api.evaluatePriceAlert(rule, 89, checked.state);
assert.strictEqual(checked.triggers[0].direction, "lower");

const rapidRule = api.normalizeRapidAlert({
  enabled: true,
  thresholdPercent: 5,
  windowMinutes: 5,
  cooldownMinutes: 10,
  instrumentIds: ["huobi:spot:BTCUSDT"]
});
let rapidState = api.evaluateRapidMove([{ at: 0, price: 100 }], rapidRule, null, 300000);
assert.strictEqual(api.isRapidAlertSelected(rapidRule, "huobi:spot:BTCUSDT"), true);
assert.strictEqual(api.isRapidAlertSelected(rapidRule, "huobi:spot:ETHUSDT"), false);
assert.strictEqual(rapidState.trigger, null);
rapidState = api.evaluateRapidMove([{ at: 0, price: 100 }, { at: 300000, price: 106 }], rapidRule, rapidState.state, 300000);
assert.strictEqual(rapidState.trigger.direction, "rise");
rapidState = api.evaluateRapidMove([
  { at: 0, price: 100 },
  { at: 300000, price: 106 },
  { at: 310000, price: 107 }
], rapidRule, rapidState.state, 310000);
assert.strictEqual(rapidState.trigger, null);
rapidState = api.evaluateRapidMove([
  { at: 300000, price: 106 },
  { at: 700000, price: 100 }
], rapidRule, rapidState.state, 700000);
assert.strictEqual(rapidState.trigger, null);

let fallState = api.evaluateRapidMove([{ at: 0, price: 100 }], rapidRule, null, 0);
fallState = api.evaluateRapidMove([{ at: 0, price: 100 }, { at: 300000, price: 94 }], rapidRule, fallState.state, 300000);
assert.strictEqual(fallState.trigger.direction, "fall");

const malformed = api.normalizePriceAlert({ enabled: true, upperPrice: -1, lowerPrice: "nope" });
assert.strictEqual(malformed.upperPrice, null);
assert.strictEqual(malformed.lowerPrice, null);
assert.strictEqual(api.isPriceAlertValid({ upperPrice: 90, lowerPrice: 100 }), false);
const invalidRange = api.evaluatePriceAlert({ enabled: true, upperPrice: 90, lowerPrice: 100 }, 95, { initialized: true });
assert.deepStrictEqual(JSON.parse(JSON.stringify(invalidRange.triggers)), []);

assert.strictEqual(api.trimSamples([{ at: 0, price: 1 }, { at: 1000, price: 2 }], 61000, 1).length, 1);
assert.strictEqual(api.normalizeRapidAlert({}).thresholdPercent, 5);
assert.deepStrictEqual(JSON.parse(JSON.stringify(api.normalizePriceAlerts(null))), {});
console.log("AlertEngine crossing, cooldown, normalization, and rolling-window checks passed");
