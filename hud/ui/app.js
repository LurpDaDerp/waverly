import { Ambient, applyTheme, phaseAt, sunTimes, weatherState } from "./sky.js";
import { openAnimation, closeAnimation, OPEN_TYPES, CLOSE_TYPES } from "./anim.js";

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const DEBUG = params.has("debug");
const DEMO = params.has("demo");
// macOS overlay mode (?mac=1): the HUD appears over the desktop instead of on a
// dedicated screen. The sky layer's opacity plays the role of the black curtain,
// trackpad scrolling drives the lists, and Esc closes the HUD.
const MAC = params.has("mac");
if (MAC) { document.documentElement.classList.add("mac"); document.body.classList.add("mac"); }
function setFaded(faded) {
  if (MAC) $("sky").style.opacity = faded ? 0 : 1;
  else $("curtain").style.opacity = faded ? 1 : 0;
}

const S = {
  data: null,
  phase: "asleep", // asleep | entering | awake | leaving
  anims: [],
  lastRender: {},
};

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const fmtTime = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" });
const fmtHour = new Intl.DateTimeFormat("en-US", { hour: "numeric" });
const fmtDate = new Intl.DateTimeFormat("en-US", { weekday: "long", month: "long", day: "numeric" });
const fmtShort = new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric" });
const fmtMD = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric" });
const pad2 = (n) => String(n).padStart(2, "0");
const dayKey = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const daysBetween = (a, b) => Math.round((startOfDay(b) - startOfDay(a)) / 864e5);
// 12-hour ("9:05 AM") or 24-hour ("09:05") clock, from the config
const H24 = () => S.data?.config?.clock === "24h";
const hhmm = (d) => `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
const timeParts = (d) => {
  if (H24()) return { t: hhmm(d), ap: "" };
  const [t, ap] = fmtTime.format(d).split(/\s/);
  return { t, ap };
};
const timeHTML = (d) => { const { t, ap } = timeParts(d); return ap ? `${t}<small>${ap}</small>` : t; };
const plain = (d) => (H24() ? hhmm(d) : fmtTime.format(d));
const shortRange = (a, b) => `${timeParts(a).t}–${plain(b)}`;
const hourLabel = (d) => (H24() ? `${pad2(d.getHours())}:00` : fmtHour.format(d).replace(" ", " "));

// Appearance and gesture settings from the config (validated by hud-core; checked again
// here so a missing or odd value always means the default).
const PREFS = {
  theme: ["adaptive", "light", "dark"],
  weather_detail: ["high", "medium", "low"],
  parallax: true,
  weather_animation: true,
  scroll_reverse_vertical: false,
  scroll_reverse_horizontal: false,
  open_animation: OPEN_TYPES, // fade | zoom | shatter | slide | swirl (anim.js); "fade" first = the default
  close_animation: CLOSE_TYPES,
};
function pref(key) {
  const v = S.data?.config?.[key], spec = PREFS[key];
  if (Array.isArray(spec)) return spec.includes(v) ? v : spec[0];
  return typeof v === "boolean" ? v : spec;
}
// Hand-scrolling speed per axis: a multiple of the standard speed, 0.5-2 (common.SCROLL_SPEED_RANGE).
function scrollSpeed(axis) {
  const v = S.data?.config?.[axis === "y" ? "scroll_speed_vertical" : "scroll_speed_horizontal"];
  return typeof v === "number" && Number.isFinite(v) ? Math.min(2, Math.max(0.5, v)) : 1;
}
// Open / close animation lengths in seconds, 0 = instant: [minimum, maximum, default].
// The same rules as hud-core (common.animation_seconds): below the minimum is instant.
const ANIM_LENGTH = { open_animation_s: [0.3, 2.0, 1.0], close_animation_s: [0.2, 1.5, 0.75] };
function animSeconds(key) {
  const [lo, hi, def] = ANIM_LENGTH[key], v = S.data?.config?.[key];
  if (typeof v !== "number" || !Number.isFinite(v)) return def;
  return v < lo ? 0 : Math.min(v, hi);
}

// colour classes (.c-<id> in style.css); an unknown id falls back to slate
const PALETTE = new Set(["blue", "amber", "teal", "rose", "violet", "green", "gold", "coral", "cyan", "slate"]);
const colorClass = (tag) => `c-${PALETTE.has(tag?.color) ? tag.color : "slate"}`;
const pill = (tag) => (tag?.label ? `<span class="tag ${colorClass(tag)}">${esc(tag.label)}</span>` : "");

// ---------------------------------------------------------------- icons
const CLOUD = "M7.2 18.6h9.9a4.1 4.1 0 0 0 .5-8.17 5.6 5.6 0 0 0-10.9 1.3A3.45 3.45 0 0 0 7.2 18.6z";
const CLOUD_UP = "M7.2 14.6h9.9a4.1 4.1 0 0 0 .5-8.17 5.6 5.6 0 0 0-10.9 1.3A3.45 3.45 0 0 0 7.2 14.6z";
const SUN_RAYS = (cx, cy, r1, r2) => Array.from({ length: 8 }, (_, i) => {
  const a = (i * Math.PI) / 4;
  return `M${(cx + Math.cos(a) * r1).toFixed(2)} ${(cy + Math.sin(a) * r1).toFixed(2)}L${(cx + Math.cos(a) * r2).toFixed(2)} ${(cy + Math.sin(a) * r2).toFixed(2)}`;
}).join("");
const MOON = (cx, cy, r) => `M${cx + r * 0.25} ${cy - r}a${r} ${r} 0 1 0 ${r * 0.75} ${r * 1.55}A${r * 0.82} ${r * 0.82} 0 0 1 ${cx + r * 0.25} ${cy - r}z`;
const SMALL_CLOUD = "M9.2 20.4h8.6a3.6 3.6 0 0 0 .45-7.17 4.9 4.9 0 0 0-9.5 1.15A3 3 0 0 0 9.2 20.4z";
// hides the sun or moon behind the cloud (with a small gap) so the outlines never cross
const PART_MASK = `<mask id="hud-part" maskUnits="userSpaceOnUse" x="-4" y="-4" width="32" height="32"><rect x="-4" y="-4" width="32" height="32" fill="#fff"/><path d="${SMALL_CLOUD}" fill="#000" stroke="#000" stroke-width="3.6"/></mask>`;
const ICONS = {
  sun: `<circle cx="12" cy="12" r="4.2"/><path d="${SUN_RAYS(12, 12, 7, 9.6)}"/>`,
  moon: `<path d="${MOON(11, 12, 7)}"/>`,
  partly: `<defs>${PART_MASK}</defs><g mask="url(#hud-part)"><circle cx="9" cy="8.6" r="3.3"/><path d="${SUN_RAYS(9, 8.6, 5.3, 7.1)}"/></g><path d="${SMALL_CLOUD}"/>`,
  partlyNight: `<defs>${PART_MASK}</defs><g mask="url(#hud-part)"><path d="${MOON(8.4, 8.8, 4.6)}"/></g><path d="${SMALL_CLOUD}"/>`,
  cloud: `<path d="${CLOUD}"/>`,
  fog: `<path d="${CLOUD_UP}"/><path d="M4.5 18h15M6.5 21h11"/>`,
  drizzle: `<path d="${CLOUD_UP}"/><path d="M9 17.6l-.4 1.2M13 17.6l-.4 1.2M17 17.6l-.4 1.2M11 20.6l-.4 1.2M15 20.6l-.4 1.2"/>`,
  rain: `<path d="${CLOUD_UP}"/><path d="M8.6 17.4l-1.2 3.6M12.6 17.4l-1.2 3.6M16.6 17.4l-1.2 3.6"/>`,
  snow: `<path d="${CLOUD_UP}"/><circle class="fill" cx="8.4" cy="18.4" r=".95"/><circle class="fill" cx="12.4" cy="20.4" r=".95"/><circle class="fill" cx="16.4" cy="18.4" r=".95"/><circle class="fill" cx="10.4" cy="22" r=".95"/><circle class="fill" cx="14.4" cy="22.6" r=".95"/>`,
  storm: `<path d="${CLOUD_UP}"/><path d="M12.6 15.2l-2.4 3.6h3.4l-2.2 3.8"/>`,
  sunrise: `<path d="M5 18.5a7 7 0 0 1 14 0"/><path d="M2.5 21.5h19"/><path d="M12 3.2v6.4M9.2 6.2L12 3.2l2.8 3"/>`,
  sunset: `<path d="M5 18.5a7 7 0 0 1 14 0"/><path d="M2.5 21.5h19"/><path d="M12 9.6V3.2M9.2 6.6L12 9.6l2.8-3"/>`,
};
const icon = (name) => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ICONS.cloud}</svg>`;

