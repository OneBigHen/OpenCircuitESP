/*! ringconn-card — custom Lovelace card for a RingConn Gen 2 smart ring (OpenCircuit bridge).
 *  Single file, no dependencies, Shadow DOM, hand-written SVG. */
(() => {
  if (customElements.get('ringconn-card')) return;

  const DAY = 86400;
  const GAP = 1000; // seconds; > one 15-min bucket apart = a real gap
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const isNum = (v) => typeof v === 'number' && isFinite(v);
  const c2f = (c) => (c * 9) / 5 + 32;
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const nf = (v, d = 0) => (isNum(v) ? v.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }) : '–');

  const METRICS = {
    hr_bpm: { key: 'hr', label: 'Heart rate', short: 'HR', unit: 'bpm', dec: 0 },
    hrv_rmssd_ms: { key: 'hrv', label: 'HRV', short: 'HRV', sub: 'RMSSD', unit: 'ms', dec: 0 },
    spo2_pct: { key: 'spo2', label: 'Blood oxygen', short: 'SpO₂', unit: '%', dec: 0 },
    respiratory_rate: { key: 'resp', label: 'Respiration', short: 'Resp', unit: 'br/min', dec: 1 },
    skin_temp_c: { key: 'temp', label: 'Skin temp', short: 'Temp', unit: '°F', dec: 1, conv: c2f },
    battery_pct: { key: 'bat', label: 'Ring battery', short: 'Battery', unit: '%', dec: 0 },
    quarter_hour_steps: { key: 'steps', label: 'Steps', short: 'Steps', unit: 'steps', dec: 0, bars: true },
  };
  const VITALS = ['hr_bpm', 'hrv_rmssd_ms', 'spo2_pct', 'respiratory_rate', 'skin_temp_c'];
  const TABS = ['hr_bpm', 'hrv_rmssd_ms', 'spo2_pct', 'respiratory_rate', 'skin_temp_c', 'battery_pct', 'quarter_hour_steps'];

  const LOCATIONS = {
    bedside_case: ['Bedside case', 'Resting in its charging case'],
    bedside: ['Bedside', 'Within range of the bedside'],
    living_room: ['Living room', 'Within range in the living room'],
    out_of_range: ['Out of range', 'Not reachable by the bridge'],
  };

  const STYLE = `
:host{
  display:block;
  --rc-ink:var(--primary-text-color,hsl(220 18% 14%));
  --rc-bg:var(--card-background-color,hsl(40 22% 96%));
  --rc-mute:color-mix(in srgb,var(--secondary-text-color,hsl(220 8% 38%)) 72%,var(--rc-ink));
  --rc-line:var(--divider-color,hsl(220 10% 80%));
  --c-hr:hsl(6 68% 41%); --c-hrv:hsl(172 70% 26%); --c-spo2:hsl(206 78% 33%);
  --c-resp:hsl(34 85% 30%); --c-temp:hsl(334 60% 40%); --c-bat:hsl(142 60% 26%); --c-steps:hsl(28 80% 34%);
  --rc-warn:hsl(14 76% 40%); --rc-ok:hsl(150 60% 28%); --rc-amber:hsl(38 90% 34%);
  --rc-font:"Plus Jakarta Sans","DM Sans","Manrope",system-ui,-apple-system,"Segoe UI",sans-serif;
}
*{box-sizing:border-box}
.card{
  container-type:inline-size; container-name:rc;
  font-family:var(--rc-font); color:var(--rc-ink);
  background:color-mix(in srgb,var(--rc-bg) 90%,hsl(38 35% 86%));
  border-radius:var(--ha-card-border-radius,20px);
  padding:22px 20px 18px; font-variant-numeric:tabular-nums lining-nums; line-height:1.35;
}
.card[data-scheme=dark]{
  background:color-mix(in srgb,var(--rc-bg) 94%,hsl(210 30% 10%));
  --c-hr:hsl(8 90% 72%); --c-hrv:hsl(168 62% 58%); --c-spo2:hsl(206 90% 72%);
  --c-resp:hsl(40 90% 64%); --c-temp:hsl(334 85% 76%); --c-bat:hsl(142 58% 58%); --c-steps:hsl(28 92% 66%);
  --rc-warn:hsl(14 92% 68%); --rc-ok:hsl(150 60% 58%); --rc-amber:hsl(42 92% 62%);
}
.m-hr{--m:var(--c-hr)} .m-hrv{--m:var(--c-hrv)} .m-spo2{--m:var(--c-spo2)} .m-resp{--m:var(--c-resp)}
.m-temp{--m:var(--c-temp)} .m-bat{--m:var(--c-bat)} .m-steps{--m:var(--c-steps)}
h2,h3,p{margin:0}
.num{font-weight:700;letter-spacing:-.02em}
.mute{color:var(--rc-mute)}
.eyebrow{font-size:.72rem;letter-spacing:.12em;text-transform:uppercase;font-weight:700;color:var(--rc-mute)}
section{padding-top:18px;margin-top:18px;border-top:1px solid var(--rc-line)}
section>header{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin-bottom:10px}
section h3{font-size:.72rem;letter-spacing:.12em;text-transform:uppercase;font-weight:700;color:var(--rc-mute)}
.hint{font-size:.78rem;color:var(--rc-mute)}

/* hero */
.hero{display:grid;gap:18px}
.hero-top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
.fresh{display:inline-flex;align-items:center;gap:7px;font-size:.78rem;font-weight:600;color:var(--rc-mute)}
.fresh i{width:8px;height:8px;border-radius:50%;background:var(--rc-ok);display:inline-block}
.fresh.warn i{background:var(--rc-amber)} .fresh.bad i{background:var(--rc-warn)}
@media (prefers-reduced-motion:no-preference){.fresh.ok i{animation:pulse 2.4s ease-in-out infinite}}
@keyframes pulse{50%{opacity:.35}}
.where h2{font-size:clamp(1.9rem,8cqi,3.1rem);line-height:1.02;font-weight:800;letter-spacing:-.035em;margin:6px 0 8px}
.where p{font-size:.95rem;color:var(--rc-mute)}
.where p b{color:var(--rc-ink);font-weight:700}
.pills{display:flex;gap:6px;flex-wrap:wrap;margin-top:12px}
.pill{font-size:.78rem;font-weight:700;padding:3px 11px;border-radius:99px;border:1.5px solid currentColor}
.pill.on{color:var(--rc-ok)} .pill.off{color:var(--rc-mute)} .pill.chg{color:var(--rc-amber)} .pill.bad{color:var(--rc-warn)}
.batt .big{font-size:clamp(3.2rem,16cqi,5.4rem);line-height:.95;font-weight:800;letter-spacing:-.05em;color:var(--c-bat)}
.batt .big small{font-size:.38em;font-weight:700;letter-spacing:0;margin-left:2px}
.bar{height:10px;border-radius:5px;background:color-mix(in srgb,var(--rc-ink) 12%,transparent);overflow:hidden;margin:12px 0 8px;max-width:420px}
.bar>b{display:block;height:100%;border-radius:5px;background:var(--c-bat)}
.batt .sub{font-size:.9rem;color:var(--rc-mute)} .batt .sub b{color:var(--rc-ink)}
@container rc (min-width:640px){
  .hero{grid-template-columns:1.25fr 1fr;align-items:end;column-gap:40px}
  .hero-top{grid-column:1/-1}
}

/* layout */
.main{display:block}
@container rc (min-width:900px){
  .main{display:grid;grid-template-columns:minmax(0,1.5fr) minmax(0,1fr);column-gap:40px}
}

/* vitals */
.vrow{display:grid;grid-template-columns:1fr auto;grid-template-areas:"id val" "spark spark" "rng rng";gap:4px 12px;padding:12px 0;border-top:1px solid var(--rc-line)}
.vrow:first-of-type{border-top:0;padding-top:2px}
.vid b{display:block;font-size:.95rem;font-weight:700}
.vid span{font-size:.78rem;color:var(--rc-mute)}
.vval{grid-area:val;text-align:right;white-space:nowrap}
.vval .v{font-size:1.9rem;line-height:1;color:var(--m)}
.vval .u{font-size:.78rem;font-weight:600;color:var(--rc-mute);margin-left:3px}
.vval .alt{display:block;font-size:.76rem;color:var(--rc-mute);margin-top:2px}
.vrow.hr .v{font-size:2.7rem}
.vspark{grid-area:spark;display:block;width:100%;height:34px}
.vrng{grid-area:rng;font-size:.76rem;color:var(--rc-mute);display:flex;justify-content:space-between}
.vrow.empty .vval .v{color:var(--rc-mute);font-size:1.4rem}
@container rc (min-width:560px){
  .vrow{grid-template-columns:minmax(120px,1fr) 150px minmax(0,1.6fr);grid-template-areas:"id val spark" "id val rng";align-items:center}
  .vval{text-align:left}
  .vspark{height:38px}
}

/* timeline */
.tabs{display:flex;gap:4px;flex-wrap:wrap;margin-bottom:12px}
.tab{font:inherit;font-size:.8rem;font-weight:700;padding:5px 12px;border-radius:99px;border:1.5px solid var(--rc-line);background:transparent;color:var(--rc-mute);cursor:pointer}
.tab:hover{color:var(--rc-ink);border-color:var(--rc-mute)}
.tab[aria-checked=true]{background:var(--m);border-color:var(--m);color:var(--rc-bg)}
button:focus-visible,.chartwrap:focus-visible{outline:3px solid var(--rc-ink);outline-offset:2px}
.readout{min-height:2.6em;margin-bottom:4px;font-size:.9rem}
.readout b{font-size:1.5rem;color:var(--m);margin-right:4px}
.chartwrap{position:relative;border-radius:8px;touch-action:pan-y}
.chartwrap svg{display:block;width:100%;height:auto;overflow:visible}
svg text{font-family:var(--rc-font);font-size:11px;fill:var(--rc-mute);font-variant-numeric:tabular-nums}
.grid{stroke:var(--rc-line);stroke-width:1}
.band{fill:var(--m);opacity:.2}
.avg{fill:none;stroke:var(--m);stroke-width:2.2;stroke-linejoin:round;stroke-linecap:round}
.bar-s{fill:var(--m)}
.cursor{stroke:var(--rc-ink);stroke-width:1;opacity:.55}
.legend{display:flex;gap:16px;font-size:.76rem;color:var(--rc-mute);margin-top:6px;flex-wrap:wrap}
.legend i{display:inline-block;vertical-align:middle;margin-right:6px}

/* activity */
.steps-hero{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
.steps-hero .big{font-size:3rem;line-height:1;font-weight:800;letter-spacing:-.04em;color:var(--c-steps)}
.trend{display:grid;grid-template-columns:1fr auto;gap:2px 10px;padding:9px 0;border-top:1px solid var(--rc-line)}
.trend:first-of-type{border-top:0}
.trend b{font-size:.85rem}
.trend .tv{font-weight:700;text-align:right;color:var(--m)}
.trend svg{grid-column:1/-1;width:100%;height:28px;display:block}
.stepsvg{display:block;width:100%;height:auto;margin:10px 0 4px;overflow:visible}

/* battery */
.bat-row{display:flex;gap:18px;flex-wrap:wrap;margin-bottom:6px;font-size:.88rem;color:var(--rc-mute)}
.bat-row b{color:var(--rc-ink);font-size:1.05rem}
.case{display:flex;align-items:center;gap:12px;margin-top:12px;font-size:.88rem}
.case .bar{flex:1;margin:0;max-width:none;height:8px}
.case .bar>b{background:var(--rc-mute)}

/* bridge */
dl.kv{display:grid;grid-template-columns:auto 1fr;gap:5px 18px;margin:0 0 14px;font-size:.88rem}
dl.kv dt{color:var(--rc-mute)} dl.kv dd{margin:0;font-weight:600;text-align:right}
.links svg{display:block;width:100%;height:auto}
.rbar{fill:var(--rc-ok)} .rbar.mid{fill:var(--rc-amber)} .rbar.low{fill:var(--rc-warn)} .dbar{fill:var(--rc-warn)}
.empty-note{padding:18px 0 6px;color:var(--rc-mute);font-size:.9rem}
.foot{margin-top:18px;font-size:.72rem;color:var(--rc-mute);text-align:right}
`;

  class RingConnCard extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: 'open' });
      this._cfg = null; this._hass = null; this._sig = ''; this._tab = null; this._w = 0; this._raf = 0;
    }

    static getStubConfig() { return { type: 'custom:ringconn-card' }; }

    setConfig(config) {
      this._cfg = {
        title: 'RingConn Gen 2',
        dashboard_entity: 'sensor.ringconn_dashboard',
        state_entity: 'sensor.ringconn_ring_state',
        location_entity: 'sensor.ringconn_ring_location',
        area_entity: 'sensor.ringconn_ring_area',
        default_metric: 'hr_bpm',
        show_bridge: true,
        ...config,
      };
      if (!METRICS[this._cfg.default_metric]) this._cfg.default_metric = 'hr_bpm';
      this._tab = this._tab || this._cfg.default_metric;
      this._sig = '';
      this._render();
    }

    getCardSize() { return 14; }
    getGridOptions() { return { columns: 'full', min_columns: 6, rows: 'auto' }; }

    set hass(hass) {
      this._hass = hass;
      if (!this._cfg) return;
      const c = this._cfg;
      const sig = [c.dashboard_entity, c.state_entity, c.location_entity, c.area_entity]
        .map((id) => { const s = hass.states?.[id]; return s ? `${s.last_updated}|${s.state}` : '-'; }).join('~');
      if (sig === this._sig) return;
      this._sig = sig;
      this._render();
    }

    connectedCallback() {
      this._ro = new ResizeObserver((e) => {
        const w = Math.round(e[0].contentRect.width);
        if (Math.abs(w - this._w) < 2) return;
        this._w = w;
        cancelAnimationFrame(this._raf);
        this._raf = requestAnimationFrame(() => this._render());
      });
      this._ro.observe(this);
      this._timer = setInterval(() => { if (!document.hidden && this._cfg) this._render(); }, 30000);
    }
    disconnectedCallback() { this._ro?.disconnect(); clearInterval(this._timer); cancelAnimationFrame(this._raf); }

    /* ---------- data ---------- */
    _data() {
      const st = this._hass?.states || {};
      const c = this._cfg;
      const dash = st[c.dashboard_entity];
      const a = dash?.attributes || {};
      const val = (id) => { const s = st[id]?.state; return s && !['unknown', 'unavailable', 'none', ''].includes(s) ? s : null; };
      const area = val(c.area_entity);
      return {
        have: !!dash && dash.state !== 'unavailable',
        gen: Number(dash?.state) || a.generated_at || 0,
        tz: a.timezone || this._hass?.config?.time_zone || undefined,
        latest: a.latest || {},
        series: a.series_24h || {},
        stepsToday: isNum(a.steps_today) ? a.steps_today : null,
        drain: isNum(a.battery_drain_pct_per_h) ? a.battery_drain_pct_per_h : null,
        days: Array.isArray(a.days) ? a.days : [],
        bridge: a.bridge || {},
        ringState: val(c.state_entity),
        loc: val(c.location_entity),
        area: area ? area.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase()) : null,
      };
    }

    _now() { return Date.now() / 1000; }

    _ago(t, now) {
      if (!isNum(t) || !t) return 'never';
      const d = Math.max(0, now - t);
      if (d < 60) return 'just now';
      if (d < 3600) return `${Math.round(d / 60)} min ago`;
      if (d < 3 * 3600) return `${Math.floor(d / 3600)} h ${Math.round((d % 3600) / 60)} min ago`;
      if (d < 2 * DAY) return `${Math.round(d / 3600)} h ago`;
      return `${Math.round(d / DAY)} d ago`;
    }

    _clock(t, tz, long) {
      try {
        return new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: tz, ...(long ? { weekday: 'short' } : {}) }).format(t * 1000);
      } catch { return new Date(t * 1000).toLocaleTimeString(); }
    }

    _pts(d, key) {
      const m = METRICS[key];
      const cv = m.conv || ((x) => x);
      const arr = (d.series[key] || []).filter((r) => Array.isArray(r) && isNum(r[0]) && isNum(r[1]));
      return arr.map(([t, avg, mn, mx]) => ({ t, avg: cv(avg), min: cv(isNum(mn) ? mn : avg), max: cv(isNum(mx) ? mx : avg) }))
        .sort((a, b) => a.t - b.t);
    }

    _segments(pts) {
      const segs = [];
      pts.forEach((p, i) => { if (i === 0 || p.t - pts[i - 1].t > GAP) segs.push([]); segs[segs.length - 1].push(p); });
      return segs;
    }

    /* ---------- svg helpers ---------- */
    _sparkSvg(pts, t0, t1, domain) {
      const W = 200, H = 34;
      if (!pts.length) return `<svg class="vspark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true"><line x1="0" x2="${W}" y1="${H / 2}" y2="${H / 2}" class="grid" stroke-dasharray="2 5" vector-effect="non-scaling-stroke"/></svg>`;
      let lo = domain ? domain[0] : Math.min(...pts.map((p) => p.min));
      let hi = domain ? domain[1] : Math.max(...pts.map((p) => p.max));
      if (hi - lo < 1e-6) { lo -= 1; hi += 1; }
      const x = (t) => clamp(((t - t0) / (t1 - t0)) * W, 1.5, W - 1.5);
      const y = (v) => H - 3 - ((v - lo) / (hi - lo)) * (H - 6);
      let out = `<line x1="0" x2="${W}" y1="${H - .5}" y2="${H - .5}" class="grid" vector-effect="non-scaling-stroke"/>`;
      for (const seg of this._segments(pts)) {
        if (seg.length > 1) {
          const top = seg.map((p) => `${x(p.t).toFixed(1)},${y(p.max).toFixed(1)}`);
          const bot = seg.slice().reverse().map((p) => `${x(p.t).toFixed(1)},${y(p.min).toFixed(1)}`);
          out += `<polygon class="band" points="${top.concat(bot).join(' ')}"/>`;
          out += `<polyline class="avg" vector-effect="non-scaling-stroke" style="stroke-width:1.8" points="${seg.map((p) => `${x(p.t).toFixed(1)},${y(p.avg).toFixed(1)}`).join(' ')}"/>`;
        } else {
          const p = seg[0];
          out += `<path class="avg" vector-effect="non-scaling-stroke" d="M${x(p.t).toFixed(1)} ${y(p.min).toFixed(1)}V${y(p.max).toFixed(1)}" style="stroke-width:2.2;opacity:.55"/>`;
          out += `<path class="avg" vector-effect="non-scaling-stroke" d="M${x(p.t).toFixed(1)} ${y(p.avg).toFixed(1)}h.01" style="stroke-width:4.5"/>`;
        }
      }
      const l = pts[pts.length - 1];
      out += `<path class="avg" vector-effect="non-scaling-stroke" d="M${x(l.t).toFixed(1)} ${y(l.avg).toFixed(1)}h.01" style="stroke-width:7"/>`;
      return `<svg class="vspark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true">${out}</svg>`;
    }

    _hourTicks(t0, t1, tz, step) {
      const fmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', hourCycle: 'h23', timeZone: tz });
      const out = [];
      for (let t = Math.ceil(t0 / 3600) * 3600; t <= t1; t += 3600) {
        const h = Number(fmt.formatToParts(t * 1000).find((p) => p.type === 'hour').value) % 24;
        if (h % step === 0) out.push({ t, h });
      }
      return out;
    }
    _hLabel(h) { return h === 0 ? '12a' : h === 12 ? '12p' : h < 12 ? `${h}a` : `${h - 12}p`; }

    /* ---------- sections ---------- */
    _hero(d, now) {
      const L = d.latest, chg = L.charging?.v === 1;
      const bat = L.battery_pct?.v, temp = L.skin_temp_c;
      const tempFresh = temp && now - temp.t < 3600;
      let worn = null;
      if (chg || d.ringState === 'in_case') worn = false;
      else if (tempFresh) worn = temp.v >= 30;
      const locKey = d.loc && LOCATIONS[d.loc] ? d.loc : null;
      const title = d.area || (locKey ? LOCATIONS[locKey][0] : d.ringState === 'in_case' ? 'In its case' : 'Location unknown');
      const sub = d.area ? 'Nearest room by Bluetooth' : locKey ? LOCATIONS[locKey][1] : 'No location sensor reporting';
      const seen = d.bridge.last_frame;
      const age = now - d.gen;
      const fcls = age < 1200 ? 'ok' : age < 7200 ? 'warn' : 'bad';
      const pills = [];
      if (chg) pills.push('<span class="pill chg">Charging</span>');
      if (d.ringState === 'in_case') pills.push('<span class="pill off">In case</span>');
      else if (d.ringState === 'out_of_case') pills.push('<span class="pill off">Out of case</span>');
      if (worn === true) pills.push(`<span class="pill on">On wrist · ${nf(c2f(temp.v), 1)}°F</span>`);
      else if (worn === false) pills.push('<span class="pill off">Not worn</span>');
      else pills.push('<span class="pill off">Wear unknown</span>');
      if (d.loc === 'out_of_range') pills.push('<span class="pill bad">Out of range</span>');

      let left;
      if (!isNum(bat)) left = '<div class="big num">–</div><p class="sub">No battery reading yet</p>';
      else {
        const hrs = d.drain > 0 && !chg ? bat / d.drain : null;
        const sub2 = chg ? `<b>Charging</b>${isNum(L.battery_mv?.v) ? ` · ${nf(L.battery_mv.v / 1000, 2)} V` : ''}`
          : hrs ? `About <b>${hrs >= 48 ? `${nf(hrs / 24, 1)} days` : `${nf(hrs)} h`}</b> left at ${nf(d.drain, 1)}%/h` : 'Drain rate not available yet';
        left = `<div class="big num">${nf(bat)}<small>%</small></div><div class="bar" role="img" aria-label="Ring battery ${nf(bat)} percent"><b style="width:${clamp(bat, 0, 100)}%"></b></div><p class="sub">${sub2}</p>`;
      }
      return `<div class="hero">
        <div class="hero-top"><span class="eyebrow">${esc(this._cfg.title)}</span>
          <span class="fresh ${fcls}" role="status"><i></i>Updated ${this._ago(d.gen, now)}</span></div>
        <div class="where"><h2>${esc(title)}</h2>
          <p>${esc(sub)}${seen ? ` · ring heard <b>${this._ago(seen, now)}</b>` : ''}</p>
          <div class="pills">${pills.join('')}</div></div>
        <div class="batt">${left}</div></div>`;
    }

    _vitals(d, now) {
      const t1 = d.gen || now, t0 = t1 - DAY;
      const rows = VITALS.map((k) => {
        const m = METRICS[k], pts = this._pts(d, k), lat = d.latest[k];
        const cv = m.conv || ((x) => x);
        let alt = '';
        if (k === 'skin_temp_c' && lat) alt = `<span class="alt">${nf(lat.v, 1)}°C</span>`;
        const idsub = lat ? `${this._clock(lat.t, d.tz)} · ${this._ago(lat.t, now)}` : 'No reading in 24 h';
        let rng = '<span>no data in the last 24 h</span>';
        if (pts.length) {
          const lo = Math.min(...pts.map((p) => p.min)), hi = Math.max(...pts.map((p) => p.max));
          const avg = pts.reduce((s, p) => s + p.avg, 0) / pts.length;
          rng = `<span>low ${nf(lo, m.dec)}</span><span>avg ${nf(avg, m.dec)}</span><span>high ${nf(hi, m.dec)}</span>`;
        }
        return `<div class="vrow m-${m.key} ${k === 'hr_bpm' ? 'hr' : ''} ${lat ? '' : 'empty'}">
          <div class="vid"><b>${m.label}${m.sub ? ` <span>${m.sub}</span>` : ''}</b><span>${idsub}</span></div>
          <div class="vval">${lat ? `<span class="v num">${nf(cv(lat.v), m.dec)}</span><span class="u">${m.unit}</span>${alt}` : '<span class="v num">No data</span>'}</div>
          ${this._sparkSvg(pts, t0, t1)}
          <div class="vrng">${rng}</div></div>`;
      });
      return `<section><header><h3>Vitals now</h3><span class="hint">band = min–max, line = average, 24 h</span></header>${rows.join('')}</section>`;
    }

    _timeline(d, now) {
      const tab = TABS.includes(this._tab) ? this._tab : 'hr_bpm';
      const m = METRICS[tab];
      const W = Math.max(280, Math.min(900, (this._w || 380) - (this._w >= 900 ? 460 : 40)));
      const wide = W > 520, H = wide ? 230 : 200;
      const mg = { l: 40, r: 8, t: 8, b: 22 };
      const t1 = d.gen || now, t0 = t1 - DAY;
      let pts = this._pts(d, tab);
      if (m.bars) pts = pts.map((p) => ({ ...p, avg: p.max, min: p.max }));
      this._tl = { pts, W, H, mg, t0, t1, tab, d };
      const tabs = TABS.map((k) => {
        const mm = METRICS[k];
        return `<button class="tab m-${mm.key}" role="radio" aria-checked="${k === tab}" data-tab="${k}" data-fid="tab-${k}" tabindex="${k === tab ? 0 : -1}">${mm.short}</button>`;
      }).join('');
      let svg = '', summary;
      if (!pts.length) {
        summary = `No ${m.label.toLowerCase()} readings in the last 24 hours.`;
        svg = `<div class="empty-note">Nothing to plot. The ring was not reachable or did not record ${m.label.toLowerCase()} in this window.</div>`;
      } else {
        let lo = Math.min(...pts.map((p) => p.min)), hi = Math.max(...pts.map((p) => p.max));
        if (m.bars) lo = 0;
        const pad = (hi - lo || 2) * 0.12;
        lo = m.bars ? 0 : lo - pad; hi += pad;
        if (tab === 'spo2_pct') hi = Math.min(hi, 100.5);
        if (m.dec === 0) { lo = m.bars ? 0 : Math.floor(lo / 3) * 3; hi = Math.ceil(hi / 3) * 3; }
        const iw = W - mg.l - mg.r, ih = H - mg.t - mg.b;
        const X = (t) => mg.l + ((t - t0) / (t1 - t0)) * iw;
        const Y = (v) => mg.t + ih - ((v - lo) / (hi - lo)) * ih;
        this._tl.X = X; this._tl.Y = Y;
        let g = '';
        for (let i = 0; i <= 3; i++) {
          const v = lo + ((hi - lo) * i) / 3, yy = Y(v);
          g += `<line class="grid" x1="${mg.l}" x2="${W - mg.r}" y1="${yy}" y2="${yy}" ${i ? 'stroke-dasharray="2 4"' : ''}/><text x="${mg.l - 6}" y="${yy + 4}" text-anchor="end">${nf(v, m.dec > 0 && hi - lo < 12 ? 1 : 0)}</text>`;
        }
        for (const tk of this._hourTicks(t0, t1, d.tz, wide ? 3 : 6)) {
          g += `<line class="grid" x1="${X(tk.t)}" x2="${X(tk.t)}" y1="${H - mg.b}" y2="${H - mg.b + 4}"/><text x="${X(tk.t)}" y="${H - 6}" text-anchor="middle">${this._hLabel(tk.h)}</text>`;
        }
        // gaps > 45 min shaded honestly
        let gaps = '';
        const edges = [{ t: t0 }, ...pts, { t: t1 }];
        for (let i = 1; i < edges.length; i++) {
          const a = i === 1 ? t0 : edges[i - 1].t + 450, b = i === edges.length - 1 ? t1 : edges[i].t - 450;
          if (b - a > 2700) gaps += `<rect x="${X(a)}" y="${mg.t}" width="${X(b) - X(a)}" height="${ih}" fill="url(#hatch)"/>`;
        }
        let body = '';
        if (m.bars) {
          const bw = Math.max(2, (iw / 96) * 0.8);
          body = pts.map((p) => `<rect class="bar-s" x="${X(p.t) - bw / 2}" y="${Y(p.avg)}" width="${bw}" height="${Math.max(1, Y(0) - Y(p.avg))}" rx="1.5"/>`).join('');
        } else {
          for (const seg of this._segments(pts)) {
            if (seg.length > 1) {
              const top = seg.map((p) => `${X(p.t).toFixed(1)},${Y(p.max).toFixed(1)}`);
              const bot = seg.slice().reverse().map((p) => `${X(p.t).toFixed(1)},${Y(p.min).toFixed(1)}`);
              body += `<polygon class="band" points="${top.concat(bot).join(' ')}"/><polyline class="avg" points="${seg.map((p) => `${X(p.t).toFixed(1)},${Y(p.avg).toFixed(1)}`).join(' ')}"/>`;
            } else {
              const p = seg[0];
              body += `<line class="avg" style="opacity:.5" x1="${X(p.t)}" x2="${X(p.t)}" y1="${Y(p.min)}" y2="${Y(p.max)}"/>`;
            }
          }
          body += pts.map((p) => `<circle cx="${X(p.t)}" cy="${Y(p.avg)}" r="2.6" fill="var(--m)"/>`).join('');
        }
        const sumAll = pts.reduce((s, p) => s + p.avg, 0);
        const all = { lo: Math.min(...pts.map((p) => p.min)), hi: Math.max(...pts.map((p) => p.max)) };
        summary = m.bars
          ? `<b class="num">${nf(pts.reduce((s, p) => s + p.avg, 0))}</b> steps logged in 24 h · hover or use arrow keys for each quarter hour`
          : `<b class="num">${nf(sumAll / pts.length, m.dec)}</b> ${m.unit} average · low ${nf(all.lo, m.dec)} · high ${nf(all.hi, m.dec)} · hover or use arrow keys`;
        this._tl.summary = summary;
        const aria = `${m.label} over the last 24 hours, ${pts.length} readings, average ${nf(sumAll / pts.length, m.dec)} ${m.unit}, from ${nf(all.lo, m.dec)} to ${nf(all.hi, m.dec)}.`;
        svg = `<div class="chartwrap" tabindex="0" data-fid="chart" role="img" aria-label="${esc(aria)} Use left and right arrow keys to inspect readings.">
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}"><defs><pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" stroke="var(--rc-line)" stroke-width="2" opacity=".7"/></pattern></defs>
          ${gaps}${g}${body}<line class="cursor" id="cur" x1="0" x2="0" y1="${mg.t}" y2="${H - mg.b}" visibility="hidden"/></svg></div>
          <div class="legend"><span><svg width="16" height="10" aria-hidden="true"><rect width="16" height="10" rx="2" class="band" style="opacity:.3"/></svg> min–max band</span><span><svg width="16" height="10" aria-hidden="true"><line x1="0" x2="16" y1="5" y2="5" class="avg"/></svg> 15-min average</span><span><svg width="16" height="10" aria-hidden="true"><rect width="16" height="10" fill="url(#hatch)"/></svg> ring not reachable</span></div>`;
      }
      this._tl.summary = this._tl.summary || summary;
      return `<section class="m-${m.key}"><header><h3>Last 24 hours</h3><span class="hint">${esc(d.tz ? d.tz.replace(/_/g, ' ') : '')}</span></header>
        <div class="tabs" role="radiogroup" aria-label="Signal to chart">${tabs}</div>
        <div class="readout" aria-live="polite" id="readout">${summary}</div>${svg}</section>`;
    }

    _activity(d) {
      const days = d.days.filter((x) => x && x.date);
      const past = days.filter((x) => isNum(x.steps) && x.steps > 0).slice(0, -1);
      const prev = days.slice(0, -1).filter((x) => isNum(x.steps) && x.steps > 0);
      const avg = prev.length ? prev.reduce((s, x) => s + x.steps, 0) / prev.length : null;
      void past;
      const steps = d.stepsToday;
      let bars = '';
      if (days.length) {
        const W = 340, H = 92, bw = W / days.length, max = Math.max(1, ...days.map((x) => x.steps || 0));
        bars = days.map((x, i) => {
          const h = Math.max(2, ((x.steps || 0) / max) * (H - 24)), last = i === days.length - 1;
          const dt = new Date(x.date + 'T12:00:00Z');
          const lbl = i % 2 === (days.length - 1) % 2 ? ['S', 'M', 'T', 'W', 'T', 'F', 'S'][dt.getUTCDay()] : '';
          return `<rect x="${i * bw + bw * .14}" y="${H - 16 - h}" width="${bw * .72}" height="${h}" rx="3" fill="var(--c-steps)" opacity="${last ? 1 : .5}"/>
            <text x="${i * bw + bw / 2}" y="${H - 3}" text-anchor="middle">${lbl}</text>${last || x.steps === max ? `<text x="${i * bw + bw / 2}" y="${H - 20 - h}" text-anchor="middle" style="font-weight:700;fill:var(--rc-ink)">${nf(x.steps)}</text>` : ''}`;
        }).join('');
        bars = `<svg class="stepsvg" viewBox="0 0 ${W} ${H}" role="img" aria-label="Daily steps for the last ${days.length} days. Today ${nf(steps ?? days[days.length - 1].steps)}.">${bars}</svg>`;
      }
      const trend = (key, idx, lab, cls, dec, unit) => {
        const vals = days.map((x, i) => ({ i, v: Array.isArray(x[key]) && x[key][0] > 0 ? x[key][idx] : null }));
        const good = vals.filter((p) => isNum(p.v));
        if (!good.length) return `<div class="trend m-${cls}"><b>${lab}</b><span class="tv mute">No data</span></div>`;
        const lo = Math.min(...good.map((p) => p.v)), hi = Math.max(...good.map((p) => p.v)), r = hi - lo || 1;
        const W = 300, H = 28, n = days.length - 1 || 1;
        const px = (i) => 4 + (i / n) * (W - 8), py = (v) => H - 4 - ((v - lo) / r) * (H - 8);
        let path = '', run = [];
        const flush = () => { if (run.length > 1) path += `<polyline class="avg" vector-effect="non-scaling-stroke" style="stroke-width:1.8" points="${run.join(' ')}"/>`; run = []; };
        vals.forEach((p) => { if (isNum(p.v)) run.push(`${px(p.i).toFixed(1)},${py(p.v).toFixed(1)}`); else flush(); });
        flush();
        const dots = good.map((p) => `<path class="avg" vector-effect="non-scaling-stroke" style="stroke-width:5" d="M${px(p.i).toFixed(1)} ${py(p.v).toFixed(1)}h.01"/>`).join('');
        const last = good[good.length - 1];
        return `<div class="trend m-${cls}"><b>${lab} <span class="mute" style="font-weight:500">${unit}</span></b><span class="tv num">${nf(last.v, dec)}</span>
          <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="${lab}, last ${days.length} days, ${nf(lo, dec)} to ${nf(hi, dec)}">${path}${dots}</svg></div>`;
      };
      const stepsLine = isNum(steps)
        ? `<div class="steps-hero"><span class="big num">${nf(steps)}</span><span class="mute">steps today${avg ? ` · ${nf(Math.round(avg))} daily avg` : ''}</span></div>`
        : '<div class="empty-note">No step count yet today.</div>';
      const goal = this._cfg.step_goal;
      const goalBar = isNum(steps) && goal > 0 ? `<div class="bar" role="img" aria-label="${nf(steps)} of ${nf(goal)} steps"><b style="width:${clamp((steps / goal) * 100, 0, 100)}%;background:var(--c-steps)"></b></div>` : '';
      return `<section><header><h3>Activity · ${days.length || 14} days</h3><span class="hint">today is partial</span></header>${stepsLine}${goalBar}${bars}
        ${trend('hr_bpm', 1, 'Resting-ish HR (daily low)', 'hr', 0, 'bpm')}${trend('hrv_rmssd_ms', 3, 'HRV (daily mean)', 'hrv', 0, 'ms')}${trend('spo2_pct', 3, 'SpO₂ (daily mean)', 'spo2', 1, '%')}</section>`;
    }

    _battery(d, now) {
      const L = d.latest, pts = this._pts(d, 'battery_pct');
      const t1 = d.gen || now, t0 = t1 - DAY;
      const chg = L.charging?.v === 1, cb = L.case_battery_pct;
      const stats = `<div class="bat-row"><span>Ring <b class="num" style="color:var(--c-bat)">${isNum(L.battery_pct?.v) ? nf(L.battery_pct.v) + '%' : '–'}</b></span>
        <span>${chg ? '<b>Charging</b>' : 'Drain <b class="num">' + (d.drain ? nf(d.drain, 1) + '%/h' : 'n/a') + '</b>'}</span>
        ${isNum(L.battery_mv?.v) ? `<span><b class="num">${nf(L.battery_mv.v / 1000, 2)}</b> V</span>` : ''}</div>`;
      const chart = pts.length
        ? `<div class="m-bat">${this._sparkSvg(pts, t0, t1, [Math.max(0, Math.min(...pts.map((p) => p.min)) - 8), 100]).replace('class="vspark"', 'class="vspark" style="height:56px" role="img" aria-label="Ring battery over 24 hours"').replace(' aria-hidden="true"', '')}</div><div class="vrng m-bat" style="display:flex;justify-content:space-between;font-size:.76rem;color:var(--rc-mute)"><span>24 h ago</span><span>now</span></div>`
        : '<div class="empty-note">No battery history in the last 24 h.</div>';
      const caseRow = isNum(cb?.v)
        ? `<div class="case"><span>Case <b class="num">${nf(cb.v)}%</b></span><div class="bar" role="img" aria-label="Case battery ${nf(cb.v)} percent"><b style="width:${clamp(cb.v, 0, 100)}%"></b></div><span class="mute">${this._ago(cb.t, now)}</span></div>`
        : '<div class="case mute">Case battery not reported yet.</div>';
      return `<section><header><h3>Battery</h3></header>${stats}${chart}${caseRow}</section>`;
    }

    _bridge(d, now) {
      const b = d.bridge, links = (b.links || []).filter((e) => e && isNum(e.t)).slice(-36);
      const conns = links.filter((e) => e.event === 'connect' && isNum(e.rssi)), drops = links.filter((e) => e.event === 'drop');
      const med = conns.length ? conns.map((e) => e.rssi).sort((a, c) => a - c)[Math.floor(conns.length / 2)] : null;
      const heldAvg = drops.length ? drops.reduce((s, e) => s + (e.held_s || 0), 0) / drops.length : null;
      const q = med == null ? '' : med > -75 ? 'strong' : med > -90 ? 'fair' : 'weak';
      let strip = '<div class="empty-note">No link events recorded yet.</div>';
      if (links.length) {
        const W = 340, H = 84, base = 46, bw = W / links.length;
        strip = links.map((e, i) => {
          const x = i * bw + bw * .15, w = bw * .7;
          if (e.event === 'connect') {
            const h = 4 + clamp(((e.rssi ?? -110) + 110) / 50, 0, 1) * (base - 8);
            const cls = e.rssi > -75 ? '' : e.rssi > -90 ? 'mid' : 'low';
            return `<rect class="rbar ${cls}" x="${x}" y="${base - h}" width="${w}" height="${h}" rx="1.5"/>`;
          }
          const h = 4 + clamp((e.held_s || 0) / 80, 0, 1) * 20;
          return `<rect class="dbar" x="${x}" y="${base + 3}" width="${w}" height="${h}" rx="1.5"/>`;
        }).join('');
        strip = `<div class="links"><svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Last ${links.length} Bluetooth link events: ${conns.length} connects${med != null ? `, median signal ${med} dBm` : ''}, ${drops.length} drops."><line class="grid" x1="0" x2="${W}" y1="${base + .5}" y2="${base + .5}"/>${strip}
          <text x="0" y="${H - 6}">drops (height = seconds held)</text></svg></div>
          <div class="legend"><span>Bars up: connects, taller = stronger signal</span><span>${esc(this._ago(links[0].t, now).replace(' ago', ''))} of history</span></div>`;
      }
      return `<section><header><h3>Bridge health</h3><span class="hint">${q ? `${q} link · median ${med} dBm` : ''}</span></header>
        <dl class="kv"><dt>Firmware</dt><dd>${esc(b.firmware || 'unknown')}</dd>
        <dt>Last frame</dt><dd>${b.last_frame ? this._ago(b.last_frame, now) : 'never'}</dd>
        <dt>Last full sync</dt><dd>${b.last_full_sync ? `${this._clock(b.last_full_sync, d.tz, true)} · ${this._ago(b.last_full_sync, now)}` : 'never'}</dd>
        <dt>Recent drops</dt><dd>${links.length ? `${drops.length} of ${links.length} events${heldAvg != null ? ` · held ${nf(heldAvg)} s avg` : ''}` : '–'}</dd></dl>${strip}</section>`;
    }

    /* ---------- render ---------- */
    _scheme() {
      const p = document.createElement('div');
      p.style.cssText = 'position:absolute;visibility:hidden;background:var(--card-background-color,#f4f1ea)';
      this.shadowRoot.appendChild(p);
      const m = getComputedStyle(p).backgroundColor.match(/[\d.]+/g) || [244, 241, 234];
      p.remove();
      return (0.299 * m[0] + 0.587 * m[1] + 0.114 * m[2]) < 128 ? 'dark' : 'light';
    }

    _render() {
      if (!this._cfg || !this.shadowRoot) return;
      const root = this.shadowRoot;
      const active = root.activeElement?.dataset?.fid;
      const scheme = this._scheme();
      if (!this._hass) { root.innerHTML = `<style>${STYLE}</style><div class="card" data-scheme="${scheme}"><div class="empty-note">Connecting to Home Assistant…</div></div>`; return; }
      const d = this._data(), now = this._now();
      let html;
      if (!d.have) {
        html = `<div class="hero"><div class="hero-top"><span class="eyebrow">${esc(this._cfg.title)}</span></div><div class="where"><h2>No data yet</h2><p>The entity <b>${esc(this._cfg.dashboard_entity)}</b> is missing or unavailable. Check that the OpenCircuit bridge is online and the package is loaded.</p></div></div>`;
      } else {
        html = `${this._hero(d, now)}<div class="main"><div class="col">${this._vitals(d, now)}${this._timeline(d, now)}</div>
          <div class="col">${this._activity(d)}${this._battery(d, now)}${this._cfg.show_bridge !== false ? this._bridge(d, now) : ''}</div></div>
          <p class="foot">Source: ${esc(this._cfg.dashboard_entity)}</p>`;
      }
      root.innerHTML = `<style>${STYLE}</style><div class="card" data-scheme="${scheme}">${html}</div>`;
      this._bind();
      if (active) root.querySelector(`[data-fid="${active}"]`)?.focus({ preventScroll: true });
    }

    _bind() {
      const root = this.shadowRoot;
      const tabs = [...root.querySelectorAll('.tab')];
      const pick = (k) => { this._tab = k; this._render(); };
      tabs.forEach((b, i) => {
        b.addEventListener('click', () => pick(b.dataset.tab));
        b.addEventListener('keydown', (e) => {
          const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
          if (e.key === 'Home' || e.key === 'End' || step) {
            e.preventDefault();
            const j = e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : (i + step + tabs.length) % tabs.length;
            this._tab = tabs[j].dataset.tab; this._render();
            this.shadowRoot.querySelector(`[data-fid="tab-${this._tab}"]`)?.focus();
          } else if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); pick(b.dataset.tab); }
        });
      });
      const wrap = root.querySelector('.chartwrap'), tl = this._tl;
      if (!wrap || !tl || !tl.X) return;
      const cur = root.getElementById ? root.querySelector('#cur') : null, ro = root.querySelector('#readout'), m = METRICS[tl.tab];
      const show = (i) => {
        const p = tl.pts[i]; if (!p || !cur) return;
        const x = tl.X(p.t);
        cur.setAttribute('x1', x); cur.setAttribute('x2', x); cur.setAttribute('visibility', 'visible');
        ro.innerHTML = m.bars
          ? `<b class="num">${nf(p.avg)}</b> steps · ${this._clock(p.t, tl.d.tz)}–${this._clock(p.t + 900, tl.d.tz)}`
          : `<b class="num">${nf(p.avg, m.dec)}</b> ${m.unit} avg · range ${nf(p.min, m.dec)}–${nf(p.max, m.dec)} · ${this._clock(p.t, tl.d.tz)}`;
        this._idx = i;
      };
      const hide = () => { cur?.setAttribute('visibility', 'hidden'); ro.innerHTML = tl.summary; this._idx = null; };
      const near = (e) => {
        const r = wrap.getBoundingClientRect(), x = ((e.clientX - r.left) / r.width) * tl.W;
        let best = 0, bd = Infinity;
        tl.pts.forEach((p, i) => { const dd = Math.abs(tl.X(p.t) - x); if (dd < bd) { bd = dd; best = i; } });
        return best;
      };
      wrap.addEventListener('pointermove', (e) => show(near(e)));
      wrap.addEventListener('pointerdown', (e) => show(near(e)));
      wrap.addEventListener('pointerleave', () => { if (root.activeElement !== wrap) hide(); });
      wrap.addEventListener('blur', hide);
      wrap.addEventListener('keydown', (e) => {
        const n = tl.pts.length; let i = this._idx;
        if (e.key === 'ArrowRight') i = i == null ? 0 : Math.min(n - 1, i + 1);
        else if (e.key === 'ArrowLeft') i = i == null ? n - 1 : Math.max(0, i - 1);
        else if (e.key === 'Home') i = 0; else if (e.key === 'End') i = n - 1;
        else if (e.key === 'Escape') { hide(); return; } else return;
        e.preventDefault(); show(i);
      });
    }
  }

  customElements.define('ringconn-card', RingConnCard);
  window.customCards = window.customCards || [];
  window.customCards.push({
    type: 'ringconn-card',
    name: 'RingConn Gen 2',
    description: 'Ring location, battery, vitals, 24 h timeline, 14-day trends and bridge health.',
    preview: false,
  });
})();
