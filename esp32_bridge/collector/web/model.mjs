export const METRICS = {
  hr_bpm: {
    label: "Heart rate",
    unit: "bpm",
    color: "#ce4e42",
    digits: 0,
    fresh: 24,
    description: "Heart rate from timestamped ring history.",
  },
  hrv_rmssd_ms: {
    label: "Heart rate variability",
    short: "HRV",
    unit: "ms",
    color: "#875839",
    digits: 0,
    fresh: 36,
    description:
      "Sleep-context RMSSD. This is not Apple Health SDNN or a recovery score.",
  },
  spo2_pct: {
    label: "Blood oxygen",
    unit: "%",
    color: "#3e79a7",
    digits: 0,
    fresh: 36,
    description:
      "SpO₂ from supported sleep-context epochs, not a continuous oxygen trace.",
  },
  respiratory_rate: {
    label: "Respiratory rate",
    unit: "breaths/min",
    color: "#47846f",
    digits: 1,
    fresh: 36,
    description: "Sleep-context respiratory observations from ring history.",
  },
  skin_temp_c: {
    label: "Skin temperature",
    unit: "°C",
    color: "#bd762f",
    digits: 1,
    fresh: 24,
    description:
      "Live skin temperature at sync. This is not core body temperature or historical sleep temperature.",
  },
  quarter_hour_steps: {
    label: "Step bucket",
    unit: "steps",
    color: "#647848",
    digits: 0,
    fresh: 24,
    description: "Current quarter-hour step bucket at sync, not a daily total.",
  },
  battery_pct: {
    label: "Ring battery",
    unit: "%",
    color: "#657b82",
    digits: 0,
    fresh: 24,
    description: "Battery level at the latest live status observation.",
  },
  case_battery_pct: {
    label: "Case battery",
    unit: "%",
    color: "#657b82",
    digits: 0,
    fresh: 24,
    description:
      "Case battery when reported by the ring. Missing reports stay unavailable.",
  },
  battery_mv: {
    label: "Battery voltage",
    unit: "mV",
    color: "#657b82",
    digits: 0,
    fresh: 24,
    description: "Live ring battery voltage, retained at its observation time.",
  },
  charging: {
    label: "Charging state",
    unit: "",
    color: "#657b82",
    digits: 0,
    fresh: 24,
    description: "Charging state at the latest live status observation.",
  },
};
export function formatValue(value, metric, temp = "C") {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  if (metric === "charging")
    return Number(value) === 1 ? "Charging" : "Not charging";
  const info = METRICS[metric];
  const converted =
    metric === "skin_temp_c" && temp === "F"
      ? (Number(value) * 9) / 5 + 32
      : Number(value);
  return converted.toLocaleString(undefined, {
    minimumFractionDigits: info.digits,
    maximumFractionDigits: info.digits,
  });
}
export function rangeFor(preset, anchor, now = Date.now() / 1000) {
  const [year, month, day] = anchor.split("-").map(Number);
  const end = new Date(year, month - 1, day + 1);
  const start = new Date(year, month - 1, day);
  start.setDate(
    start.getDate() -
      ({ day: 1, week: 7, month: 30, year: 365 }[preset] || 1) +
      1,
  );
  return {
    start: Math.floor(start.getTime() / 1000),
    end: Math.floor(Math.min(end.getTime() / 1000, now + 1)),
  };
}
export function chartSegments(points, bucket) {
  const segments = [];
  for (const point of points) {
    const last = segments.at(-1);
    if (!last || point.timestamp - last.at(-1).timestamp > bucket * 1.7)
      segments.push([point]);
    else last.push(point);
  }
  return segments;
}
export function freshness(stamp, metric, now = Date.now() / 1000) {
  if (!stamp) return "unavailable";
  return now - stamp > METRICS[metric].fresh * 3600 ? "stale" : "current";
}
export function comparison(metric) {
  if (
    !metric ||
    metric.count < 3 ||
    !metric.previous ||
    metric.previous.count < 3 ||
    metric.previous.mean == null
  )
    return null;
  const difference = metric.mean - metric.previous.mean;
  return {
    difference,
    percent: metric.previous.mean
      ? (difference / metric.previous.mean) * 100
      : null,
  };
}

export function comparisonText(change, metric, temp = "C") {
  if (!change) return "More observations needed for a comparison";
  const arrow = change.difference > 0 ? "↑" : change.difference < 0 ? "↓" : "→";
  const absolute = metric === "skin_temp_c" || change.percent == null;
  const amount = Math.abs(
    absolute
      ? change.difference * (metric === "skin_temp_c" && temp === "F" ? 1.8 : 1)
      : change.percent,
  );
  const unit = absolute
    ? metric === "skin_temp_c" && temp === "F"
      ? "°F"
      : METRICS[metric].unit
    : "%";
  return `${arrow} ${amount.toFixed(absolute ? METRICS[metric].digits : 1)}${absolute ? " " : ""}${unit} versus previous period`;
}

export function nearestPoint(points, timestamp) {
  if (!points.length) return -1;
  let best = 0;
  for (let n = 1; n < points.length; n++)
    if (
      Math.abs(points[n].timestamp - timestamp) <
      Math.abs(points[best].timestamp - timestamp)
    )
      best = n;
  return best;
}

export function chargingSummary(metric) {
  if (!metric?.count) return "No charging states recorded.";
  const charging = Math.round(metric.mean * metric.count);
  const state =
    metric.min !== metric.max
      ? "Both states"
      : metric.max === 1
        ? "Charging"
        : "Not charging";
  return `${charging} of ${metric.count} recorded states charging (${Math.round(metric.mean * 100)}%). ${state} observed.`;
}