function wmo(code, isDay) {
  const c = code;
  if (c === 0) return [isDay ? "sun" : "moon", "Clear"];
  if (c === 1) return [isDay ? "sun" : "moon", "Mostly clear"];
  if (c === 2) return [isDay ? "partly" : "partlyNight", "Partly cloudy"];
  if (c === 3) return ["cloud", "Overcast"];
  if (c === 45 || c === 48) return ["fog", "Fog"];
  if (c >= 51 && c <= 55) return ["drizzle", c === 55 ? "Heavy drizzle" : "Drizzle"];
  if (c === 56 || c === 57) return ["drizzle", "Freezing drizzle"];
  if (c === 61) return ["rain", "Light rain"];
  if (c === 63) return ["rain", "Rain"];
  if (c === 65) return ["rain", "Heavy rain"];
  if (c === 66 || c === 67) return ["rain", "Freezing rain"];
  if (c === 71) return ["snow", "Light snow"];
  if (c === 73) return ["snow", "Snow"];
  if (c === 75) return ["snow", "Heavy snow"];
  if (c === 77) return ["snow", "Snow grains"];
  if (c === 80) return ["rain", "Light showers"];
  if (c === 81) return ["rain", "Showers"];
  if (c === 82) return ["rain", "Heavy showers"];
  if (c === 85 || c === 86) return ["snow", "Snow showers"];
  if (c >= 95) return ["storm", "Thunderstorm"];
  return ["cloud", "Cloudy"];
}

// ---------------------------------------------------------------- scrolling
class Scroller {
  // The list follows the hand: a hand stroke moves the list the same way, and
  // one comfortable stroke (about 45% of the camera's view) spans the whole list.
  constructor(name, vp, track, axis) {
    Object.assign(this, { name, vp, track, axis });
    this.off = 0; this.target = 0; this.vel = 0;
    this.lastInput = -1e9; this.auto = 0; this.applied = null;
    this.shift = this.gone = this.above = 0; // collapses under way (see collapseRows)
    this.card = vp.closest(".card");
  }
  get size() { return this.axis === "y" ? this.vp.clientHeight : this.vp.clientWidth; }
  get max() {
    return this.axis === "y"
      ? Math.max(0, this.track.scrollHeight - this.vp.clientHeight)
      : Math.max(0, this.track.scrollWidth - this.vp.clientWidth);
  }
  setAuto(px, immediate) {
    this.auto = Math.max(0, Math.min(this.max, px));
    if (immediate) { this.off = this.target = this.auto; this.vel = 0; this.apply(true); }
    kick();
  }
  scrollPx(px, now) {
    // trackpad (macOS): follow the fingers 1:1; the OS already adds momentum.
    // Never reversed here: WebKit already applies the system's scroll direction.
    this.target = Math.max(0, Math.min(this.max, this.target + px));
    this.off = this.target; this.vel = 0; this.lastInput = now;
    this.apply();
    this.input();
  }
  move(d, now) {
    // d: hand movement in camera-frame units (+ = down / right); the list follows
    // the hand unless the reverse setting for this axis is on (hand gestures only)
    if (pref(this.axis === "y" ? "scroll_reverse_vertical" : "scroll_reverse_horizontal")) d = -d;
    // a typical stroke (~45% of the camera view) moves about 2.5 screenfuls,
    // and proportionally less for short lists; times the speed setting for this axis
    const gain = Math.min(this.max / 0.235, this.size * 2.8) * scrollSpeed(this.axis);
    if (now - this.lastInput > 400) this.target = this.off; // new stroke starts where the list is
    this.target = Math.max(0, Math.min(this.max, this.target + d * gain));
    this.lastInput = now;
    this.input();
  }
  input() {
    // the frame loop sleeps when nothing moves: wake it now, and again when the
    // list is due to drift back to "now"
    kick();
    clearTimeout(this.homeTimer);
    this.homeTimer = setTimeout(kick, 12050);
  }
  tick(dt, now) {
    const max = this.max;
    if (now - this.lastInput > 12000) this.target = this.auto; // drift back to "now" when left alone
    this.target = Math.max(0, Math.min(max, this.target));
    // critically damped spring toward the hand-driven target: continuous,
    // overshoot-free motion at 60 fps between 30 Hz camera samples
    const w = now - this.lastInput > 12000 ? 6 : 16; // rad/s; slower when drifting home
    const steps = Math.max(1, Math.ceil(dt / 0.008));
    const h = dt / steps;
    for (let i = 0; i < steps; i++) {
      const acc = w * w * (this.target - this.off) - 2 * w * this.vel;
      this.vel += acc * h;
      this.off += this.vel * h;
    }
    if (Math.abs(this.target - this.off) < 0.05 && Math.abs(this.vel) < 1) { this.off = this.target; this.vel = 0; }
    this.apply();
    return this.off !== this.target; // still moving
  }
  apply(force) {
    const v = Math.round(this.off * 100) / 100;
    if (!force && v === this.applied) return;
    this.applied = v;
    this.track.style.transform = this.axis === "y" ? `translate3d(0,${-v}px,0)` : `translate3d(${-v}px,0,0)`;
  }
}

const scrollers = {};
function setupScrollers() {
  scrollers.schedule = new Scroller("schedule", $("schedule-vp"), $("schedule"), "y");
  scrollers.deadlines = new Scroller("deadlines", $("deadlines-vp"), $("deadlines"), "y");
  scrollers.weather = new Scroller("weather", $("hourly-vp"), $("hourly"), "x");
}

let engagedName = null, releaseTimer = 0;
function onScroll(m) {
  if (S.phase !== "awake") return;
  const s = scrollers[m.target];
  if (!s) return;
  if (m.kind === "move") { s.move(m.d, performance.now()); setEngaged(s); }
  else if (m.kind === "end") {
    clearTimeout(releaseTimer);
    releaseTimer = setTimeout(() => setEngaged(null), 450);
  }
}
function setEngaged(s) {
  clearTimeout(releaseTimer);
  if (engagedName === (s && s.name)) return;
  for (const o of Object.values(scrollers)) o.card.classList.toggle("engaged", o === s);
  engagedName = s && s.name;
}

// ---------------------------------------------------------------- head parallax
// The tiles lean slightly toward your head and the sky shifts the other way,
// so the dashboard reads as a layer floating in front of the sky.
// Targets are set only when a head reading arrives (15 Hz) and has moved enough to
// see; CSS transitions animate between them on the compositor, so the page itself
// does no per-frame work and a resting head costs nothing (detector jitter stays
// under the dead band, so nothing is written and the cards' backdrops stay put).
// The parallax setting turns all of it off: the cards stay flat and the sky still.
const head = { x: 0, y: 0, cx: null, cy: null, ax: 9, ay: 9, idle: 0 };
const PARALLAX_DEADBAND = 0.05;
let parallaxEls = null, parallaxOn = true;
function onHead(m) {
  if (S.phase !== "awake" || skyHalf || !parallaxOn) return;
  // where you usually sit becomes "straight on"; drifts over ~20 s
  const hx = (m.x - 0.5) + 0.35 * m.yaw, hy = (m.y - 0.5) + 0.25 * (m.pitch - 0.6);
  if (head.cx === null) { head.cx = hx; head.cy = hy; }
  head.cx += (hx - head.cx) * 0.004;
  head.cy += (hy - head.cy) * 0.004;
  const tx = Math.max(-1, Math.min(1, (hx - head.cx) / 0.22));
  const ty = Math.max(-1, Math.min(1, (hy - head.cy) / 0.18));
  head.x += (tx - head.x) * 0.3; // smooths detector jitter; real movement still follows within ~0.2 s
  head.y += (ty - head.y) * 0.3;
  applyParallax(head.x, head.y);
  clearTimeout(head.idle);
  head.idle = setTimeout(() => { head.x = head.y = 0; applyParallax(0, 0); }, 1500); // nobody in view: settle flat
}
function applyParallax(x, y) {
  // the dead band (0.05: about 0.2 deg of tilt, 0.1 rem of sky) is too small to see, and the
  // transitions smooth the steps; every write would restart them and re-blur every backdrop
  if (Math.abs(x - head.ax) < PARALLAX_DEADBAND && Math.abs(y - head.ay) < PARALLAX_DEADBAND) return;
  head.ax = x; head.ay = y;
  parallaxEls ??= { sky: $("sky"), cards: [...document.querySelectorAll("#stage .card")] };
  const mag = Math.hypot(x, y);
  const rot = mag < 1e-4 ? "0 1 0 0deg" : `${(-y / mag).toFixed(4)} ${(x / mag).toFixed(4)} 0 ${(mag * 4.5).toFixed(3)}deg`;
  const shift = `${(-x * 0.5).toFixed(3)}rem ${(-y * 0.35).toFixed(3)}rem`;
  for (const c of parallaxEls.cards) { c.style.rotate = rot; c.style.translate = shift; }
  parallaxEls.sky.style.translate = `${(x * 2.0).toFixed(3)}rem ${(y * 1.4).toFixed(3)}rem`; // sky overhangs 3rem
}
function setParallax(on) {
  if (on === parallaxOn) return;
  parallaxOn = on;
  if (on) return; // the next head reading tilts the cards again
  clearTimeout(head.idle);
  head.x = head.y = 0;
  head.ax = head.ay = 9;
  // ease back to flat (the CSS transitions run to "none"), then no inline styles at all
  parallaxEls ??= { sky: $("sky"), cards: [...document.querySelectorAll("#stage .card")] };
  for (const c of parallaxEls.cards) { c.style.rotate = ""; c.style.translate = ""; }
  parallaxEls.sky.style.translate = "";
}

