import test from "node:test";
import assert from "node:assert/strict";
import {
  formatValue,
  rangeFor,
  chartSegments,
  freshness,
  comparison,
  comparisonText,
  METRICS,
} from "../collector/web/model.mjs";
test("missing measurements stay missing while zero steps remain a real zero", () => {
  assert.equal(formatValue(null, "hr_bpm"), "—");
  assert.equal(formatValue(0, "quarter_hour_steps"), "0");
  assert.equal(formatValue(36, "skin_temp_c", "F"), "96.8");
  assert.equal(formatValue(1, "charging"), "Charging");
  assert.match(METRICS.quarter_hour_steps.description, /not a daily total/);
});
test("date ranges have local midnight boundaries and stop at now for today", () => {
  const now = new Date(2026, 9, 9, 14).getTime() / 1000;
  const day = rangeFor("day", "2026-10-09", now);
  assert.equal(new Date(day.start * 1000).getHours(), 0);
  assert.equal(day.end, now + 1);
  const week = rangeFor("week", "2026-10-08", now);
  assert.equal(new Date(week.start * 1000).getDate(), 2);
  assert.equal(new Date(week.end * 1000).getDate(), 9);
});
test("charts break at missing buckets instead of drawing continuous readings", () => {
  const points = [
    { timestamp: 0, value: 60 },
    { timestamp: 900, value: 65 },
    { timestamp: 7200, value: 70 },
  ];
  assert.equal(chartSegments(points, 900).length, 2);
});
test("freshness and period comparisons do not manufacture a baseline", () => {
  assert.equal(freshness(null, "hr_bpm", 100000), "unavailable");
  assert.equal(freshness(1, "hr_bpm", 100000), "stale");
  assert.equal(freshness(99999, "hr_bpm", 100000), "current");
  assert.equal(
    comparison({ count: 2, mean: 60, previous: { count: 20, mean: 50 } }),
    null,
  );
  assert.equal(
    comparison({ count: 4, mean: 60, previous: { count: 4, mean: 50 } })
      .percent,
    20,
  );
});

test("zero baselines and temperature changes use absolute differences", () => {
  assert.equal(
    comparisonText({ difference: 10, percent: null }, "quarter_hour_steps"),
    "↑ 10 steps versus previous period",
  );
  assert.equal(
    comparisonText({ difference: 1, percent: 3 }, "skin_temp_c", "F"),
    "↑ 1.8 °F versus previous period",
  );
});
