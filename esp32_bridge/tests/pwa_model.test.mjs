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

test("setup config rejects unsafe inputs and escapes C++ strings", async () => {
  const { buildConfig } = await import("../collector/web/setup.mjs");
  const input = {
    ssid: 'home "wifi"',
    password: "safe\\password",
    collector: "http://192.168.1.20:8765",
    token: "a".repeat(32),
    ringName: "RingConn Gen2-1234",
    mac: "",
    timezone: "EST5EDT,M3.2.0,M11.1.0",
    start: 9,
    end: 22,
    interval: 8,
    board: "esp32dev",
  };
  const config = buildConfig(input);
  assert.ok(config.includes('#define WIFI_SSID "home \\"wifi\\""'));
  assert.ok(config.includes('#define WIFI_PASSWORD "safe\\\\password"'));
  assert.throws(
    () => buildConfig({ ...input, ringName: "RingConn" }),
    /exact/i,
  );
  assert.throws(
    () => buildConfig({ ...input, collector: "https://example.com" }),
    /HTTP/i,
  );
  assert.throws(() => buildConfig({ ...input, token: "CHANGE_ME" }), /token/i);
  assert.throws(() => buildConfig({ ...input, mac: "not-a-mac" }), /MAC/i);
  assert.throws(
    () => buildConfig({ ...input, start: 22, end: 9 }),
    /schedule/i,
  );
});
test("chart inspection selects nearest observed bucket without inventing points", async () => {
  const { nearestPoint } = await import("../collector/web/model.mjs");
  const points = [
    { timestamp: 100, value: 60 },
    { timestamp: 200, value: 70 },
  ];
  assert.equal(nearestPoint(points, 160), 1);
  assert.equal(nearestPoint(points, 90), 0);
  assert.equal(nearestPoint([], 90), -1);
});
test("setup rejects control bytes and placeholder ring identifiers", async () => {
  const { buildConfig } = await import("../collector/web/setup.mjs");
  const input = {
    ssid: "home",
    password: "password",
    collector: "http://192.168.1.20:8765",
    token: "a".repeat(32),
    ringName: "RingConn Gen2-1234",
    mac: "",
    timezone: "UTC0",
    start: 0,
    end: 24,
    interval: 8,
    board: "esp32dev",
  };
  assert.throws(
    () => buildConfig({ ...input, ssid: "home\u0000ignored" }),
    /Wi-Fi/,
  );
  assert.throws(
    () => buildConfig({ ...input, ringName: "RingConn Gen2-XXXX" }),
    /exact/,
  );
  assert.throws(
    () => buildConfig({ ...input, timezone: "America/New_York" }),
    /timezone/i,
  );
});
test("setup rejects unsupported collector URL prefixes", async () => {
  const { buildConfig } = await import("../collector/web/setup.mjs");
  assert.throws(
    () =>
      buildConfig({
        ssid: "home",
        password: "password",
        collector: "http://192.168.1.20:8765/prefix",
        token: "a".repeat(32),
        ringName: "RingConn Gen2-1234",
        mac: "",
        timezone: "UTC0",
        start: 0,
        end: 24,
        interval: 8,
        board: "esp32dev",
      }),
    /root|path/i,
  );
});
test("charging aggregates count states without inventing duration", async () => {
  const { chargingSummary } = await import("../collector/web/model.mjs");
  assert.equal(
    chargingSummary({ mean: 0.5, count: 2, min: 0, max: 1 }),
    "1 of 2 recorded states charging (50%). Both states observed.",
  );
  assert.equal(
    chargingSummary({ mean: 0, count: 2, min: 0, max: 0 }),
    "0 of 2 recorded states charging (0%). Not charging observed.",
  );
});
test("an old asynchronous session cleanup cannot hide a newer signed-in view", async () => {
  const { clearExpiredSession } = await import(
    "../collector/web/session-view.mjs"
  );
  let sequence = 1,
    hidden = false,
    release;
  const cleanup = new Promise((resolve) => (release = resolve));
  const operation = clearExpiredSession(
    1,
    () => sequence,
    () => cleanup,
    () => (hidden = true),
  );
  sequence = 2;
  release();
  await operation;
  assert.equal(hidden, false);
  await clearExpiredSession(
    2,
    () => sequence,
    async () => {},
    () => (hidden = true),
  );
  assert.equal(hidden, true);
});