// ---------------------------------------------------------------- render: greeting + clock
function greeting(h) {
  const name = String(S.data?.config?.name ?? "").trim();
  const to = name ? `, ${name}` : "";
  if (h < 5) return `Up late${to}`;
  if (h < 12) return `Good morning${to}`;
  if (h < 17) return `Good afternoon${to}`;
  return `Good evening${to}`;
}
let lastClock = "";
function renderClock(now = new Date()) {
  const h = now.getHours(), h24 = H24();
  const hm = h24 ? hhmm(now) : `${h % 12 || 12}:${pad2(now.getMinutes())}`;
  const sec = pad2(now.getSeconds());
  const hello = greeting(h);
  const key = `${hm}|${hello}|${h24}`;
  if (key !== lastClock) {
    lastClock = key;
    $("hm").textContent = hm;
    $("ampm").textContent = h24 ? "" : h < 12 ? "AM" : "PM";
    $("date").textContent = fmtDate.format(now);
    const el = $("hello");
    el.textContent = hello;
    // a long name: shrink the greeting to fit its card (at most to half size; beyond that it ends in "…")
    el.style.fontSize = "";
    if (el.scrollWidth > el.clientWidth + 1) {
      const cs = getComputedStyle(el), pad = parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight);
      const fit = (el.clientWidth - pad) / (el.scrollWidth - pad);
      el.style.fontSize = `${6.6 * Math.max(0.5, fit) * 0.99}rem`;
    }
  }
  $("sec").textContent = sec;
}

// ---------------------------------------------------------------- render: schedule
// card titles from the config ("" or missing = the default)
function renderTitles() {
  const t = S.data?.config?.titles || {};
  $("left-title").textContent = String(t.left ?? "").trim() || "Calendars";
  $("right-title").textContent = String(t.right ?? "").trim() || "Tasks";
}

const CONNECT = `choose <b>Connect Google Calendar…</b> from the Waverly menu bar icon`;
function googleEmpty(kind) {
  const g = S.data?.google || {};
  if (g.state === "setup") {
    return kind === "schedule"
      ? `<div class="empty"><h3>Connect Google Calendar</h3><p>To show your events and tasks here, ${CONNECT}.</p></div>`
      : `<div class="empty"><h3>Nothing here yet</h3><p>Upcoming tasks and events appear here once Google Calendar is connected.</p></div>`;
  }
  if (g.state === "auth") {
    return `<div class="empty"><h3>Reconnect Google</h3><p>Google stopped accepting the saved sign-in. To reconnect, ${CONNECT}.</p></div>`;
  }
  if (g.state === "error") {
    return `<div class="empty"><h3>Can't reach Google</h3><p>Your events and tasks will appear as soon as the connection is back.</p></div>`;
  }
  return `<div class="empty"><h3>Loading your day</h3><p>Fetching events and tasks from Google.</p></div>`;
}

function renderSchedule() {
  const el = $("schedule");
  const lists = S.data?.lists;
  const sc = lists?.left;
  const now = new Date();
  if (!sc || lists.date !== dayKey(now) || S.data?.google?.state === "setup") {
    el.innerHTML = googleEmpty("schedule");
    scrollers.schedule.setAuto(0, true);
    return;
  }
  const tasks = (sc.tasks || []).filter(shownTask), events = sc.events || [];
  const parts = [];
  if (tasks.length) {
    parts.push(`<div class="row-group">`);
    for (const t of tasks) {
      const due = t.overdue && t.due ? `<span class="overdue-note">Overdue since ${fmtMD.format(new Date(t.due + "T12:00"))}</span>` : `<span>Due today</span>`;
      const ck = checkParts(t);
      parts.push(`<div class="task${ck.row}" data-rise${ck.key}>${ck.ring || `<span class="ring ${colorClass(t.tag)}"></span>`}<div><div class="t-title">${esc(t.title)}</div>
        <div class="meta">${pill(t.tag)}${due}</div>${ck.note}</div></div>`);
    }
    parts.push(`</div><div class="sep"></div>`);
  }
  const allDay = events.filter((e) => e.allDay);
  const timed = events.filter((e) => !e.allDay);
  for (const e of allDay) {
    parts.push(`<div class="ev" data-rise><div class="ev-time all-day">All day</div><div><div class="ev-title">${esc(e.title)}</div>
      <div class="meta">${pill(e.tag)}</div></div></div>`);
  }
  let nowPlaced = false;
  const nowLine = `<div class="now-line" id="now-line"><span class="now-pill">Now<b>${plain(now)}</b></span></div>`;
  for (const e of timed) {
    const s = new Date(e.start), en = new Date(e.end);
    if (!nowPlaced && s > now) { parts.push(nowLine); nowPlaced = true; }
    const state = en <= now ? "past" : s <= now ? "current" : "";
    let extra = "", left = "";
    if (state === "current") {
      const p = Math.min(1, (now - s) / Math.max(1, en - s));
      const mins = Math.max(1, Math.round((en - now) / 60000));
      left = `<span class="left">${mins >= 60 ? `${Math.floor(mins / 60)} h ${mins % 60} min` : `${mins} min`} left</span>`;
      extra = `<div class="progress" style="--p:${p.toFixed(3)}"><i></i></div>`;
    }
    const loc = e.location ? `<span>${esc(e.location.split(",")[0])}</span>` : "";
    parts.push(`<div class="ev ${state}" ${state === "current" ? 'id="current-ev"' : ""} data-rise><div class="ev-time">${timeHTML(s)}</div><div>
      <div class="ev-title">${esc(e.title)}</div>
      <div class="meta">${pill(e.tag)}${loc}<span>${shortRange(s, en)}</span>${left}</div>${extra}</div></div>`);
  }
  if (!nowPlaced && timed.length) parts.push(nowLine);
  if (!events.length) {
    parts.push(`<div class="empty"><h3>${tasks.length ? "No events today" : "Nothing scheduled today"}</h3><p>${tasks.length ? "Just the tasks above." : "Your calendar is clear."}</p></div>`);
  }
  el.innerHTML = parts.join("");
  // auto position: keep "now" (or the current event) in the middle
  const vp = $("schedule-vp");
  const anchor = $("current-ev") || $("now-line");
  if (anchor) {
    const center = anchor.offsetTop + anchor.offsetHeight / 2;
    scrollers.schedule.setAuto(center - vp.clientHeight / 2, false);
  } else {
    scrollers.schedule.setAuto(0, false);
  }
}

