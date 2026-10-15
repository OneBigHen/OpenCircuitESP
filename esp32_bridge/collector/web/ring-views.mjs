import { METRICS, formatValue, chargingSummary } from "./model.mjs";
export const html = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const when = (value) =>
  value ? new Date(value * 1000).toLocaleString() : "Not recorded";
const unit = (name, temp) =>
  name === "skin_temp_c" && temp === "F" ? "°F" : METRICS[name].unit;
export const DEFAULT_FAVORITES = [
  "hrv_rmssd_ms",
  "spo2_pct",
  "respiratory_rate",
  "skin_temp_c",
  "quarter_hour_steps",
  "battery_pct",
];
export function favoriteSettings(favorites) {
  return `<div class="settings-section"><h2>Your summary favorites</h2><p>Choose which observations appear on your summary. This only saves metric names.</p><div class="favorite-list">${Object.entries(
    METRICS,
  )
    .map(
      ([name, info]) =>
        `<label><input type="checkbox" data-favorite="${name}" ${favorites.includes(name) ? "checked" : ""}>${info.label}</label>`,
    )
    .join("")}</div></div>`;
}
export function dailyView(state, temp) {
  const data = state.days;
  if (!state.device)
    return '<div class="info-band"><h3>Your daily journal starts with your first sync.</h3><p>Connect your ring using the Connection tab. Observed measurements will appear by calendar day.</p></div>';
  if (!data)
    return `<div class="info-band"><h3>${state.extraError ? "Daily observations unavailable" : state.offline ? "Daily details were not saved" : "Opening daily observations…"}</h3><p>${state.extraError ? html(state.extraError) : state.offline ? "Reconnect to load this view." : "Grouping your actual readings by local date."}</p></div>`;
  const recorded = data.days.filter(
    (day) => Object.keys(day.metrics).length,
  ).length;
  return `<div class="info-band"><h3>${recorded} ${recorded === 1 ? "day" : "days"} with observations</h3><p>${data.days.length} calendar days in ${html(data.timezone)}. Blank days have no stored measurements. Counts and observed time spans describe the data available, not how long you wore the ring.</p></div><div class="daily-list">${data.days
    .slice()
    .reverse()
    .slice(0, state.dailyLimit || 30)
    .map(
      (day) =>
        `<article class="day-card"><div class="section-heading"><h2>${html(new Date(day.date + "T12:00:00").toLocaleDateString(undefined, { weekday: "short", month: "long", day: "numeric" }))}</h2><button class="quiet" data-open-day="${day.date}">Open day</button></div>${
          Object.keys(day.metrics).length
            ? `<div class="day-metrics">${Object.entries(day.metrics)
                .sort(
                  ([a], [b]) =>
                    Object.keys(METRICS).indexOf(a) -
                    Object.keys(METRICS).indexOf(b),
                )
                .filter(([name]) => METRICS[name])
                .map(
                  ([name, metric]) =>
                    `<div><h3>${METRICS[name].label}</h3><span class="source-label">${name === "charging" ? "" : "Average observation"}</span><strong>${name === "charging" ? html(chargingSummary(metric)) : formatValue(metric.mean, name, temp) + " <small>" + unit(name, temp) + "</small>"}</strong><p>${metric.count.toLocaleString()} readings · ${html(when(metric.first_at))} – ${html(when(metric.last_at))}</p>${name === "charging" ? "" : `<p>Low ${formatValue(metric.min, name, temp)} · High ${formatValue(metric.max, name, temp)}</p>`}<span class="source-label">${Object.entries(
                      metric.sources,
                    )
                      .map(
                        ([source, count]) =>
                          `${source === "history" ? "Ring history" : "Live sync status"}: ${count}`,
                      )
                      .join(" · ")}</span></div>`,
                )
                .join("")}</div>`
            : '<p class="muted">No observations recorded this day.</p>'
        }</article>`,
    )
    .join(
      "",
    )}</div>${data.days.length > (state.dailyLimit || 30) ? '<button class="quiet" id="more-days">Show earlier days</button>' : ""}<p class="small">Showing ${Math.min(data.days.length, state.dailyLimit || 30)} of ${data.days.length} calendar days.</p>`;
}
export function connectionView(state) {
  const data = state.diagnostics,
    device = state.status?.devices[state.device];
  const synced = Boolean(device?.last_complete_sync);
  const checklist = [
    ["Collector reachable", !state.offline],
    ["Ring frames uploaded", Boolean(device?.frame_count)],
    ["Both history channels completed", synced],
    ["Decoded measurements available", Boolean(data?.archive.metrics)],
  ];
  return `<div class="connection-layout"><div><div class="info-band"><h3>Ready for your first ring sync</h3><p>This bridge targets RingConn Gen 2. Your AITRIP 30-pin ESP-WROOM-32 uses the <strong>esp32dev</strong> firmware target. Keep the ring nearby and temporarily pause the official app's Bluetooth connection for the first test.</p><a class="text-link" href="#setup">Prepare firmware configuration →</a></div><ol class="sync-checklist">${checklist.map(([label, done]) => `<li><span class="check-state ${done ? "done" : ""}">${done ? "✓" : "○"}</span><div><strong>${label}</strong><p>${done ? "Persisted evidence available" : "Waiting for evidence"}</p></div></li>`).join("")}</ol><div class="info-band"><h3>What a complete sync means</h3><p>The collector must persist a history end marker or explicit empty acknowledgement for both channels from the same attempt. An upload alone is not completion. These are archived observations; the collector cannot prove current Wi-Fi or Bluetooth liveness.</p></div></div><div>${
    data
      ? `<div class="archive-card"><h2>Your archive</h2><div class="archive-counts"><div><strong>${data.archive.frames.toLocaleString()}</strong><span>frames</span></div><div><strong>${data.archive.epochs.toLocaleString()}</strong><span>epochs</span></div><div><strong>${data.archive.metrics.toLocaleString()}</strong><span>measurements</span></div></div><button class="quiet" id="support-export">Export sync diagnostics</button><p class="small">Counts and timestamps only. No values, raw frames, access key or full ring identifier.</p></div><div class="channel-grid">${Object.entries(
          data.channels,
        )
          .map(
            ([channel, info]) =>
              `<article class="archive-card"><h3>${channel === "0" ? "Sleep-context" : "All-day"} channel · 0x0${channel}</h3><p>${info.pages} archived pages · ${info.empty_acks} empty acknowledgements</p><p>Last termination: ${html(when(info.last_end_seen))}</p></article>`,
          )
          .join(
            "",
          )}</div><div class="archive-card"><h2>Measurement coverage</h2>${
          Object.entries(data.metrics)
            .sort(
              ([a], [b]) =>
                Object.keys(METRICS).indexOf(a) -
                Object.keys(METRICS).indexOf(b),
            )
            .filter(([name]) => METRICS[name])
            .map(
              ([name, info]) =>
                `<div class="coverage-row"><strong>${METRICS[name].label}</strong><span>${info.count.toLocaleString()} readings</span><small>${html(when(info.first_at))} → ${html(when(info.last_at))}</small></div>`,
            )
            .join("") ||
          "<p>No decoded measurements yet. A successful empty-history sync can still contain no measurements.</p>"
        }</div><div class="archive-card"><h2>Recent complete syncs</h2>${data.syncs.map((sync) => `<p>${html(when(sync.completed))} · both channels persisted</p>`).join("") || "<p>No complete sync recorded yet.</p>"}<h3>Recent uploads</h3>${data.uploads.map((upload) => `<p>${html(when(upload.committed))} · ${upload.received_frames} received frames</p>`).join("") || "<p>No uploads recorded.</p>"}</div>`
      : `<div class="archive-card"><h2>Waiting for ring data</h2><p>${state.extraError ? html(state.extraError) : state.device ? "Opening archived sync evidence…" : "Your ring will appear after its first frame upload. Collector availability does not prove ring discovery or authentication."}</p></div>`
  }</div></div>`;
}
export function setupView() {
  return `<div class="info-band"><h3>Prepare your ESP32</h3><p>Generate a local <strong>secrets.h</strong> file, then build and flash over USB using PlatformIO. This form sends no credentials to the server and saves none in browser storage. The downloaded file contains secrets; keep it out of source control.</p></div><form id="setup-form" class="setup-form" autocomplete="off"><div class="setup-grid"><label>ESP32 board<select name="board"><option value="esp32dev">AITRIP / ESP-WROOM-32 · esp32dev</option><option value="esp32c6">ESP32-C6 DevKitC-1 · esp32c6</option></select></label><label>Wi-Fi name<input name="ssid" required maxlength="32" autocomplete="off"></label><label>Wi-Fi password<input name="password" type="password" autocomplete="new-password"><small>Leave empty only for an open network.</small></label><label>Collector LAN URL<input name="collector" type="url" required placeholder="http://192.168.1.20:8765"></label><label>Collector ingest token<input name="token" type="password" required minlength="20" autocomplete="new-password"><small>Use RING_TOKEN, not a read-only viewing key.</small></label><label>Exact ring advertisement name<input name="ringName" required placeholder="RingConn Gen2-XXXX"><small>Read Nearby BLE in the USB serial monitor; generic RingConn is not sufficient.</small></label><label>Optional System ID MAC<input name="mac" placeholder="AA:BB:CC:DD:EE:FF"><small>System ID may differ from the advertised BLE address.</small></label><label>Firmware timezone<select name="timezone"><option value="EST5EDT,M3.2.0,M11.1.0">US Eastern</option><option value="CST6CDT,M3.2.0,M11.1.0">US Central</option><option value="MST7MDT,M3.2.0,M11.1.0">US Mountain</option><option value="PST8PDT,M3.2.0,M11.1.0">US Pacific</option><option value="MST7">US Arizona</option><option value="UTC0">UTC</option></select></label><label>Sync window starts<input name="start" type="number" min="0" max="23" value="9" required></label><label>Sync window ends<input name="end" type="number" min="1" max="24" value="22" required></label><label>Hours between completed syncs<input name="interval" type="number" min="1" max="24" value="8" required></label></div><button type="submit" class="primary">Download local secrets.h</button><p id="setup-result" role="status"></p></form><div class="info-band"><h3>Flash and verify</h3><ol class="setup-steps"><li>Put the downloaded file in <code>esp32_bridge/firmware/include/secrets.h</code>.</li><li>From the repository, run <code>pio run -d esp32_bridge/firmware -e esp32dev -t upload</code> for your WROOM board.</li><li>Run <code>pio device monitor -b 115200</code>. Confirm correct discovery, authentication, both history channels and committed upload.</li><li>Return to <a href="#connection">Connection</a> and compare matching measurement times with the official app. Preserve the official app until this A/B test passes.</li></ol><p>Changing settings requires a new USB flash. No OTA slot exists. If the serial scan is needed first, use the repository's placeholder config for discovery, then generate this exact configuration.</p></div>`;
}
export function supportReport(state) {
  return {
    format: "OpenCircuit sync diagnostics v1",
    exported_at: new Date().toISOString(),
    ring_suffix: state.device.slice(-5),
    evidence: state.diagnostics,
  };
}
