import {
  METRICS,
  formatValue,
  rangeFor,
  chartSegments,
  freshness,
  comparison,
  comparisonText,
} from "./model.mjs";
const $ = (selector) => document.querySelector(selector);
const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ],
  );
const localDate = (date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const when = (stamp, options = {}) =>
  stamp
    ? new Date(stamp * 1000).toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
        ...options,
      })
    : "No reading in this range";
let prefs;
try {
  prefs = JSON.parse(localStorage.getItem("oc-preferences") || "{}");
} catch {
  prefs = {};
}
const state = {
  status: null,
  overview: null,
  device: "",
  preset: "day",
  anchor: localDate(new Date()),
  offline: false,
  savedAt: null,
  sequence: 0,
  sampleRequest: 0,
  samples: [],
  nextBefore: null,
  install: null,
};
const savePrefs = () => {
  try {
    localStorage.setItem("oc-preferences", JSON.stringify(prefs));
  } catch {
    notice("This browser cannot save preferences.");
  }
};
function applyTheme() {
  document.documentElement.dataset.theme = prefs.theme || "auto";
}
applyTheme();
async function api(path, body) {
  const sequence = state.sequence;
  const response = await fetch(path, {
    cache: "no-store",
    credentials: "same-origin",
    ...(body !== undefined
      ? {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-OpenCircuit-UI": "1",
          },
          body: JSON.stringify(body),
        }
      : {}),
  });
  if (!response.ok) {
    const error = new Error(
      response.status === 401
        ? "Your session has ended. Sign in again."
        : response.status === 429
          ? "Too many sign-in attempts. Wait a minute and try again."
          : `The collector could not complete this request (${response.status}).`,
    );
    error.status = response.status;
    if (
      response.status === 401 &&
      path !== "/auth/login" &&
      sequence === state.sequence
    ) {
      await snapshotStore("clear").catch(() => {});
      showLogin(error.message);
    }
    throw error;
  }
  return response.json();
}
function notice(message, error = false) {
  $("#notice").textContent = message;
  $("#notice").hidden = !message;
  $("#notice").classList.toggle("error", error);
}
async function snapshotStore(mode, value) {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open("opencircuit-private-snapshot", 1);
    open.onupgradeneeded = () => open.result.createObjectStore("snapshots");
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const db = open.result;
      const tx = db.transaction(
        "snapshots",
        mode === "get" ? "readonly" : "readwrite",
      );
      const store = tx.objectStore("snapshots");
      const request =
        mode === "get"
          ? store.get("latest")
          : mode === "put"
            ? store.put(value, "latest")
            : store.clear();
      tx.oncomplete = () => {
        resolve(request.result);
        db.close();
      };
      tx.onerror = () => {
        reject(tx.error);
        db.close();
      };
    };
  });
}
function showLogin(message = "") {
  ++state.sequence;
  state.status = state.overview = null;
  state.samples = [];
  state.device = "";
  state.nextBefore = null;
  $("#view").replaceChildren();
  $("#device").replaceChildren();
  $("#login").hidden = false;
  $("#app").hidden = true;
  $("#connection").textContent = "Private journal";
  $("#login-error").textContent = message;
}
function range() {
  if (state.offline && state.overview) return state.overview.range;
  if (state.preset === "custom") {
    const start = new Date($("#custom-start").value + "T00:00:00");
    const end = new Date($("#custom-end").value + "T00:00:00");
    end.setDate(end.getDate() + 1);
    return {
      start: Math.floor(start.getTime() / 1000),
      end: Math.floor(Math.min(end.getTime() / 1000, Date.now() / 1000 + 1)),
    };
  }
  return rangeFor(state.preset, state.anchor);
}
function unit(name) {
  return name === "skin_temp_c" && prefs.temp === "F"
    ? "°F"
    : METRICS[name].unit;
}
function value(v, name) {
  return escape(formatValue(v, name, prefs.temp));
}
function measurementLabel(name) {
  return [
    "skin_temp_c",
    "quarter_hour_steps",
    "battery_pct",
    "case_battery_pct",
    "battery_mv",
    "charging",
  ].includes(name)
    ? "Live status at sync"
    : "Ring history";
}
function badge(name) {
  const stamp = state.overview?.metrics[name]?.latest?.timestamp;
  const status = freshness(stamp, name);
  return `<span class="badge ${status}">${status === "current" ? "Latest available" : status === "stale" ? "Older observation" : "No reading in this range"}</span>`;
}
function chart(name, small = false) {
  const metric = state.overview?.metrics[name];
  if (!metric?.series.length)
    return small
      ? ""
      : `<div class="chart-empty">No readings in this date range</div>`;
  const data = metric.series;
  const width = 640,
    height = small ? 80 : 180,
    pad = small ? 4 : 30;
  const low = metric.min,
    high = metric.max,
    span = Math.max(1, high - low),
    bounds = state.overview.range;
  const x = (stamp) =>
    pad +
    ((stamp - bounds.start) / Math.max(1, bounds.end - bounds.start)) *
      (width - pad * 2);
  const y = (v) =>
    height -
    pad -
    ((v - low + span * 0.15) / (span * 1.3)) * (height - pad * 2);
  const segments = chartSegments(data, bounds.bucket);
  const lines = segments
    .map((segment) =>
      segment.length === 1
        ? `<circle cx="${x(segment[0].timestamp)}" cy="${y(segment[0].value)}" r="3" fill="${METRICS[name].color}"/>`
        : `<polyline class="chart-line" stroke="${METRICS[name].color}" points="${segment.map((point) => `${x(point.timestamp)},${y(point.value)}`).join(" ")}"/>`,
    )
    .join("");
  const grid = small
    ? ""
    : [0.2, 0.5, 0.8]
        .map(
          (t) =>
            `<line class="chart-grid" x1="${pad}" x2="${width - pad}" y1="${height * t}" y2="${height * t}"/>`,
        )
        .join("");
  const labels = small
    ? ""
    : `<text class="chart-label" x="${pad}" y="${height - 2}">${escape(new Date(bounds.start * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" }))}</text><text class="chart-label" x="${width - pad}" y="${height - 2}" text-anchor="end">${escape(new Date((bounds.end - 1) * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" }))}</text>`;
  return `<svg class="${small ? "sparkline" : "chart"}" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="${escape(METRICS[name].label)} chart: ${metric.count} readings; ${name === "charging" ? "latest state " + formatValue(metric.latest.value, name) : "average " + formatValue(metric.mean, name, prefs.temp) + " " + unit(name)}. Gaps show missing readings.">${grid}${lines}${labels}</svg>`;
}
function card(name) {
  const metric = state.overview?.metrics[name];
  return `<a class="metric-card" href="#metric/${name}"><div class="metric-label"><span class="metric-dot" data-metric="${name}"></span>${escape(METRICS[name].short || METRICS[name].label)}</div><div class="metric-number">${value(metric?.latest?.value, name)}<span class="unit">${escape(unit(name))}</span></div><p>${metric ? escape(when(metric.latest.timestamp)) : "No reading in this date range"}</p><div class="card-footer">${badge(name)}${chart(name, true)}<span class="arrow-link" aria-hidden="true">↗</span></div></a>`;
}
function hero(name = "hr_bpm") {
  const metric = state.overview?.metrics[name];
  return `<div class="hero"><div class="hero-head"><a href="#metric/${name}" class="metric-label">${escape(METRICS[name].label)} <span aria-hidden="true">↗</span></a>${badge(name)}</div><div class="hero-values"><div><div class="big-number">${value(name === "charging" ? metric?.latest?.value : metric?.mean, name)}<span class="unit">${escape(unit(name))}</span></div><p class="number-caption">${name === "charging" ? "Latest state in selected range" : "Average in selected range"}</p></div>${metric && name !== "charging" ? `<div class="hero-meta"><div>${value(metric.min, name)}<small>LOWEST</small></div><div>${value(metric.max, name)}<small>HIGHEST</small></div><div>${metric.count.toLocaleString()}<small>READINGS</small></div></div>` : ""}</div>${chart(name)}<p class="chart-note">Measured observations · Missing intervals stay visible · ${escape(measurementLabel(name))}</p></div>`;
}
function syncStrip() {
  const device = state.status?.devices[state.device];
  return `<div class="sync-strip"><div><h3>${device?.last_complete_sync ? "Full sync recorded" : "Full sync not yet recorded"}</h3><p>${device?.last_complete_sync ? escape(when(device.last_complete_sync)) : "Waiting for both history channels to finish."}</p></div><div class="sync-detail"><p>${(device?.epoch_count || 0).toLocaleString()} history epochs archived · ${device?.last_upload ? "Latest upload " + escape(when(device.last_upload)) : "No uploads yet"}</p></div></div>`;
}
function emptyBanner() {
  return !state.device
    ? `<div class="empty-banner"><h2>Your first sync starts here.</h2><p>Once your ESP32 downloads the ring and uploads to this collector, your measurements will appear here. Keep the ring nearby and check the bridge's USB serial output for pairing and sync progress.</p></div>`
    : "";
}
function unsupported() {
  return `<div class="info-band"><h3>Every number has a source.</h3><p>Sleep stages, stress, daily step totals and recovery scores aren't decoded by this bridge yet. Temperature is a live sync observation; sleep-context vitals have their own timestamps. Only measured values appear here.</p></div>`;
}
function summary() {
  return (
    emptyBanner() +
    hero() +
    `<div class="section-heading"><h2>Your daily observations</h2><p>${escape(when(range().end - 1, { hour: undefined, minute: undefined }))}</p></div><div class="metrics-grid">${["hrv_rmssd_ms", "spo2_pct", "respiratory_rate", "skin_temp_c", "quarter_hour_steps", "battery_pct"].map(card).join("")}</div>` +
    syncStrip() +
    unsupported()
  );
}
function browse() {
  return (
    emptyBanner() +
    `<div class="section-heading"><h2>Vitals & activity</h2><p>Latest reading in your selected range</p></div><div class="metrics-grid">${Object.keys(METRICS).map(card).join("")}</div>` +
    unsupported()
  );
}
function trends() {
  return (
    emptyBanner() +
    `<div class="info-band"><h3>A little context for your patterns.</h3><p>These compare observed averages with the preceding equally long period. They aren't diagnoses or health scores. A comparison appears only when both periods have at least three readings.</p></div><div class="trend-grid">${[
      "hr_bpm",
      "hrv_rmssd_ms",
      "spo2_pct",
      "respiratory_rate",
      "skin_temp_c",
      "quarter_hour_steps",
    ]
      .map((name) => {
        const metric = state.overview?.metrics[name],
          change = comparison(metric);
        return `<a href="#metric/${name}" class="trend-card"><h3>${escape(METRICS[name].label)} <span aria-hidden="true">↗</span></h3><div class="trend-value">${value(name === "charging" ? metric?.latest?.value : metric?.mean, name)}<span class="unit">${escape(unit(name))}</span></div><p>${metric ? metric.count.toLocaleString() + " readings in this range" : "No readings in this range"}</p>${chart(name)}<div class="trend-comparison">${escape(comparisonText(change, name, prefs.temp))}</div></a>`;
      })
      .join("")}</div>`
  );
}
function sampleRows(name) {
  return state.samples
    .slice()
    .reverse()
    .map(
      (point) =>
        `<tr><td>${escape(when(point.timestamp))}</td><td>${value(point.value, name)} ${escape(unit(name))}</td><td>${point.source === "history" ? "Ring history" : "Live status"}</td></tr>`,
    )
    .join("");
}
function detail(name) {
  const metric = state.overview?.metrics[name];
  if (state.offline)
    return `<div class="detail-chart">${hero(name)}</div><div class="info-band"><h3>Exact readings unavailable offline</h3><p>This saved view contains chart summaries. Reconnect to load individual readings or export data.</p></div>`;
  return `<div class="detail-heading"><a href="#browse">← Browse health</a><button class="quiet" id="export">Export selected range</button></div><div class="detail-chart">${hero(name)}</div><div class="info-band"><h3>About this measurement</h3><p>${escape(METRICS[name].description)}</p></div><div class="sample-section"><div class="section-heading"><h2>Recorded readings</h2><p>Exact observations, newest first</p></div><div class="sample-scroll"><table class="samples"><thead><tr><th>OBSERVED</th><th>VALUE</th><th>SOURCE</th></tr></thead><tbody id="sample-rows">${sampleRows(name) || '<tr><td colspan="3">No readings in this range.</td></tr>'}</tbody></table></div><div class="sample-actions"><span>${state.samples.length.toLocaleString()} of ${(metric?.count || 0).toLocaleString()} readings shown</span>${state.nextBefore ? '<button id="load-earlier" class="quiet">Load earlier readings</button>' : ""}</div></div>`;
}
function settings() {
  const secure = window.isSecureContext;
  return `<div class="settings"><div class="settings-section"><h2>Your preferences</h2><div class="setting-row"><label for="theme">Appearance</label><select id="theme"><option value="auto">Follow device</option><option value="light">Light</option><option value="dark">Dark</option></select></div><div class="setting-row"><label for="temperature">Temperature</label><select id="temperature"><option value="C">Celsius</option><option value="F">Fahrenheit</option></select></div></div><div class="settings-section"><h2>Privacy & offline access</h2><p>Health data is kept on your collector. By default, this browser only saves the app shell and your display preferences.</p><div class="setting-row"><label for="offline-save">Keep my last view offline<span>Opt in to save a health snapshot on this device. Anyone with access to this browser may see it while offline. Signing out clears it.</span></label><input id="offline-save" type="checkbox" ${prefs.offline ? "checked" : ""}></div><button id="clear-local" class="quiet">Clear saved health data</button><button id="sign-out" class="quiet">Sign out</button></div><div class="settings-section"><h2>Make room on your home screen</h2><p>${secure ? "On iPhone: open Share, then Add to Home Screen. On desktop and Android, use your browser’s Install option." : "Open this collector through a private HTTPS address to enable home-screen installation and the offline shell on your phone."}</p>${state.install ? '<button id="install" class="primary">Install OpenCircuit</button>' : ""}<p>The app shell works offline. Your health snapshot is available offline only if you enable it above.</p></div><div class="settings-section"><h2>Your data, in context</h2><p>RingConn Gen 2 · ESP32 local bridge · Stored in your collector's SQLite archive. The current decoder provides ten measurement types. Apple Health synchronization requires a native iOS companion; this PWA does not write to HealthKit.</p><button id="export" class="quiet" ${!state.device ? "disabled" : ""}>Export selected date range</button></div></div>`;
}
function route() {
  const [tab, name] = location.hash.slice(1).split("/");
  return tab === "metric" && METRICS[name]
    ? { tab, name }
    : {
        tab: ["summary", "browse", "trends", "settings"].includes(tab)
          ? tab
          : "summary",
      };
}
function render() {
  const { tab, name } = route();
  $("#anchor").value = state.anchor;
  if (state.offline && state.overview) {
    $("#custom-start").value = localDate(
      new Date(state.overview.range.start * 1000),
    );
    $("#custom-end").value = localDate(
      new Date((state.overview.range.end - 1) * 1000),
    );
    $("#custom-range").hidden = state.preset !== "custom";
  }
  for (const control of $("#range-toolbar").querySelectorAll("input, button"))
    control.disabled = state.offline;
  for (const button of document.querySelectorAll("[data-range]"))
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.range === state.preset),
    );
  $("#page-title").textContent = name
    ? METRICS[name].label
    : {
        summary: "Your health, in perspective.",
        browse: "Browse your health",
        trends: "Patterns over time",
        settings: "Make it yours",
      }[tab];
  $("#page-subtitle").textContent = {
    summary: "Small observations. A bigger picture.",
    browse: "Measured values, with their context.",
    trends: "Take the longer view of your everyday.",
    settings: "A private journal, on your terms.",
    metric: "Explore the observations behind each number.",
  }[tab];
  $("#range-toolbar").hidden = tab === "settings";
  for (const link of document.querySelectorAll("[data-tab]")) {
    if (link.dataset.tab === (tab === "metric" ? "browse" : tab))
      link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  $("#view").innerHTML =
    tab === "metric"
      ? detail(name)
      : { summary, browse, trends, settings }[tab]();
  if (tab === "settings") {
    $("#theme").value = prefs.theme || "auto";
    $("#temperature").value = prefs.temp || "C";
  }
}
async function saveSnapshot() {
  if (prefs.offline && state.status && state.overview && !state.offline) {
    try {
      await snapshotStore("put", {
        status: state.status,
        overview: state.overview,
        device: state.device,
        preset: state.preset,
        anchor: state.anchor,
        savedAt: Date.now(),
      });
    } catch {
      notice("Offline health saving is unavailable in this browser.", true);
    }
  }
}
async function loadSamples(append = false) {
  const { tab, name } = route();
  if (tab !== "metric" || !state.device || state.offline) return;
  const bounds = range(),
    query = new URLSearchParams({
      device: state.device,
      metric: name,
      since: bounds.start,
      until: bounds.end,
      limit: 100,
    });
  if (append && state.nextBefore) query.set("before", state.nextBefore);
  const sequence = state.sequence,
    request = ++state.sampleRequest;
  const result = await api("/history?" + query);
  if (
    sequence !== state.sequence ||
    request !== state.sampleRequest ||
    route().name !== name
  )
    return;
  state.samples = append ? [...result.points, ...state.samples] : result.points;
  state.nextBefore = result.next_before;
  render();
}
async function load() {
  const sequence = ++state.sequence;
  $("#refresh").disabled = true;
  $("#connection").textContent = "Updating";
  notice("");
  try {
    if (prefs.pendingLogout) {
      await api("/auth/logout", {});
      delete prefs.pendingLogout;
      savePrefs();
      showLogin();
      return;
    }
    const status = await api("/status");
    if (sequence !== state.sequence) return;
    state.status = status;
    state.offline = false;
    const devices = Object.keys(status.devices);
    if (!devices.includes(state.device)) state.device = devices[0] || "";
    $("#device").innerHTML = devices.length
      ? devices
          .map(
            (dev, index) =>
              `<option value="${escape(dev)}">Ring ${index + 1} · ${escape(dev.slice(-5))}</option>`,
          )
          .join("")
      : "<option>No rings yet</option>";
    $("#device").value = state.device;
    $("#device").disabled = !devices.length;
    const bounds = range();
    if (
      !Number.isFinite(bounds.start) ||
      !Number.isFinite(bounds.end) ||
      bounds.start >= bounds.end
    )
      throw new Error("Choose a valid date range ending today or earlier.");
    state.overview = state.device
      ? await api(
          "/overview?" +
            new URLSearchParams({
              device: state.device,
              start: bounds.start,
              end: bounds.end,
              bucket: Math.max(
                900,
                Math.floor((bounds.end - bounds.start) / 96),
              ),
            }),
        )
      : null;
    if (sequence !== state.sequence) return;
    state.samples = [];
    state.nextBefore = null;
    $("#login").hidden = true;
    $("#app").hidden = false;
    const device = status.devices[state.device];
    $("#connection").textContent =
      device?.sync_state === "healthy"
        ? "Collector connected · sync current"
        : "Collector connected";
    render();
    await loadSamples();
    await saveSnapshot();
  } catch (error) {
    if (sequence !== state.sequence) return;
    if (error.status === 401) {
      state.status = state.overview = null;
      state.samples = [];
      await snapshotStore("clear").catch(() => {});
      showLogin();
      notice("");
    } else if (!error.status && prefs.offline && !prefs.pendingLogout) {
      const snapshot = await snapshotStore("get").catch(() => null);
      if (snapshot) {
        Object.assign(state, snapshot, { offline: true });
        $("#login").hidden = true;
        $("#app").hidden = false;
        $("#device").innerHTML = "<option>Saved ring view</option>";
        $("#device").disabled = true;
        $("#connection").textContent = "Offline snapshot";
        notice(
          "Offline · Saved " +
            when(snapshot.savedAt / 1000) +
            ". This is a saved view, not current telemetry.",
        );
        render();
      } else {
        showLogin("The collector is unreachable and no offline view is saved.");
        $("#connection").textContent = "Collector unavailable";
      }
    } else {
      notice(error.message || "The collector is unreachable.", true);
      $("#connection").textContent = "Collector unavailable";
      if (state.status) {
        $("#view").innerHTML =
          '<div class="error-panel"><h2>Your view could not be updated.</h2><p>Check the collector and try refreshing. A connection error does not mean there are no readings.</p></div>';
      } else showLogin(error.message);
    }
  } finally {
    if (sequence === state.sequence) $("#refresh").disabled = false;
  }
}
async function exportData() {
  if (!state.device || state.offline) {
    notice("Connect to your collector to export its records.", true);
    return;
  }
  const bounds = range();
  const response = await fetch(
    "/export.csv?" +
      new URLSearchParams({
        device: state.device,
        since: bounds.start,
        until: bounds.end,
      }),
    { cache: "no-store" },
  );
  if (!response.ok)
    throw new Error("Export failed. Refresh your session and try again.");
  const url = URL.createObjectURL(await response.blob());
  const link = document.createElement("a");
  link.href = url;
  link.download = `opencircuit-${state.anchor}.csv`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
$("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = event.target.querySelector("button");
  button.disabled = true;
  $("#login-error").textContent = "";
  try {
    await api("/auth/login", { token: $("#access-key").value });
    $("#access-key").value = "";
    await load();
  } catch (error) {
    $("#login-error").textContent = error.message;
  } finally {
    button.disabled = false;
  }
});
$("#refresh").addEventListener("click", load);
$("#device").addEventListener("change", (event) => {
  state.device = event.target.value;
  load();
});
$("#anchor").value = state.anchor;
$("#anchor").max = state.anchor;
$("#custom-start").value = state.anchor;
$("#custom-end").value = state.anchor;
$("#custom-end").max = state.anchor;
$("#anchor").addEventListener("change", (event) => {
  state.anchor = event.target.value;
  load();
});
$("#apply-range").addEventListener("click", load);
$(".segmented").addEventListener("click", (event) => {
  const preset = event.target.dataset.range;
  if (!preset) return;
  state.preset = preset;
  for (const button of document.querySelectorAll("[data-range]"))
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.range === preset),
    );
  $("#custom-range").hidden = preset !== "custom";
  $(".date-label").hidden = preset === "custom";
  if (preset !== "custom") load();
});
$("#view").addEventListener("change", async (event) => {
  if (event.target.id === "theme") {
    prefs.theme = event.target.value;
    savePrefs();
    applyTheme();
  }
  if (event.target.id === "temperature") {
    prefs.temp = event.target.value;
    savePrefs();
    render();
  }
  if (event.target.id === "offline-save") {
    prefs.offline = event.target.checked;
    savePrefs();
    if (prefs.offline) await saveSnapshot();
    else await snapshotStore("clear").catch(() => {});
  }
});
$("#view").addEventListener("click", async (event) => {
  const button = event.target.closest("button");
  if (!button) return;
  try {
    if (button.id === "export") {
      button.disabled = true;
      await exportData();
    }
    if (button.id === "load-earlier") {
      button.disabled = true;
      await loadSamples(true);
    }
    if (button.id === "clear-local") {
      await snapshotStore("clear");
      prefs.offline = false;
      savePrefs();
      if (state.offline) {
        ++state.sequence;
        state.status = state.overview = null;
        state.samples = [];
        state.device = "";
        showLogin(
          "Saved health data cleared. Reconnect to view your measurements.",
        );
        notice("");
      } else {
        notice("Saved health data cleared from this browser.");
        render();
      }
    }
    if (button.id === "sign-out") {
      prefs.pendingLogout = true;
      savePrefs();
      ++state.sequence;
      state.status = state.overview = null;
      state.device = "";
      state.samples = [];
      await snapshotStore("clear").catch(() => {});
      try {
        await api("/auth/logout", {});
        delete prefs.pendingLogout;
        savePrefs();
      } catch {}
      showLogin(
        prefs.pendingLogout
          ? "Saved health data cleared. Server sign-out will finish when you reconnect."
          : "",
      );
      notice("");
    }
    if (button.id === "install" && state.install) {
      await state.install.prompt();
      state.install = null;
      render();
    }
  } catch (error) {
    notice(error.message, true);
  } finally {
    button.disabled = false;
  }
});
window.addEventListener("hashchange", () => {
  if (!state.status) return;
  state.samples = [];
  state.nextBefore = null;
  render();
  window.scrollTo({ top: 0, behavior: "instant" });
  loadSamples().catch((error) => notice(error.message, true));
});
window.addEventListener("online", load);
window.addEventListener("offline", () =>
  notice(
    "Connection lost. Your current view was loaded earlier; refresh to open an opted-in offline snapshot.",
  ),
);
window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  state.install = event;
  if (route().tab === "settings" && state.status) render();
});
if ("serviceWorker" in navigator && window.isSecureContext)
  navigator.serviceWorker
    .register("/sw.js")
    .catch(() => notice("The offline app shell could not be enabled."));
load();