// ---------------------------------------------------------------- render: right list (upcoming)
// An event counts down to its start and shows "Now" while it is on (ended ones are hidden).
const isOn = (start, now) => !!start && new Date(start) <= now;
const isOver = (end, now) => !!end && new Date(end) <= now;
function countdown(dueISO, now, start) {
  if (isOn(start, now)) return { html: "Now", cls: "on" };
  const due = new Date(dueISO);
  const ms = due - now;
  if (ms < 0) {
    // missed: count up how long ago it was due
    const s = Math.floor(-ms / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    const days = Math.floor(s / 86400);
    const up = days >= 1 ? `${days}<small>${days === 1 ? "day" : "days"}</small>` : `${h}:${pad2(m)}:${pad2(x)}`;
    return { html: `<span class="up">${up}</span><span class="od">Overdue</span>`, cls: "over" };
  }
  const days = Math.max(1, daysBetween(now, due));
  if (ms < 864e5) { // under a day left: live timer (also just after midnight)
    const s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return { html: h ? `${h}:${pad2(m)}:${pad2(x)}` : `${m}:${pad2(x)}`, cls: "soon", live: true };
  }
  return { html: `${days}<small>${days === 1 ? "day" : "days"}</small>`, cls: "" };
}

function renderDeadlines() {
  const el = $("deadlines");
  const items = S.data?.lists?.right?.items;
  const counts = S.data?.config?.countdowns !== false;
  el.classList.toggle("no-count", !counts);
  el.classList.toggle("checks", canCheck());
  if (!items || S.data?.google?.state === "setup") {
    el.innerHTML = `<li>${googleEmpty("deadlines")}</li>`;
    return;
  }
  const now = new Date();
  const shown = items.filter((d) => !(d.kind === "event" && isOver(d.end, now)) && (d.kind === "event" || shownTask(d)));
  if (!shown.length) {
    el.innerHTML = `<li class="empty"><h3>Nothing coming up</h3><p>Upcoming tasks and events show up here. Choose what this list shows in Waverly Settings.</p></li>`;
    return;
  }
  el.innerHTML = shown.map((d) => {
    const cc = colorClass(d.tag);
    const ev = d.kind === "event";
    const start = ev ? d.start || d.due : null;
    const on = ev && isOn(start, now);
    const meta = [pill(d.tag)];
    if (d.due) {
      const due = new Date(d.due);
      meta.push(`<span>${d.allDay ? fmtShort.format(due) : `${fmtShort.format(due)}, ${plain(due)}`}</span>`);
    }
    // without the countdown column, the meta line carries what it would have said
    if (!counts && on) meta.push(`<span class="on-note">Now</span>`);
    else if (!counts && !ev && d.due && (d.overdue || new Date(d.due) < now)) meta.push(`<span class="overdue-note">Overdue</span>`);
    let count = "";
    if (counts && d.due) {
      const c = countdown(d.due, now, start);
      count = `<div class="count ${c.cls}" data-due="${esc(d.due)}"${start ? ` data-start="${esc(start)}"` : ""}>${c.html}</div>`;
    }
    const watch = ev ? ` data-start="${esc(start)}" data-end="${esc(d.end ?? "")}" data-on="${on ? 1 : 0}"` : "";
    const ck = ev ? { row: "", key: "", ring: "", note: "" } : checkParts(d);
    return `<li class="dl${ck.row}" data-rise${watch}${ck.key}>${ck.ring || `<span class="dot ${cc}"></span>`}<div><div class="dl-title">${esc(d.title)}</div>
      <div class="meta">${meta.join("")}</div>${ck.note}</div>${count}</li>`;
  }).join("");
}

function tickCountdowns() {
  const now = new Date();
  for (const el of document.querySelectorAll(".count[data-due]")) {
    const c = countdown(el.dataset.due, now, el.dataset.start);
    if (el.innerHTML !== c.html) el.innerHTML = c.html;
    el.className = `count ${c.cls}`;
  }
  // an event started or ended: lay the list out again (no re-fetch needed)
  const changed = [...document.querySelectorAll(".dl[data-start]")].some((li) =>
    isOver(li.dataset.end, now) || isOn(li.dataset.start, now) !== (li.dataset.on === "1"));
  if (changed) { if (S.phase !== "awake") S.dirty = true; else if (collapsing) heldRender = true; else renderDeadlines(); }
}

// ---------------------------------------------------------------- checking off tasks
// On the Mac, while Google allows it (data.google.can_complete), a task's ring is a button.
// A click checks it: the ring fills, the title is struck through and the row dims for UNDO_MS,
// during which a second click undoes it (nothing has been sent yet). Then the row collapses
// away and hud-core marks the task completed at Google ({t: "task-complete", list, task});
// task-done or fresh data without the task confirm it, task-error brings the row back with a
// short note. Closing the HUD (or the page going away) sends the waiting ones at once.
const UNDO_MS = 4000, SENT_MS = 60000, NOTE_MS = 8000;
const checks = new Map(); // "<list> <task>" -> { state: "pending" | "sent", timer }
const notes = new Map();  // "<list> <task>" -> { text, until } (until 0: not seen yet)
const outbox = [];        // task-complete messages waiting for the link to hud-core
let collapsing = 0, heldRender = false;
const goneRows = new WeakMap(); // a collapsing row -> the px it gives up
const taskKey = (t) => `${t.list} ${t.task}`;
const canCheck = () => MAC && S.data?.google?.state === "ok" && S.data?.google?.can_complete === true;
const checkable = (t) => canCheck() && typeof t.list === "string" && typeof t.task === "string";
// a task sent to Google stays off the lists until hud-core answers
const shownTask = (t) => !checkable(t) || checks.get(taskKey(t))?.state !== "sent";
const CHECK_SVG = `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.4 8.3l2.4 2.4 4.9-5.2"/></svg>`;

// What a task row needs: its extra classes, data-key, the ring button and a note (all "" when off).
function checkParts(t) {
  if (!checkable(t)) return { row: "", key: "", ring: "", note: "" };
  const k = taskKey(t), on = checks.get(k)?.state === "pending", n = notes.get(k);
  return {
    row: on ? " has-check checked" : " has-check",
    key: ` data-key="${esc(k)}"`,
    ring: `<button type="button" class="ring check ${colorClass(t.tag)}" aria-pressed="${on}" aria-label="${on ? "Undo" : "Mark done"}: ${esc(t.title)}">${CHECK_SVG}</button>`,
    note: n && (!n.until || n.until > Date.now()) ? `<div class="check-note" role="status">${esc(n.text)}</div>` : "",
  };
}
const rowsOf = (key) => [...document.querySelectorAll("#stage .has-check")].filter((r) => r.dataset.key === key);
const scrollerOf = (el) => Object.values(scrollers).find((s) => s.track === el.closest(".track"));
// A list the user scrolled stays put while one of its tasks is being checked off (instead of
// drifting back to "now" with the row out of sight); a list left alone keeps following "now".
function holdLists(key) {
  const now = performance.now();
  for (const s of new Set(rowsOf(key).map(scrollerOf))) {
    if (s && now - s.lastInput <= 12000) { s.lastInput = now; s.input(); }
  }
}

function toggleCheck(key) {
  const c = checks.get(key);
  if (c?.state === "sent") return;
  if (c) { clearTimeout(c.timer); checks.delete(key); } // undo: nothing was sent
  else checks.set(key, { state: "pending", timer: setTimeout(() => commitCheck(key), UNDO_MS) });
  const on = !c;
  for (const row of rowsOf(key)) {
    row.classList.toggle("checked", on);
    const b = row.querySelector(".check");
    b.setAttribute("aria-pressed", on);
    b.setAttribute("aria-label", b.getAttribute("aria-label").replace(/^[^:]*/, on ? "Undo" : "Mark done"));
    if (notes.delete(key)) row.querySelector(".check-note")?.remove();
  }
}

// The undo window ended (or the HUD is closing: `quiet`, no animation): ask hud-core.
function commitCheck(key, quiet = false) {
  const c = checks.get(key);
  if (!c || c.state !== "pending") return;
  clearTimeout(c.timer);
  c.state = "sent";
  c.timer = setTimeout(() => failCheck(key, "Couldn't reach Google. Try again."), SENT_MS);
  const [list, task] = key.split(" ");
  const m = { t: "task-complete", list, task };
  if (ws && ws.readyState === 1) send(m); else outbox.push(m);
  holdLists(key);
  if (!quiet) collapseRows(key);
}
function flushChecks() {
  for (const [key, c] of checks) if (c.state === "pending") commitCheck(key, true);
}

function failCheck(key, text) {
  const c = checks.get(key);
  if (c) clearTimeout(c.timer);
  checks.delete(key);
  // never sent (the link stayed down): it must not go out later, after the note said it failed
  const i = outbox.findIndex((m) => taskKey(m) === key);
  if (i >= 0) outbox.splice(i, 1);
  notes.set(key, { text, until: 0 });
  redrawLists();
  holdLists(key);
}
// A note is shown for NOTE_MS from when it is first on screen, then fades out.
function armNotes() {
  if (S.phase !== "awake" && S.phase !== "entering") return;
  for (const [key, n] of notes) {
    if (n.until) continue;
    n.until = Date.now() + NOTE_MS;
    setTimeout(() => {
      if (notes.get(key) !== n) return;
      notes.delete(key);
      const els = rowsOf(key).map((r) => r.querySelector(".check-note")).filter(Boolean);
      for (const el of els) el.classList.add("gone");
      setTimeout(() => { if (els.some((el) => el.isConnected)) redrawLists(); }, 400);
    }, NOTE_MS);
  }
}

// Fresh data from hud-core: forget the checks it settled (the task is gone from the lists), and
// any waiting one whose task disappeared meanwhile (completed elsewhere) or can't be sent any more.
function settleChecks() {
  const L = S.data?.lists, keys = new Set();
  for (const t of [...(L?.left?.tasks || []), ...(L?.right?.items || [])]) if (t.kind !== "event" && t.list) keys.add(taskKey(t));
  for (const [key, c] of checks) {
    if (keys.has(key) && (c.state === "sent" || canCheck())) continue;
    clearTimeout(c.timer);
    checks.delete(key);
  }
}

function redrawLists() {
  if (S.phase !== "awake" || collapsing) { heldRender = true; return; } // wake() / the collapse redraws
  renderSchedule();
  renderDeadlines();
  armNotes();
}

// The checked rows of `key` fade and the rest of the list closes the gap (transforms and
// opacity only, so the compositor does it); then the lists are drawn without the task. When
// the list's offset changes with the removal (it keeps "now" centred, or sits at its end), the
// rows above move down by that change and the rows below up by the rest, so nothing moves
// again after the redraw. Overlapping collapses add up (composite "add").
function collapseRows(key) {
  const rows = rowsOf(key);
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!rows.length || S.phase !== "awake" || reduced) return redrawLists();
  collapsing++;
  const runs = [];
  for (const row of rows) {
    // the last task of today's list goes with its group and the divider under it
    let first = row, last = row, gap = 0;
    const group = row.parentElement, track = row.closest(".track"), vp = track.parentElement;
    const others = group.classList.contains("row-group") ? [...group.children].filter((r) => r !== row) : null;
    if (others && others.every((r) => goneRows.has(r))) {
      first = group;
      if (group.nextElementSibling?.classList.contains("sep")) last = group.nextElementSibling;
    } else if (others) {
      gap = parseFloat(getComputedStyle(group).rowGap) || 0;
    }
    const followers = [], before = [];
    for (let el = last; el && el !== track; el = el.parentElement) {
      for (let s = el.nextElementSibling; s; s = s.nextElementSibling) followers.push(s);
    }
    for (let el = first; el && el !== track; el = el.parentElement) {
      for (let s = el.previousElementSibling; s; s = s.previousElementSibling) before.push(s);
    }
    let h = row.getBoundingClientRect().height + gap;
    if (first !== row) { // layout positions (other collapses may be moving these), less what they took
      const next = followers[0];
      h = next ? next.offsetTop - parseFloat(getComputedStyle(next).marginTop) - group.offsetTop : 0;
      for (const r of others) h -= goneRows.get(r);
    }
    goneRows.set(row, h);
    const s = scrollerOf(row), shift = s ? planShift(s, h, followers) : 0;
    // only what can come into view moves; the rest is placed by the redraw
    const box = vp.getBoundingClientRect();
    const fade = { duration: 260, easing: "ease-out", fill: "forwards" };
    for (let el = first; el; el = el === last ? null : el.nextElementSibling) {
      runs.push(el.animate([{ opacity: 1 }, { opacity: 0 }], fade));
      runs.push(el.animate([{ transform: "none" }, { transform: "scale(.98)" }], { ...fade, composite: "add" }));
    }
    const slide = { duration: 380, delay: 160, easing: "cubic-bezier(.3,.7,.2,1)", fill: "forwards", composite: "add" };
    const move = (els, dy) => {
      if (Math.abs(dy) < 0.5) return;
      for (const el of els) {
        const r = el.getBoundingClientRect();
        if (r.bottom > box.top - Math.max(0, dy) && r.top < box.bottom - Math.min(0, dy)) {
          runs.push(el.animate([{ transform: "none" }, { transform: `translateY(${dy}px)` }], slide));
        }
      }
    };
    move(followers, shift - h);
    move(before, shift);
  }
  Promise.allSettled(runs.map((a) => a.finished)).then(() => {
    collapsing--;
    if (collapsing) return;
    const awake = S.phase === "awake";
    if (heldRender && awake) { heldRender = false; renderAll(); } else redrawLists();
    for (const s of Object.values(scrollers)) {
      // the list's offset takes the change the animation showed (a list left alone then
      // carries on toward "now" from there, normally already there)
      if (awake && s.gone) {
        s.off = Math.max(0, Math.min(s.max, s.off - s.shift));
        s.target = Math.max(0, Math.min(s.max, s.target - s.shift));
        s.apply(true);
        s.input();
      }
      s.shift = s.gone = s.above = 0;
    }
  });
}

