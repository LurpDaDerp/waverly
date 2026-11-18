// Waverly website: hand tracking for the try-it demo. Loaded only after the visitor clicks
// "Try it with your camera". The camera picture goes to MediaPipe's gesture recognizer, which
// runs right here in the browser (WebAssembly, on the GPU when it can); nothing is uploaded.
//
// The gesture rules follow the app's own (hud/python/hud/gestures.py), a little more forgiving:
//   open:   a wave (a few side-to-side swings, palm toward the camera), or a fist then an open hand
//   close:  a fist held for a moment (after an open hand, or simply held a little longer)
//   scroll: an open hand moving up or down (the list on that side) or sideways (the forecast)
import { FilesetResolver, GestureRecognizer } from "../vendor/mediapipe/vision_bundle.mjs";

const BASE = new URL("../vendor/mediapipe", import.meta.url).href;
const FPS_GAP = 52; // ms between detections: about 19 a second

let recognizer = null, loading = null, usedDelegate = "";
let stream = null, video = null, runId = 0, engine = null, last = null, debug = false;

export const delegate = () => usedDelegate;
export const lastTrack = () => last;

const opts = (d) => ({
  baseOptions: { modelAssetPath: `${BASE}/gesture_recognizer.task`, delegate: d },
  runningMode: "VIDEO", numHands: 1,
  minHandDetectionConfidence: 0.6, minHandPresenceConfidence: 0.6, minTrackingConfidence: 0.5,
});

function load() {
  if (!loading) {
    loading = (async () => {
      const files = await FilesetResolver.forVisionTasks(BASE);
      try {
        recognizer = await GestureRecognizer.createFromOptions(files, opts("GPU"));
        usedDelegate = "GPU";
      } catch (e) {
        if (debug) console.info("[hands] GPU delegate unavailable, using the CPU", e);
        recognizer = await GestureRecognizer.createFromOptions(files, opts("CPU"));
        usedDelegate = "CPU";
      }
    })().catch((e) => { loading = null; throw e; });
  }
  return loading;
}

// Some browsers create the GPU recognizer fine but then fail on every frame: switch to the CPU.
let switching = null;
function toCpu() {
  if (!switching) {
    switching = (async () => {
      const files = await FilesetResolver.forVisionTasks(BASE);
      const old = recognizer;
      recognizer = await GestureRecognizer.createFromOptions(files, opts("CPU"));
      usedDelegate = "CPU";
      try { old?.close(); } catch {}
      if (debug) console.info("[hands] switched to the CPU");
    })().catch((e) => { if (debug) console.warn("[hands] CPU fallback failed", e); });
  }
  return switching;
}

// Start the camera and the detection loop. Resolves true once running, false if stop() was
// called meanwhile. Rejects with the getUserMedia or loading error.
export async function start(videoEl, onEvent, options = {}) {
  debug = !!options.debug;
  const id = ++runId;
  const camera = navigator.mediaDevices.getUserMedia({
    audio: false,
    video: { facingMode: "user", width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 30, max: 30 } },
  });
  let s;
  try {
    [s] = await Promise.all([camera, load()]);
  } catch (e) {
    camera.then((x) => x.getTracks().forEach((t) => t.stop()), () => {});
    throw e;
  }
  if (id !== runId) { s.getTracks().forEach((t) => t.stop()); return false; }
  stream = s;
  last = s.getVideoTracks()[0] || null;
  video = videoEl;
  video.srcObject = s;
  await video.play().catch(() => {});
  if (id !== runId) return false;
  engine = engine || new Gestures();
  engine.resume();
  loop(id, onEvent);
  return true;
}

export function stop() {
  runId++;
  if (stream) for (const t of stream.getTracks()) t.stop();
  stream = null;
  if (video) { video.pause(); video.srcObject = null; }
}