// How much list `s`'s offset drops when `h` px leave it, `followers` being what follows them:
// a list the user placed keeps its offset (within its new end); one left alone keeps its anchor
// ("now", in the left list) centred, like renderSchedule. Adds it to the collapses under way.
function planShift(s, h, followers) {
  const gone = s.gone + h, max = Math.max(0, s.max - gone);
  const anchor = s.name === "schedule" ? $("current-ev") || $("now-line") : null;
  const below = !!anchor && followers.includes(anchor);
  let base, next;
  if (performance.now() - s.lastInput <= 12000) {
    base = s.target - s.shift;
    next = base;
  } else {
    base = s.auto - s.shift;
    next = anchor ? anchor.offsetTop + anchor.offsetHeight / 2 - s.vp.clientHeight / 2 - s.above - (below ? h : 0) : 0;
  }
  const shift = base - Math.max(0, Math.min(max, next));
  s.shift += shift;
  s.gone = gone;
  if (below) s.above += h;
  return shift;
}

// ---------------------------------------------------------------- render: weather
function renderWeather() {
  const w = S.data?.weather;
  const cfg = S.data?.config || {};
  const noLoc = cfg.lat == null || cfg.lon == null;
  $("place").textContent = noLoc ? "" : cfg.place || "";
  const now = new Date();
  const sun = sunTimes(now, cfg.lat, cfg.lon);
  const chipsEl = $("wx-chips"), nowEl = $("wx-now"), hourly = $("hourly");
  $("wx-card").classList.toggle("no-loc", noLoc);
  if (noLoc) {
    nowEl.innerHTML = `<div class="empty"><h3>Weather needs your location</h3><p>Turn on Location in Waverly Settings, or enter a city.</p></div>`;
    chipsEl.innerHTML = hourly.innerHTML = "";
    return;
  }
  if (!w || !w.current) {
    nowEl.innerHTML = `<div class="empty" style="grid-column:1/-1;padding:.5rem 0"><h3>Weather unavailable</h3><p>Can't reach Open-Meteo yet. Waverly retries every few minutes while it's on screen.</p></div>`;
    chipsEl.innerHTML = chip("Sunrise", plain(sun.sunrise)) + chip("Sunset", plain(sun.sunset));
    chipsEl.style.gridTemplateColumns = "repeat(2, 1fr)";
    hourly.innerHTML = "";
    return;
  }
  chipsEl.style.gridTemplateColumns = "";
  const cur = w.current, d = w.daily;
  const [ic, label] = wmo(cur.weather_code, cur.is_day);
  const ageH = (Date.now() / 1000 - w.fetched_at) / 3600;
  const stale = ageH > 1 ? `<div class="stale">Updated ${ageH < 2 ? "over an hour" : Math.floor(ageH) + " hours"} ago</div>` : "";
  nowEl.innerHTML = `${icon(ic)}<div class="temp">${Math.round(cur.temperature_2m)}°</div>
    <div><div class="cond">${label}</div><div class="cond-sub"><span>Feels like ${Math.round(cur.apparent_temperature)}°</span>
    <span>High ${Math.round(d.temperature_2m_max[0])}°</span><span>Low ${Math.round(d.temperature_2m_min[0])}°</span></div>${stale}</div>`;

  const hourIdx = w.hourly.time.findIndex((t) => new Date(t) > now) - 1;
  const pop = hourIdx >= 0 ? w.hourly.precipitation_probability[hourIdx] : d.precipitation_probability_max[0];
  const wind = cfg.wind_unit === "kmh" ? "km/h" : "mph";
  chipsEl.innerHTML = chip("Rain chance", `${pop ?? 0}%`) + chip("Wind", `${Math.round(cur.wind_speed_10m)} ${wind}`)
    + chip("Sunrise", plain(sun.sunrise)) + chip("Sunset", plain(sun.sunset));

  // today 12 AM through tomorrow 6 AM, with sunrise and sunset slotted in
  const items = [];
  const end = new Date(startOfDay(now).getTime() + 30 * 3600e3);
  const tomorrow = new Date(now.getTime() + 864e5);
  const sun2 = sunTimes(tomorrow, cfg.lat, cfg.lon);
  const marks = [[sun.sunrise, "sunrise", "Sunrise"], [sun.sunset, "sunset", "Sunset"], [sun2.sunrise, "sunrise", "Sunrise"]];
  w.hourly.time.forEach((t, i) => {
    const at = new Date(t);
    if (at < startOfDay(now) || at > end) return;
    items.push({ at, i });
  });
  for (const [at, ic2, lab] of marks) if (at >= startOfDay(now) && at <= end) items.push({ at, sun: ic2, lab });
  items.sort((a, b) => a.at - b.at);
  hourly.innerHTML = items.map((it) => {
    if (it.sun) {
      return `<div class="hr sun ${it.at < now ? "past" : ""}"><span class="h">${it.lab}</span>${icon(it.sun)}<span class="tv">${timeParts(it.at).t}</span><span class="pop"></span></div>`;
    }
    const i = it.i;
    const isNow = i === hourIdx;
    const [hic] = wmo(w.hourly.weather_code[i], w.hourly.is_day[i]);
    const p = w.hourly.precipitation_probability[i];
    const lab = isNow ? "Now" : hourLabel(it.at);
    return `<div class="hr ${isNow ? "is-now" : it.at < now ? "past" : ""}" ${isNow ? 'id="hr-now"' : ""}><span class="h">${lab}</span>${icon(hic)}
      <span class="tv">${Math.round(w.hourly.temperature_2m[i])}°</span><span class="pop">${p >= 10 ? p + "%" : ""}</span></div>`;
  }).join("");
  const n = $("hr-now"), vp = $("hourly-vp");
  if (n) scrollers.weather.setAuto(n.offsetLeft + n.offsetWidth / 2 - vp.clientWidth / 2, false);
}
const chip = (k, v) => `<div class="chip"><span>${k}</span><b>${v}</b></div>`;

// ---------------------------------------------------------------- render: word + fact
function renderWords() {
  const wd = S.data?.word, f = S.data?.fact;
  $("wotd").innerHTML = `<h2 data-title>Word of the day</h2>` + (wd
    ? `<div class="word">${esc(wd.word)}</div><div class="word-meta">${wd.pos ? `<i>${esc(wd.pos)}</i>` : ""}${wd.pron ? `<span>\\${esc(wd.pron)}\\</span>` : ""}</div>
       <p class="prose">${esc(wd.definition)}</p>`
    : `<p class="prose">Today's word arrives once Merriam-Webster can be reached.</p>`);
  $("fact").innerHTML = `<h2 data-title>Fact of the day</h2>` + (f
    ? `<p class="prose">${esc(f.text)}</p><div class="source">${f.source?.startsWith("Wikipedia") ? "From Wikipedia's Did you know" : ""}</div>`
    : `<p class="prose">Today's fact arrives once the source can be reached.</p>`);
  fitWords();
}
// shrink the reading text a little if a long definition or fact would overflow
function fitWords() {
  const card = document.querySelector(".words");
  const proses = card.querySelectorAll(".prose");
  proses.forEach((p) => (p.style.fontSize = ""));
  if (MAC) return fitWordsMac(card);
  let size = 1.85;
  const over = () => [...card.children].some((c) => c.scrollHeight > c.clientHeight + 1) || card.scrollHeight > card.clientHeight + 1;
  while (over() && size > 1.4) {
    size -= 0.05;
    proses.forEach((p) => (p.style.fontSize = size + "rem"));
  }
}

// macOS: the word + fact card is taller here, so each column's reading text takes
// the largest size that fits its column (bisection between 1.4rem and 2.5rem), with
// the word growing in proportion (4.2rem at 1.85rem text) but never wider than its column.
function fitWordsMac(card) {
  const word = card.querySelector(".word");
  let wordMax = (4.2 * 2.5) / 1.85;
  if (word) {
    // the word's natural width at 4.2rem caps how large it may grow
    word.style.fontSize = "";
    word.style.width = "max-content";
    const natural = word.offsetWidth;
    word.style.width = "";
    if (natural > 0) wordMax = Math.min(wordMax, 4.2 * (word.clientWidth / natural) * 0.98);
  }
  const cols = [...card.children].filter((c) => c.querySelector(".prose"));
  const parts = cols.map((col) => {
    const prose = col.querySelector(".prose"), w = word && col.contains(word) ? word : null;
    return (v) => {
      prose.style.fontSize = v + "rem";
      if (w) w.style.fontSize = Math.min((4.2 * v) / 1.85, wordMax) + "rem";
    };
  });
  parts.forEach((apply) => apply(1.4));                 // the other column never causes an overflow
  cols.forEach((col, i) => {
    const apply = parts[i];
    const over = () => col.scrollHeight > col.clientHeight + 1 || card.scrollHeight > card.clientHeight + 1;
    let lo = 1.4, hi = 2.5;
    apply(hi);
    if (!over()) return;
    apply(lo);
    if (over()) return;                                 // too long even at the smallest size
    while (hi - lo > 0.02) {
      const mid = (lo + hi) / 2;
      apply(mid);
      if (over()) hi = mid; else lo = mid;
    }
    apply(+lo.toFixed(3));
  });
  // measured with a fallback font? fit again once the web fonts are in
  if (document.fonts.status !== "loaded") document.fonts.ready.then(() => fitWordsMac(card));
}

// ---------------------------------------------------------------- theme
const ambient = new Ambient($("ambient"));
function updateTheme() {
  const cfg = S.data?.config || {};
  const now = new Date();
  let phase = phaseAt(now, sunTimes(now, cfg.lat, cfg.lon));
  let wx = weatherState(S.data?.weather);
  if (params.get("phase")) phase = params.get("phase");
  if (params.get("wx")) wx = { kind: params.get("wx"), level: +(params.get("lvl") || 1) };
  applyTheme(phase, wx, pref("theme"));
  ambient.configure({ detail: pref("weather_detail"), animated: pref("weather_animation") });
  ambient.set(phase, wx);
  setParallax(pref("parallax"));
  kick();
}
function updateAvoid() {
  ambient.setAvoid([...document.querySelectorAll("[data-title]")].map((e) => e.getBoundingClientRect()));
  kick(); // a still sky is drawn again if the titles moved
}

function renderAll() {
  renderTitles();
  renderClock();
  renderSchedule();
  renderDeadlines();
  renderWeather();
  renderWords();
  updateTheme();
  armNotes();
  if (S.phase === "awake") requestAnimationFrame(updateAvoid); // never mid-entrance
  kick();
}