function loop(id, onEvent) {
  let prev = -1e9, frames = 0;
  const rvfc = "requestVideoFrameCallback" in HTMLVideoElement.prototype;
  let useRaf = !rvfc;
  const next = () => (useRaf ? requestAnimationFrame(step) : video.requestVideoFrameCallback(step));
  // if the video stops producing frame callbacks (some browsers skip them for tiny videos), use rAF
  const watchdog = setTimeout(() => { if (id === runId && !frames) { useRaf = true; next(); } }, 1500);
  let open = false, errors = 0;
  function step() {
    if (id !== runId) { clearTimeout(watchdog); return; }
    const now = performance.now();
    if (now - prev >= FPS_GAP && video.readyState >= 2 && video.videoWidth) {
      prev = now;
      frames++;
      let res = null;
      try {
        res = recognizer.recognizeForVideo(video, now);
        errors = 0;
      } catch (e) {
        if (debug) console.warn("[hands]", e);
        if (++errors >= 5 && usedDelegate === "GPU") toCpu();
      }
      const obs = res ? observe(res, video.videoWidth / video.videoHeight) : null;
      for (const ev of engine.update(now / 1000, obs, open)) {
        if (debug && ev.t !== "scroll") console.info("[hands]", JSON.stringify(ev));
        open = onEvent(ev);
      }
      open = onEvent({ t: "hand", state: obs ? obs.state : "none" });
      if (debug && obs && frames % 10 === 0) console.info("[hands] frame", JSON.stringify({ x: +obs.x.toFixed(3), y: +obs.y.toFixed(3), open: +obs.open.toFixed(2), shape: obs.shape, facing: obs.facing, yaw: obs.yaw === null ? null : Math.round(obs.yaw), cat: obs.cat }));
    }
    next();
  }
  next();
}

// ------------------------------------------------------------------ one detection, measured like the app
const FIST = "fist", PALM = "palm", OTHER = "other";
const d2 = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const d3 = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
const TIPS = [[8, 6], [12, 10], [16, 14], [20, 18]];
const CHAINS = [[5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16], [17, 18, 19, 20]];

function fingers(p) {
  let ext = 0, curl = 0;
  for (const [tip, pip] of TIPS) {
    const r = d2(p[tip], p[0]) / Math.max(d2(p[pip], p[0]), 1e-6);
    ext += r > 1.15;
    curl += r < 0.98;
  }
  return [ext, curl];
}

// 0 = a tight fist, 1 = all four fingers straight (3D landmarks, so the viewing angle doesn't matter)
function openness(w) {
  let s = 0;
  for (const [a, b, c, d] of CHAINS) s += d3(w[d], w[a]) / Math.max(d3(w[b], w[a]) + d3(w[c], w[b]) + d3(w[d], w[c]), 1e-9);
  return Math.min(1, Math.max(0, (s / 4 - 0.43) / 0.5));
}

// which way the palm faces: (yaw, pitch) in degrees, (0, 0) = squarely toward the camera
function palmAngles(w, p, aspect, label) {
  const sub = (a, b) => [a.x - b.x, a.y - b.y, a.z - b.z];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const o = w[0];
  const c1 = cross(sub(w[5], o), sub(w[9], o)), c2 = cross(sub(w[9], o), sub(w[13], o)), c3 = cross(sub(w[13], o), sub(w[17], o));
  let n = [c1[0] + c2[0] + c3[0], c1[1] + c2[1] + c3[1], c1[2] + c2[2] + c3[2]];
  const size = Math.hypot(...n);
  if (!(size > 1e-12)) return null;
  const sign = label === "Right" ? 1 : -1;
  n = n.map((v) => (v / size) * sign);
  const ids = [0, 5, 9, 13, 17];
  const cx = ids.reduce((s, i) => s + p[i].x, 0) / 5, cy = ids.reduce((s, i) => s + p[i].y, 0) / 5;
  const f = (0.5 * Math.hypot(aspect, 1)) / Math.tan((70 * Math.PI) / 360);
  let v = [-(cx - 0.5) * aspect, -(cy - 0.5), -f];
  const vl = Math.hypot(...v);
  v = v.map((x) => x / vl);
  const a = Math.atan2(v[0], -v[2]), ca = Math.cos(a), sa = Math.sin(a);
  const ry = (u) => [ca * u[0] + sa * u[2], u[1], -sa * u[0] + ca * u[2]];
  v = ry(v); n = ry(n);
  const b = Math.atan2(-v[1], -v[2]), cb = Math.cos(b), sb = Math.sin(b);
  n = [n[0], cb * n[1] - sb * n[2], sb * n[1] + cb * n[2]];
  const yaw = (Math.atan2(n[0], -n[2]) * 180) / Math.PI;
  const pitch = (Math.asin(Math.max(-1, Math.min(1, -n[1]))) * 180) / Math.PI;
  return Number.isFinite(yaw) && Number.isFinite(pitch) ? [yaw, pitch] : null;
}