// ---------------------------------------------------------------- wake / sleep choreography
// The choreographies live in anim.js, one per open / close animation type (config
// open_animation / close_animation). Each is written for a 1.0 s entrance and a 0.75 s exit
// (the defaults); the open / close animation length settings scale every duration and delay of
// it in proportion; 0 (instant) shows or hides everything at once and never calls anim.js.
// A close during the entrance (or an open during the exit) turns the running animation around
// from where it got to, instead of jumping to the other one's start.
const WAKE_BASE_S = 1.0, SLEEP_BASE_S = 0.75;
const openScale = () => animSeconds("open_animation_s") / WAKE_BASE_S;
const closeScale = () => animSeconds("close_animation_s") / SLEEP_BASE_S;
const cards = () => [...document.querySelectorAll("#stage .card")];
function cancelAnims() { for (const a of S.anims) a.cancel(); S.anims = []; }
// Play the running animations the other way, `speed` times as fast (never slower).
function turnAround(speed) {
  for (const a of S.anims) {
    const back = a.playbackRate > 0; // read first: reverse() changes the rate only on the next frame
    a.reverse();
    if (speed > 1) a.updatePlaybackRate((back ? -1 : 1) * speed);
  }
}

async function wake(animated = true) {
  if (S.phase === "awake" || S.phase === "entering") return;
  const k = openScale();
  if (S.phase === "leaving" && animated && k > 0 && S.anims.length) {
    S.phase = "entering"; // reopened while still closing: the close plays backwards
    turnAround(closeScale() / k);
    return entered();
  }
  cancelAnims();
  S.phase = "entering";
  await document.fonts.ready;
  if (S.phase !== "entering") return; // closed while the fonts were loading: that close owns the HUD
  document.body.classList.remove("asleep");
  // The theme cross-fades over 3 s only while the HUD is on screen: a phase or weather change
  // while it was closed (or the first open's night defaults) is applied at once, not faded
  // through mid-grey text during the entrance. Reading a computed value applies it now.
  document.body.classList.add("snap-theme");
  renderAll();
  getComputedStyle(document.body).getPropertyValue("--ink");
  document.body.classList.remove("snap-theme");
  S.dirty = heldRender = false; // the newest data is on screen (data arriving during the entrance sets it again)
  if (!secondTimer) everySecond(); // both stop while the HUD is closed (a hidden page needs no timers)
  if (!hbTimer) heartbeat();
  for (const s of Object.values(scrollers)) s.setAuto(s.auto, true);
  ambient.start();
  kick();
  if (!animated || k === 0) {
    setFaded(false);
    S.phase = "awake";
    requestAnimationFrame(updateAvoid);
    return;
  }
  openAnimation(pref("open_animation"), animCtx(k)); // creates every animation synchronously, in S.anims
  return entered();
}

// The entrance has played (forwards, or a close played backwards): the HUD is fully shown.
async function entered() {
  await Promise.allSettled(S.anims.map((a) => a.finished));
  if (S.phase !== "entering") return;
  setFaded(false);
  cancelAnims();
  S.phase = "awake";
  if (S.dirty || heldRender) { S.dirty = heldRender = false; renderAll(); }
  requestAnimationFrame(updateAvoid);
}

async function sleep(instant = false) {
  if (S.phase === "asleep" || S.phase === "leaving") return;
  const midEntrance = S.phase === "entering" && S.anims.length > 0;
  S.phase = "leaving";
  setEngaged(null);
  flushChecks(); // nothing checked off is lost: sent now, not at the end of the undo window
  const done = () => {
    setFaded(true);
    document.body.classList.add("asleep");
    ambient.stop();
    cancelAnims();
    S.phase = "asleep";
    send({ t: "slept" });
  };
  const k = closeScale();
  if (instant || k === 0) return done();
  if (midEntrance) {
    turnAround(openScale() / k); // the entrance plays backwards from where it got to
  } else {
    cancelAnims();
    closeAnimation(pref("close_animation"), animCtx(k));
  }
  await Promise.allSettled(S.anims.map((a) => a.finished));
  if (S.phase === "leaving") done();
}

// What anim.js needs. A registers every animation in S.anims, so entered() / sleep() wait for
// them and cancelAnims() / turnAround() reach them.
function animCtx(scale) {
  return {
    stage: $("stage"), sky: $("sky"), cards: cards(), mac: MAC, scale,
    A: (el, kf, opt) => { const a = el.animate(kf, opt); S.anims.push(a); return a; },
    reducedMotion: matchMedia("(prefers-reduced-motion: reduce)").matches,
  };
}

// ---------------------------------------------------------------- main loop
// Runs on every display frame only while something moves: the wake / sleep choreography,
// a list easing toward its target, or the animated sky. Otherwise it sleeps (a still HUD,
// e.g. low detail or no weather animation, then costs nothing per frame) and kick()
// wakes it: scroll input, new data, a settings change, wake.
let lastSky = 0, skyHalf = false, skyHalfAt = 0, winN = 0, winLong = 0, winStart = 0, badWindows = 0;
let lastFrame = performance.now(), fpsN = 0, fpsT = performance.now(), fps = null, rafId = 0;
function kick() {
  if (rafId || S.phase === "asleep") return;
  lastFrame = fpsT = performance.now();
  fpsN = 0;
  rafId = requestAnimationFrame(frame);
}
function frame(now) {
  rafId = 0;
  if (S.phase === "asleep") { fps = null; return; } // wake() kicks it again
  const dt = Math.min(0.05, Math.max(0, now - lastFrame) / 1000);
  lastFrame = now;
  let moving = false;
  for (const s of Object.values(scrollers)) moving = s.tick(dt, now) || moving;
  // The animated sky runs at the full 60 fps (high detail) while it rains or snows, and at
  // about 20 fps when only clouds and stars move (ambient.minFrameMs). Only if frames start
  // running long (the machine is genuinely busy) does it drop to 30 fps, retrying 60 after
  // 30 s. Scrolling and the wake/sleep animations always stay at full rate.
  if (S.phase === "awake") {
    winN++;
    if (dt > 0.021) winLong++;
    if (now - winStart >= 2000) {
      badWindows = winLong / winN > 0.3 ? badWindows + 1 : 0;
      winN = winLong = 0; winStart = now;
      if (!skyHalf && badWindows >= 2) {
        // the machine is struggling: halve the sky rate and pause the parallax
        skyHalf = true; skyHalfAt = now;
        if (parallaxOn) applyParallax(0, 0);
        send({ t: "perf", note: "frames running long: sky 30 fps, parallax paused for 30 s" });
      }
    }
  } else { winN = winLong = badWindows = 0; winStart = now; }
  if (skyHalf && now - skyHalfAt > 30000) { skyHalf = false; badWindows = 0; }
  // Medium weather detail also draws the animated sky at 30 fps (half the canvas and
  // compositing work); a still sky is drawn the moment it changes. So does an open or close
  // animation: the sky is fading and moving then, so its weather at 30 fps looks the same and
  // saves 3-7% of the transition's CPU (held completely still, it would visibly freeze).
  const transition = S.phase === "entering" || S.phase === "leaving";
  const sky = ambient.needsFrame, half = skyHalf || ambient.detail === "medium" || transition;
  if (sky && (!ambient.animated || now - lastSky >= Math.max(ambient.minFrameMs, half ? 31 : 0))) {
    lastSky = now;
    ambient.frame(now);
  }
  // the frame rate (reported in the heartbeat) only means something over a full second of
  // continuous frames; a sleeping loop reports none
  fpsN++;
  if (now - fpsT > 1000) { fps = fpsN; fpsN = 0; fpsT = now; }
  if (moving || ambient.needsFrame || S.phase !== "awake") rafId = requestAnimationFrame(frame);
  else { fps = null; winN = winLong = badWindows = 0; winStart = now; }
}

let secondTimer = 0;
function everySecond() {
  secondTimer = 0;
  if (S.phase === "asleep") return; // wake() starts it again
  const now = new Date();
  renderClock(now);
  tickCountdowns();
  if (now.getSeconds() === 0) {
    // (a task's collapse redraws once it ends)
    if (now.getMinutes() === 0 && now.getHours() === 0) { if (collapsing) heldRender = true; else renderAll(); }
    else { if (collapsing) heldRender = true; else renderSchedule(); renderWeather(); updateTheme(); }
  }
  secondTimer = setTimeout(everySecond, 1000 - (Date.now() % 1000) + 8);
}

// ---------------------------------------------------------------- link to hud-core
let ws = null;
function send(o) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); }
function connect() {
  ws = new WebSocket(`ws://${location.host}/ws${DEBUG ? "?vstat=1" : ""}`); // engine status only for ?debug
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.t === "data") {
      if (DEMO) Object.assign(m, demoData());
      S.data = m;
      settleChecks();
      // during the entrance animation, wait: re-rendering would make content pop in
      // (and during a checked task's collapse, which redraws once it ends)
      if (collapsing) heldRender = true;
      else if (S.phase === "awake" || S.phase === "leaving") renderAll();
      else if (S.phase === "entering") S.dirty = true;
    } else if (m.t === "task-done" || m.t === "task-error") {
      const key = taskKey(m), c = checks.get(key);
      if (c?.state !== "sent") return; // an answer to an attempt the page already gave up on
      if (m.t === "task-error") failCheck(key, String(m.message || "Couldn't reach Google. Try again."));
      else { clearTimeout(c.timer); checks.delete(key); }
    } else if (m.t === "wake") wake(true);
    else if (m.t === "sleep") sleep(false);
    else if (m.t === "state") {
      if (m.awake && S.phase === "asleep") wake(false);
      else if (!m.awake && (S.phase === "awake" || S.phase === "entering")) sleep(true);
    } else if (m.t === "scroll") onScroll(m);
    else if (m.t === "head") onHead(m);
    else if (m.t === "vstat" && DEBUG) {
      $("debug").textContent = `state ${m.state}  cam ${m.camera ? "ok" : "down"}  ${m.fps} fps  luma ${m.luma}${m.dark ? " (dark)" : ""}\nperson ${m.person}  hands ${m.hands}  ui ${fps ?? "-"} fps`;
    }
  };
  // checked off while the link was down (and not given up on meanwhile)
  ws.onopen = () => { for (const m of outbox.splice(0)) if (checks.get(taskKey(m))?.state === "sent") send(m); };
  ws.onclose = () => setTimeout(connect, 1500);
}
// Heartbeat while the HUD is on screen (the app reloads a visible page that stops sending it).
let hbTimer = 0;
function heartbeat() {
  hbTimer = 0;
  if (S.phase === "asleep") return; // wake() starts it again
  send({ t: "hb", fps: S.phase === "awake" ? fps : null });
  hbTimer = setTimeout(heartbeat, 5000);
}
window.addEventListener("error", (e) => send({ t: "error", message: `${e.message} @${e.lineno}` }));
window.addEventListener("unhandledrejection", (e) => send({ t: "error", message: String(e.reason) }));

// ---------------------------------------------------------------- demo data (preview only, ?demo=1)
function demoData() {
  const now = new Date(), y = now.getFullYear(), mo = now.getMonth(), d = now.getDate();
  const at = (h, m, n = 0) => new Date(y, mo, d + n, h, m).toISOString();   // n days from today
  const eod = (n) => new Date(y, mo, d + n, 23, 59, 59).toISOString();
  const work = { label: "Work", color: "teal" };            // a category covering several calendars
  const personal = { label: "Personal", color: "amber" };
  const family = { label: "Family", color: "rose" };
  const mine = { label: "My Tasks", color: "blue" };
  const errands = { label: "Errands", color: "amber" };
  const ev = (id, title, tag, start, end, location = "") => ({ id, title, start, end, allDay: false, location, tag });
  const task = (id, title, tag, n) => ({ id, kind: "task", title, due: eod(n), allDay: true, overdue: n < 0, tag });
  const upcoming = (id, title, tag, start, end) => ({ id, kind: "event", title, due: start, start, end, allDay: false, tag });
  const allDay = (id, title, tag, n) => ({ id, kind: "event", title, due: eod(n), start: at(0, 0, n), end: at(0, 0, n + 1), allDay: true, tag });
  const undated = (id, title, tag) => ({ id, kind: "task", title, due: null, allDay: true, overdue: false, tag });
  return {
    google: { state: "ok" },
    lists: {
      date: dayKey(now),
      left: {
        tasks: [
          { id: "t2", title: "Return library books", due: dayKey(new Date(y, mo, d - 2)), overdue: true, tag: mine },
          { id: "t1", title: "Send the weekly project update", due: dayKey(now), overdue: false, tag: work },
        ],
        events: [
          { id: "e0", title: "Sam's birthday", start: at(0, 0), end: at(0, 0, 1), allDay: true, location: "", tag: family },
          ev("e1", "Morning run", personal, at(7, 0), at(7, 30), "Riverside trail"),
          ev("e2", "Team stand-up", work, at(9, 0), at(9, 15), "Video call"),
          ev("e3", "Design review", work, at(10, 0), at(11, 0), "Studio B, 2nd floor"),
          ev("e4", "Lunch with Maya", personal, at(12, 30), at(13, 15), "Corner Café"),
          ev("e5", "Quarterly planning", work, at(14, 0), at(15, 30), "Room 4"),
          ev("e6", "Dentist", personal, at(16, 30), at(17, 0), "Elm Street Dental, 12 Elm St"),
          ev("e7", "Family dinner", family, at(18, 30), at(19, 30)),
        ],
      },
      right: {
        items: [
          task("t2", "Return library books", mine, -2),
          task("t3", "Submit expense report", work, 0),
          upcoming("e8", "Car service", errands, at(8, 30, 1), at(9, 30, 1)),
          task("t4", "Pay the electricity bill", errands, 3),
          allDay("e9", "Sam's birthday party", family, 5),
          task("t5", "Finish the slides for the client pitch", work, 6),
          upcoming("e10", "Flight to Lisbon", personal, at(10, 15, 12), at(14, 40, 12)),
          task("t6", "Renew passport", mine, 24),
          undated("t7", "Plan the weekend trip", mine),
          undated("t8", "Fix the squeaky door", errands),
          undated("t9", "Read the book club pick", mine),
        ],
      },
    },
  };
}

// ---------------------------------------------------------------- boot
setupScrollers();
if (DEBUG) {
  $("debug").hidden = false;
  window.addEventListener("keydown", (e) => {
    if (e.key === "w") send({ t: "force", awake: true });
    if (e.key === "s") send({ t: "force", awake: false });
  });
}
window.addEventListener("resize", () => { lastClock = ""; if (S.phase !== "asleep") renderAll(); });
if (MAC) {
  setFaded(true);
  // Trackpad / mouse wheel scrolls the list under the pointer. The weather
  // timeline is horizontal: it takes sideways swipes, or vertical ones if that
  // is all the device sends. WebKit already applies the user's natural-scrolling setting.
  window.addEventListener("wheel", (e) => {
    if (S.phase !== "awake") return;
    const card = e.target.closest && e.target.closest("[data-scroll]");
    const s = card && scrollers[card.dataset.scroll];
    if (!s) return;
    e.preventDefault();
    const unit = e.deltaMode === 1 ? 32 : e.deltaMode === 2 ? s.size : 1; // lines / pages -> px
    const d = s.axis === "x" ? (Math.abs(e.deltaX) >= Math.abs(e.deltaY) ? e.deltaX : e.deltaY) : e.deltaY;
    s.scrollPx(d * unit, performance.now());
    setEngaged(s);
    clearTimeout(releaseTimer);
    releaseTimer = setTimeout(() => setEngaged(null), 450);
  }, { passive: false });
  // A click on a task's ring checks it off (or undoes that during the undo window).
  $("stage").addEventListener("click", (e) => {
    const b = e.target.closest && e.target.closest(".check");
    if (!b || S.phase !== "awake") return;
    e.preventDefault();
    const key = b.closest(".has-check").dataset.key;
    toggleCheck(key);
    holdLists(key);
  });
  // On the Mac the HUD window takes every click while it shows, so a click outside the
  // cards closes it, like any overlay.
  document.addEventListener("click", (e) => {
    if (!MAC || S.phase !== "awake" || e.button !== 0) return;
    if (e.target.closest && e.target.closest(".card, button, a, .note")) return;
    send({ t: "force", awake: false });
  });
  // the page going away (reload, hidden window) sends what was checked off
  window.addEventListener("pagehide", flushChecks);
  document.addEventListener("visibilitychange", () => { if (document.hidden) flushChecks(); });
  // Esc closes the HUD (the app also catches Esc natively when the page lacks focus).
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && (S.phase === "awake" || S.phase === "entering")) send({ t: "force", awake: false });
  });
}
window.HUD = { wake, sleep, onScroll, onHead, S, scrollers, renderAll, ambient, checks, notes, get skyHalf() { return skyHalf; },
  get looping() { return rafId !== 0; } };
everySecond();
connect();
if (params.has("awake")) document.fonts.ready.then(() => wake(params.get("awake") !== "0"));