function observe(res, aspect) {
  const lm = res.landmarks?.[0], wl = res.worldLandmarks?.[0];
  if (!lm || !wl) return null;
  const g = res.gestures?.[0]?.[0];
  const cat = g ? g.categoryName : "None", score = g ? g.score : 0;
  const label = (res.handedness || res.handednesses)?.[0]?.[0]?.categoryName || "";
  const geo = lm.map((q) => ({ x: q.x * aspect, y: q.y }));
  const [ext, curl] = fingers(geo);
  let shape = OTHER;
  if ((cat === "Closed_Fist" && score >= 0.5) || (curl >= 4 && ["None", "Closed_Fist", "Thumb_Up", "Thumb_Down"].includes(cat))) shape = FIST;
  else if ((cat === "Open_Palm" && score >= 0.5) || (ext >= 4 && (cat === "None" || cat === "Open_Palm"))) shape = PALM;
  const open = openness(wl);
  const ang = palmAngles(wl, lm, aspect, label);
  const facing = !!ang && Math.abs(ang[0]) <= 30 && Math.abs(ang[1]) <= 45;
  const palm = [0, 5, 9, 13, 17].reduce((s, i) => ({ x: s.x + lm[i].x / 5, y: s.y + lm[i].y / 5 }), { x: 0, y: 0 });
  const fist = shape === FIST || open <= 0.2;
  return {
    x: 1 - palm.x, // mirrored, like the preview: x grows toward the visitor's right
    y: palm.y,
    open, shape, fist, facing, cat,
    yaw: ang ? ang[0] : null,
    state: fist ? "fist" : shape === PALM || open >= 0.85 ? "open" : "hand",
  };
}

// ------------------------------------------------------------------ gestures (after gestures.py)
const WAVE_SWING = 0.045, WAVE_SWINGS = 4, WAVE_MIN_TIME = 1.0, WAVE_WINDOW = 2.4, WAVE_GAP = 0.6;
const WAVE_FACING_SHARE = 0.3, WAVE_MIN_FRAMES = 6;
const WAKE_FIST_HOLD = 0.1, WAKE_OPEN = 0.95, WAKE_WITHIN = 1.5, WAKE_GAP = 0.5, WAKE_DROPOUT = 2.0;
const WAKE_AFTER_CLOSE = 1.2, WAKE_UNBLOCK = 0.5;
const FIST_MIN_FRAMES = 4, FIST_FACING_LAST = 2;
const CLOSE_FROM = 0.9, CLOSE_WITHIN = 1.5, CLOSE_HOLD = 0.3, CLOSE_HOLD_ALONE = 0.8, CLOSE_AFTER_OPEN = 1.5;
const MOVE_MIN = 0.08, MAX_GAP = 0.15, LOST_AFTER = 0.3, AXIS_LOCK = 0.06, AXIS_RATIO = 1.5, ASPECT = 4 / 3;
const ARRIVAL = 0.35, STROKE_END = 0.28, SCROLL_OPEN = 0.85, SCROLL_AFTER_WAKE = 0.8;

class OneEuro {
  constructor(mincutoff = 1.8, beta = 12, dcutoff = 1) { Object.assign(this, { mincutoff, beta, dcutoff }); this.reset(); }
  reset() { this.x = null; this.dx = 0; this.t = 0; }
  static alpha(cutoff, dt) { const tau = 1 / (2 * Math.PI * cutoff); return 1 / (1 + tau / dt); }
  f(x, t) {
    if (this.x === null) { this.x = x; this.t = t; return x; }
    const dt = Math.max(t - this.t, 1e-3);
    this.t = t;
    const ad = OneEuro.alpha(this.dcutoff, dt);
    this.dx = ad * ((x - this.x) / dt) + (1 - ad) * this.dx;
    const a = OneEuro.alpha(this.mincutoff + this.beta * Math.abs(this.dx), dt);
    this.x = a * x + (1 - a) * this.x;
    return this.x;
  }
}

class Gestures {
  constructor() {
    this.lastWake = -1e9;
    this.lastSleep = -1e9;
    this.seen = [];
    this.w = { dir: 0, start: 0, ext: 0, from: 0, swings: [], last: -1e9 };
    this.wf = { since: null, last: -1e9, ok: false, start: 0, seen: -1e9, block: false, lost: 0, lostAll: 0, dropped: false };
    this.cl = { openAt: -1e9, fistSince: null };
    this.sc = null;
    this.handAt = -1e9;
  }

  // the camera was off for a while: forget half-made gestures
  resume() {
    this.seen = [];
    this.w.swings = [];
    this.w.last = -1e9;
    this.wf.since = null; this.wf.ok = false;
    this.cl.fistSince = null; this.cl.openAt = -1e9;
    this.sc = null;
  }

  update(t, o, awake) {
    const ev = [];
    if (!o) {
      if (this.sc && t - this.sc.seen > LOST_AFTER) { this.endStroke(ev); this.sc = null; }
      if (t - this.handAt > WAKE_GAP) this.cl.fistSince = null;
      return ev;
    }
    this.handAt = t;
    if (!awake) {
      this.sc = null;
      this.seen.push({ t, facing: o.facing, fist: o.fist });
      while (this.seen.length && t - this.seen[0].t > 5) this.seen.shift();
      this.wave(o, t, ev);
      if (!ev.length) this.fistWake(o, t, ev);
    } else {
      if (this.close(o, t)) {
        ev.push({ t: "sleep", by: "fist" });
        this.lastSleep = t;
        this.endStroke(ev);
        this.sc = null;
        Object.assign(this.wf, { block: true, since: null, ok: false, seen: t });
        this.w.swings = [];
        return ev;
      }
      // the hand that just waved the dashboard open is still moving: let it settle first
      if (t - this.lastWake >= SCROLL_AFTER_WAKE) this.scroll(o, t, ev);
      else this.sc = null;
    }
    return ev;
  }

  // ---- open: wave
  wave(o, t, ev) {
    const w = this.w, x = o.x, gap = t - w.last;
    w.last = t;
    if (gap > WAVE_GAP) { Object.assign(w, { dir: 0, start: x, ext: x, from: t, swings: [] }); return; }
    if (!o.fist) {
      if (w.dir === 0) {
        if (Math.abs(x - w.start) > 0.02) { w.dir = x > w.start ? 1 : -1; w.ext = x; w.from = t; }
      } else if ((x - w.ext) * w.dir >= 0) {
        w.ext = x;
      } else if (Math.abs(x - w.ext) > 0.02) { // turned around
        if (Math.abs(w.ext - w.start) >= WAVE_SWING) w.swings.push([t, w.from]);
        Object.assign(w, { start: w.ext, ext: x, dir: -w.dir, from: t });
      }
    }
    w.swings = w.swings.filter((s) => t - s[0] <= WAVE_WINDOW);
    const n = w.swings.length;
    if (n < WAVE_SWINGS) return;
    const since = w.swings[0][1];
    if (t - since < WAVE_MIN_TIME || t - this.lastSleep < WAKE_AFTER_CLOSE || t - this.lastWake < 2) return;
    // the palm must face the camera on enough of the wave, and on the newest frame
    const frames = this.seen.filter((f) => f.t >= since - 1e-6 && !f.fist);
    const facing = frames.filter((f) => f.facing).length;
    const newest = this.seen[this.seen.length - 1];
    if (frames.length < WAVE_MIN_FRAMES || facing / frames.length < WAVE_FACING_SHARE || newest.fist || !newest.facing) return;
    ev.push({ t: "wake", by: "wave" });
    this.lastWake = t;
    w.swings = [];
  }

  // ---- open: a fist, then an open hand
  fistWake(o, t, ev) {
    const f = this.wf, gap = t - f.seen;
    // A fist turning round as it opens is often lost for a moment: an armed fist survives up
    // to WAKE_DROPOUT s out of view in all, and that time doesn't count toward WAKE_WITHIN.
    // (The app also asks for the fist to look like a real hand first.)
    if (gap > WAKE_GAP && f.ok && f.lostAll + gap <= WAKE_DROPOUT) { f.lost += gap; f.lostAll += gap; f.dropped = true; }
    else if (gap > WAKE_GAP) { f.since = null; f.ok = false; f.block = false; }
    f.seen = t;
    if (o.fist) {
      if (f.block) return; // still the fist that closed it
      if (f.since === null) f.since = t;
      if (t - f.since >= WAKE_FIST_HOLD && (!f.ok || (f.dropped && f.start !== f.since))) {
        if (!f.ok) f.lostAll = 0; // (a fist back after a dropout re-arms; the dropout stays a total)
        f.ok = true; f.start = f.since; f.dropped = false;
      }
      f.last = t; f.lost = 0;
      return;
    }
    if (o.open >= WAKE_UNBLOCK) f.block = false;
    f.since = null;
    if (f.ok && t - f.last - f.lost > WAKE_WITHIN) f.ok = false; // opened too late
    if (!f.ok || o.open < WAKE_OPEN || t - this.lastSleep < WAKE_AFTER_CLOSE) return;
    const frames = this.seen.filter((x) => x.t >= f.start - 1e-6);
    const opened = frames.filter((x) => !x.fist).slice(-FIST_FACING_LAST);
    if (frames.length < FIST_MIN_FRAMES || opened.length < FIST_FACING_LAST || !opened.every((x) => x.facing)) return;
    f.ok = false;
    ev.push({ t: "wake", by: "fist" });
    this.lastWake = t;
  }

  // ---- close: a fist held a moment
  close(o, t) {
    const c = this.cl;
    if (o.open >= CLOSE_FROM) c.openAt = t;
    if (!o.fist) { c.fistSince = null; return false; }
    if (c.fistSince === null) { c.fistSince = t; c.fromOpen = t - c.openAt <= CLOSE_WITHIN; }
    if (t - this.lastWake < CLOSE_AFTER_OPEN) return false;
    const held = t - c.fistSince;
    if (held >= (c.fromOpen ? CLOSE_HOLD : CLOSE_HOLD_ALONE)) { c.fistSince = null; c.openAt = -1e9; return true; }
    return false;
  }

  // ---- scroll: an open hand moving
  endStroke(ev) {
    const s = this.sc;
    if (!s) return;
    if (s.axis) ev.push({ t: "end", target: s.target });
    Object.assign(s, { axis: null, target: null, ax: 0, ay: 0, perp: 0, along: 0, quiet: null });
  }

  scroll(o, t, ev) {
    let s = this.sc;
    if (!s || t - s.seen > LOST_AFTER) {
      s = this.sc = { first: t, seen: t, arrived: false, fx: new OneEuro(), fy: new OneEuro(), px: null, py: 0, pt: 0, vx: 0, vy: 0, open: o.open, axis: null, target: null, ax: 0, ay: 0, perp: 0, along: 0, quiet: null };
    } else if (t - s.seen > MAX_GAP) { // reappeared after a short gap: restart smoothing, never jump
      s.fx.reset(); s.fy.reset(); s.px = null;
    }
    s.seen = t;
    const x = s.fx.f(o.x, t), y = s.fy.f(o.y, t);
    if (s.px === null) { Object.assign(s, { px: x, py: y, pt: t, vx: 0, vy: 0 }); return; }
    const dt = t - s.pt;
    if (dt <= 0) return;
    const dx = x - s.px, dy = y - s.py;
    Object.assign(s, { px: x, py: y, pt: t });
    const k = 1 - Math.exp(-dt / 0.035);
    s.vx += k * (dx / dt - s.vx);
    s.vy += k * (dy / dt - s.vy);
    s.open += (1 - Math.exp(-dt / 0.07)) * (o.open - s.open);
    const moving = Math.hypot(s.vx, s.vy) >= MOVE_MIN && s.open >= SCROLL_OPEN && !o.fist;
    if (!moving) {
      if (s.quiet === null) s.quiet = t;
      else if (t - s.quiet > STROKE_END) this.endStroke(ev);
      return;
    }
    s.quiet = null;
    const decay = Math.exp(-dt / 0.2);
    if (s.axis) {
      const a = s.axis === "x" ? dx * ASPECT : dy, p = s.axis === "x" ? dy : dx * ASPECT;
      s.along = s.along * decay + Math.abs(a);
      s.perp = s.perp * decay + Math.abs(p);
      if (s.perp > 0.1 && s.perp > 3 * s.along) { this.endStroke(ev); return; } // a clear turn: start over
      ev.push({ t: "scroll", target: s.target, d: s.axis === "x" ? dx : dy });
      return;
    }
    // before a direction is chosen, small movements leak away so a resting hand never scrolls
    const leak = Math.exp(-dt / 0.8);
    if (s.ax * dx * ASPECT * ASPECT + s.ay * dy < 0) s.ax = s.ay = 0;
    s.ax = s.ax * leak + dx;
    s.ay = s.ay * leak + dy;
    const tx = Math.abs(s.ax) * ASPECT;
    if (!s.arrived) {
      if (t - s.first >= ARRIVAL) { s.arrived = true; s.ax = s.ay = 0; return; }
      if (Math.abs(s.ay) >= tx) { s.ax = s.ay = 0; return; } // the arm is still rising into view
    }
    if (Math.hypot(s.ax, s.ay) < AXIS_LOCK) return;
    let d;
    if (tx > AXIS_RATIO * Math.abs(s.ay)) { s.axis = "x"; s.target = "weather"; d = s.ax; }
    else if (Math.abs(s.ay) > AXIS_RATIO * tx) { s.axis = "y"; s.target = o.x < 0.5 ? "schedule" : "deadlines"; d = s.ay; }
    else return;
    s.ax = s.ay = s.perp = s.along = 0;
    ev.push({ t: "scroll", target: s.target, d });
  }
}
