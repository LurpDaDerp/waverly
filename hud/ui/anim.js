// Open ("wake") and close ("sleep") choreographies for the HUD: fade, zoom, shatter, slide, swirl.
//
// Contract (see app.js wake() / exit()):
//   openAnimation(type, ctx) / closeAnimation(type, ctx) -> Promise<void>
//   ctx = { stage, sky, cards, mac, scale, A, reducedMotion, lite? }
// Every animation is created synchronously, through ctx.A, so the app can cancel it or play it
// backwards (turnAround) like any other. The promise resolves once all of them have finished or
// been cancelled. An open ends exactly on the natural layout (cards: fill "backwards"); a close
// ends with everything invisible (sky opacity 0, cards opacity 0, fill "forwards").
//
// Timing: ctx.scale is the user's setting divided by the app's default (open 1.0 s, close
// 0.75 s). Every type except fade is normalised so that the whole run, the last child "rise"
// included, lasts exactly scale x 1000 ms (open) or scale x 750 ms (close): the setting means
// what it says. Fade keeps today's tile choreography verbatim (about 1000 / 750 ms at scale 1).
//
// The tiles are the main event; the background (#sky) is quiet. For every type it starts with
// the tiles (or a moment before), is fully in before they settle, and on close is gone together
// with, or just before, the last tile. It fades softly, darker and less saturated while it moves,
// and never shows an edge: zoom and swirl bloom it out of the centre and shatter floods it in from
// the screen edges, each through a radial mask feathered over 30-40% of the screen; fade and slide
// simply fade it with a slight scale. Wherever the mask lets the sky box's own edge show, the box
// is kept larger than the screen.
//
// How it is built: cards only ever animate transform + opacity, and the sky transform, filter
// and opacity, all of which the compositor plays. Motion paths (spirals, curved tumbles) and
// spring easings are sampled into keyframes (linear between ~45 steps), so no per-frame
// JavaScript runs and every engine shows the same thing (no dependence on CSS linear() easing,
// which WebKit only has from Safari 17.2).
// The bloom (zoom, swirl) is compositor-only too: a fixed feathered mask on #sky-veil, the
// sky's wrapper (index.html), which is scaled up from the centre while the sky inside is scaled
// back down by the same factor, so only the mask grows (WebKit paints the mask once; animating
// the mask itself would repaint a full-screen layer every frame, measured at ~125 ms CPU per
// second of animation). Shatter's ink, a hole that closes, cannot be made by scaling a fixed mask,
// so it animates the mask through two registered custom properties (--wv-r radius, --wv-a floor
// alpha), on the main thread, for about 0.6 s per run. ctx.lite (optional) drops the masks
// (transform + opacity only) for slower machines. Nothing is left behind at rest: no class,
// inline style, transform, mask or will-change.

export const OPEN_TYPES = ["fade", "zoom", "shatter", "slide", "swirl"];
export const CLOSE_TYPES = ["fade", "zoom", "shatter", "slide", "swirl"];

// length of each choreography at scale 1, in ms (fade: today's, not normalised; its open ends
// with the last child element that rises, about 1000)
export const DURATION_MS = {
  open: { fade: 1000, zoom: 1000, shatter: 1000, slide: 1000, swirl: 1000 },
  close: { fade: 750, zoom: 750, shatter: 750, slide: 750, swirl: 750 },
};
const TARGET = { open: 1000, close: 750 };

export function openAnimation(type, ctx) { return run("open", type, ctx); }
export function closeAnimation(type, ctx) { return run("close", type, ctx); }

// ---------------------------------------------------------------- runner
let runId = 0;
const SKY_CLASSES = ["wv-bloom", "wv-ink"], VEIL_CLASS = "wv-veil";
const SKY_VARS = ["--wv-f"];

function run(dir, type, ctx) {
  const id = ++runId;
  const anims = [];
  const k = Number.isFinite(ctx.scale) && ctx.scale >= 0 ? ctx.scale : 1;
  const c = {
    ...ctx,
    A: (el, kf, opt) => { const a = ctx.A(el, kf, opt); anims.push(a); return a; },
    T: (ms) => ms * k,
    curtain: document.getElementById("curtain"),
    g: geometry(ctx),
  };
  injectCSS();
  resetSky(ctx.sky);
  c.veil = ctx.sky.parentElement?.id === "sky-veil" ? ctx.sky.parentElement : null;
  let cleanup = null;
  const fx = ctx.reducedMotion ? REDUCED : FX[type] || FX.fade;
  try {
    cleanup = fx[dir](c) || null;
    if (fx !== FX.fade && fx !== REDUCED) normalise(anims, TARGET[dir] * k);
  } catch (e) {
    console.error("anim.js:", e);
  }
  return Promise.allSettled(anims.map((a) => a.finished)).then(() => {
    if (id !== runId) return; // a newer run owns the sky now
    if (cleanup) cleanup();
  });
}

// Stretch every delay and duration by one factor so the run ends exactly at `target` ms (the
// number of child elements that rise into place depends on the data, so the end is measured).
// Runs synchronously, before the first frame, so nothing visible changes but the pace.
function normalise(anims, target) {
  let end = 0;
  for (const a of anims) { const t = a.effect.getTiming(); end = Math.max(end, (t.delay || 0) + (+t.duration || 0)); }
  if (!(end > 0) || !(target > 0) || Math.abs(end - target) < 0.5) return;
  const f = target / end;
  for (const a of anims) { const t = a.effect.getTiming(); a.effect.updateTiming({ delay: (t.delay || 0) * f, duration: (+t.duration || 0) * f }); }
}

function resetSky(sky) {
  sky.classList.remove(...SKY_CLASSES);
  for (const v of SKY_VARS) sky.style.removeProperty(v);
  if (sky.parentElement?.id === "sky-veil") sky.parentElement.classList.remove(VEIL_CLASS);
}

// The masks: one radial gradient over the sky box (an ellipse with the box's aspect, so the
// feather is the same share of the screen across and down). In % of the box's half-size:
// --wv-r is the radius of the core, --wv-f the width of the feather, --wv-a the alpha beyond it
// (bloom: the opaque core fades out to a; ink: a clear-ish hole of alpha a fades up to opaque).
// The feather follows a smoothstep profile (five stops) so there is no visible rim. --wv-r never
// goes below 0 (WebKit draws a radial gradient whose stops are all at or below 0 as its first
// colour), and the run ends on a = 1, a uniformly opaque mask, before the class is removed.
const FEATHER = 80, VEIL_CORE = 40;
const PROFILE = [[0, 1], [0.25, 0.844], [0.5, 0.5], [0.75, 0.156], [1, 0]];
function maskImage(ink) {
  const stops = PROFILE.map(([x, v]) =>
    `rgba(0, 0, 0, calc(var(--wv-a) + (1 - var(--wv-a)) * ${ink ? r4(1 - v) : v})) calc((var(--wv-r) + var(--wv-f) * ${x}) * 1%)`);
  return `radial-gradient(closest-side at 50% 50%, ${stops.join(", ")})`;
}
let cssDone = false;
function injectCSS() {
  if (cssDone) return;
  cssDone = true;
  const bloom = maskImage(false), ink = maskImage(true);
  // the veil's fixed bloom: opaque out to VEIL_CORE % of the screen's half-size, then the same
  // smooth feather down to nothing at the veil's (the screen's) edge
  const veil = `radial-gradient(closest-side at 50% 50%, ${PROFILE.map(([x, v]) => `rgba(0, 0, 0, ${v}) ${r2(VEIL_CORE + (100 - VEIL_CORE) * x)}%`).join(", ")})`;
  const css = `
@property --wv-r { syntax: "<number>"; inherits: false; initial-value: 0; }
@property --wv-a { syntax: "<number>"; inherits: false; initial-value: 1; }
#sky.wv-bloom { -webkit-mask-image: ${bloom}; mask-image: ${bloom}; }
#sky.wv-ink { -webkit-mask-image: ${ink}; mask-image: ${ink}; }
#sky-veil.${VEIL_CLASS} { -webkit-mask-image: ${veil}; mask-image: ${veil}; }`;
  const el = document.createElement("style");
  el.id = "wv-anim-css";
  el.textContent = css;
  document.head.append(el);
}

// ---------------------------------------------------------------- geometry
function geometry(ctx) {
  const W = innerWidth, H = innerHeight;
  const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
  const cx = W / 2, cy = H / 2;
  const cards = ctx.cards.map((el) => {
    // layout box (offset*: no transforms, no head-parallax tilt); #stage is fixed at 0,0
    const l = el.offsetLeft, t = el.offsetTop, w = el.offsetWidth, h = el.offsetHeight;
    const x = l + w / 2, y = t + h / 2;
    const dx = x - cx, dy = y - cy, d = Math.hypot(dx, dy) || 1;
    return { el, o: +el.dataset.enter || 0, l, t, w, h, r: l + w, b: t + h, x, y, dx, dy, d,
      ux: dx / d, uy: dy / d, nx: (x / W) * 2 - 1, ny: (y / H) * 2 - 1 };
  });
  const maxD = Math.max(1, ...cards.map((q) => q.d));
  return { W, H, cx, cy, rem, cards, maxD };
}

// distance along (ux, uy) that takes the card (grown by margin m) fully off screen
function offDistance(q, ux, uy, m, g) {
  let D = Infinity;
  if (ux < -1e-3) D = Math.min(D, (q.r + m) / -ux);
  if (ux > 1e-3) D = Math.min(D, (g.W - q.l + m) / ux);
  if (uy < -1e-3) D = Math.min(D, (q.b + m) / -uy);
  if (uy > 1e-3) D = Math.min(D, (g.H - q.t + m) / uy);
  return D === Infinity ? g.W : D;
}

// ---------------------------------------------------------------- easing + keyframe baking
const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);
const mix = (a, b, t) => a + (b - a) * t;
const lmix = (a, b, t) => a * Math.pow(b / a, t); // even-feeling zoom: interpolate scale in log space
const seg = (p, a, b) => clamp01((p - a) / (b - a)); // progress within [a, b] of the timeline
const smooth = (x) => x * x * (3 - 2 * x);
const outPow = (n) => (p) => 1 - Math.pow(1 - clamp01(p), n);
const softmin = (a, b, s) => (Math.abs(a - b) > 30 * s ? Math.min(a, b) : -s * Math.log(Math.exp(-a / s) + Math.exp(-b / s)));

function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = (t) => ((ax * t + bx) * t + cx) * t, Y = (t) => ((ay * t + by) * t + cy) * t;
  const dX = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = X(t) - x, d = dX(t);
      if (Math.abs(e) < 1e-6 || Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    if (!(t >= 0 && t <= 1) || Math.abs(X(t) - x) > 1e-4) {
      let lo = 0, hi = 1;
      for (let i = 0; i < 40; i++) { t = (lo + hi) / 2; if (X(t) < x) lo = t; else hi = t; }
    }
    return Y(t);
  };
}

// Damped spring from 0 to 1 that has settled by p = 1. bounce = overshoot (0 = critically
// damped); decay = how fast it settles (higher: more of the motion happens early).
function spring(bounce = 0, decay = 7) {
  let f;
  if (bounce <= 0) {
    f = (t) => 1 - (1 + decay * t) * Math.exp(-decay * t);
  } else {
    const L = Math.log(bounce), zeta = -L / Math.sqrt(Math.PI * Math.PI + L * L);
    const wd = (decay / zeta) * Math.sqrt(1 - zeta * zeta);
    f = (t) => 1 - Math.exp(-decay * t) * (Math.cos(wd * t) + (decay / wd) * Math.sin(wd * t));
  }
  const end = f(1);
  return (p) => (p <= 0 ? 0 : p >= 1 ? 1 : f(p) + (1 - end) * p);
}

const N = 45; // keyframe samples per animation (~20 ms apart at 1 s)
function bake(f, n = N) {
  const out = [];
  for (let i = 0; i <= n; i++) { const p = i / n; out.push({ ...f(p), offset: p }); }
  return out;
}
const r2 = (v) => Math.round(v * 100) / 100, r4 = (v) => Math.round(v * 10000) / 10000;
// one transform function list everywhere, so every pair of keyframes interpolates per function
const tf = ({ x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, sx = 1, sy = sx }) =>
  `translate3d(${r2(x)}px, ${r2(y)}px, ${r2(z)}px) rotateX(${r2(rx)}deg) rotateY(${r2(ry)}deg) rotateZ(${r2(rz)}deg) scale(${r4(sx)}, ${r4(sy)})`;

// ---------------------------------------------------------------- shared pieces
// child elements rise into place inside each card (today's entrance). They rise to their own
// opacity (past events and hours rest dimmed): rising to 1 made them snap back to it at the end,
// and show at full strength while a close played the entrance backwards.
const RISE = "[data-rise], .now, .chips, .hr, .word, .word-meta, .prose, h1, .date, .time";
function rise(c, card, start, { dur = 450, step = 20, easing = "cubic-bezier(.2,.8,.2,1)" } = {}) {
  [...card.querySelectorAll(RISE)].slice(0, 14).forEach((el, i) => {
    const o = +getComputedStyle(el).opacity;
    c.A(el, [{ opacity: 0, transform: "translate3d(0, 1.4rem, 0)" }, { opacity: Number.isFinite(o) ? o : 1, transform: "none" }],
      { duration: c.T(dur), delay: c.T(start + i * step), easing, fill: "backwards" });
  });
}

// ---------------------------------------------------------------- the background (#sky)
// Background visibility: the sky's opacity (the curtain in macOS mode). Without ?mac the black
// #curtain is held clear for the whole run instead, so the sky's own effect plays over the black
// page (the app sets the curtain after).
function skyOpacity(c, kf, opt, total) {
  c.A(c.sky, kf, { ...opt, fill: "both" });
  if (!c.mac && c.curtain) c.A(c.curtain, [{ opacity: 0 }, { opacity: 0 }], { duration: c.T(total), fill: "both" });
}

// The sky box is inset -3rem with transform-origin 50% 40%. skyTf rotates (deg) and scales it
// about the screen centre instead (the translate keeps the centre fixed).
function skyTf(g, deg, k, tx = 0, ty = 0) {
  const oy = -3 * g.rem + 0.4 * (g.H + 6 * g.rem), dy = g.cy - oy, th = deg * Math.PI / 180;
  return `translate(${r2(tx + k * Math.sin(th) * dy)}px, ${r2(ty + dy - k * Math.cos(th) * dy)}px) rotate(${r2(deg)}deg) scale(${r4(k)})`;
}
// The smallest scale at which the box, turned by deg about the screen centre, still covers the
// whole screen, head-parallax shift (up to 2rem x 1.4rem) included.
// frac < 1: only the central frac of the screen need be covered
function coverK(g, deg, frac = 1) {
  const th = deg * Math.PI / 180, co = Math.abs(Math.cos(th)), si = Math.abs(Math.sin(th));
  const qx = frac * g.W / 2 + 2 * g.rem, qy = frac * g.H / 2 + 1.4 * g.rem, bx = g.W / 2 + 3 * g.rem, by = g.H / 2 + 3 * g.rem;
  return Math.max((qx * co + qy * si) / bx, (qx * si + qy * co) / by) * 1.005;
}
// The screen's corners in the mask's units (% of the box's half-size), with the parallax shift
const cornerR = (g) => 100 * Math.hypot((g.W / 2 + 2 * g.rem) / (g.W / 2 + 3 * g.rem), (g.H / 2 + 1.4 * g.rem) / (g.H / 2 + 3 * g.rem)) + 2;
// the veil scale at which the bloom's opaque core just covers the screen corners
const veilEnd = (g) => (100 * Math.hypot(1 + 4 * g.rem / g.W, 1 + 2.8 * g.rem / g.H) + 2) / VEIL_CORE;
// the sky's head-parallax shift (the CSS translate property), in px
function skyShift(sky) {
  const t = getComputedStyle(sky).translate;
  const [x = 0, y = 0] = t && t !== "none" ? t.split(" ").map(parseFloat) : [];
  return { x: x || 0, y: y || 0 };
}

// One background run. Every channel is a function of p, the progress (0..1) of the sky's own
// [delay, delay + dur] window: o opacity, k scale, rot (deg), b brightness, s saturation, and for
// a mask ("bloom" | "ink") r and a (see maskImage). Opacity, transform and filter are compositor
// animations; only the mask's two numbers are not.
function skyRun(c, spec) {
  const { g, sky } = c, mask = c.lite ? null : spec.mask;
  const opt = { duration: c.T(spec.dur), delay: c.T(spec.delay || 0), fill: "both", easing: "linear" };
  if (mask === "bloom" && c.veil) return veilRun(c, spec, opt);
  if (mask) {
    sky.classList.add(mask === "ink" ? "wv-ink" : "wv-bloom");
    sky.style.setProperty("--wv-f", String(FEATHER));
    c.A(sky, bake((p) => ({ "--wv-r": r2(Math.max(0, spec.r(p))), "--wv-a": r4(clamp01(spec.a(p))) }), 30), opt);
  }
  c.A(sky, bake((p) => {
    const deg = spec.rot ? spec.rot(p) : 0;
    let k = spec.k(p);
    // where the mask (or no mask) lets the box's own edge show, the box covers the screen
    const edge = !mask || mask === "ink" ? 1 : clamp01(Math.max(spec.a(p) / 0.01, (spec.r(p) + FEATHER - 96) / 4));
    if (edge > 0) k = Math.max(k, mix(k, coverK(g, deg), edge));
    return { transform: skyTf(g, deg, k), filter: `brightness(${r4(spec.b(p))}) saturate(${r4(spec.s(p))})` };
  }), opt);
  skyOpacity(c, bake((p) => ({ opacity: r4(clamp01(spec.o(p))) }), 20), opt, spec.total);
  return mask ? () => resetSky(sky) : null;
}

// The bloom through #sky-veil (compositor only): the veil, with its fixed feathered mask, scales
// by v(p) about the screen centre; the sky inside scales by k / v (and its parallax shift by
// 1 / v), so on screen it does exactly what k and rot say while only the mask grows. Where the
// mask reaches beyond the sky box (scaled down or turned), the box is grown to cover it.
function veilRun(c, spec, opt) {
  const { g, sky, veil } = c, sh = skyShift(sky);
  veil.classList.add(VEIL_CLASS);
  c.A(veil, bake((p) => ({ transform: `scale(${r4(spec.v(p))})` })), opt);
  c.A(sky, bake((p) => {
    const v = spec.v(p), deg = spec.rot ? spec.rot(p) : 0;
    const k = Math.max(spec.k(p), coverK(g, deg, Math.min(1, v)));
    return { transform: skyTf(g, deg, k / v, sh.x * (1 / v - 1), sh.y * (1 / v - 1)), filter: `brightness(${r4(spec.b(p))}) saturate(${r4(spec.s(p))})` };
  }), opt);
  skyOpacity(c, bake((p) => ({ opacity: r4(clamp01(spec.o(p))) }), 20), opt, spec.total);
  return () => resetSky(sky);
}

// the shared curves: the background comes in with a long, soft ease-out and leaves with a soft
// ease-in-out
const inO = (p, end) => outPow(2)(seg(p, 0, end));
const outO = (p, from) => 1 - smooth(seg(p, from, 1));

// fade and slide: a plain fade with a slight scale
function fadeSky(c, open, total) {
  if (open) {
    const settle = bezier(0.16, 1, 0.3, 1);
    return skyRun(c, { dur: 900, total, o: (p) => inO(p, 0.62),
      k: (p) => mix(1.06, 1, settle(p)), b: (p) => mix(0.5, 1, settle(p)), s: (p) => mix(0.7, 1, settle(p)) });
  }
  const go = bezier(0.4, 0, 0.6, 1);
  return skyRun(c, { dur: 580, delay: 80, total, o: (p) => outO(p, 0),
    k: (p) => mix(1, 1.04, go(p)), b: (p) => mix(1, 0.55, go(p)), s: (p) => mix(1, 0.7, go(p)) });
}

// ---------------------------------------------------------------- the effects
const FX = {};

// ---- fade: today's choreography (only scaled by ctx.scale), except for the background's opacity
function vec(el) {
  const r = el.getBoundingClientRect();
  return { nx: (r.left + r.width / 2) / innerWidth * 2 - 1, ny: (r.top + r.height / 2) / innerHeight * 2 - 1 };
}
// The background: it now starts with the tiles and is in by the time they settle (500 ms),
// with a soft ease-out (it used to ease in over 550 ms, so it was still filling in while the
// tiles were already opaque); on close it is gone just before the last tile (650 ms, not 760).
const fadeIn = outPow(2.2);
const fadeOpacity = (c, kf, opt) => {
  if (c.mac) c.A(c.sky, kf, opt);
  else c.A(c.curtain, kf.map((f) => ({ ...f, opacity: r4(1 - f.opacity) })), opt);
};
FX.fade = {
  open(c) {
    const { A, T } = c;
    fadeOpacity(c, bake((p) => ({ opacity: r4(fadeIn(p)) }), 16), { duration: T(500), easing: "linear", fill: "forwards" });
    A(c.sky, [{ transform: "scale(1.14)", filter: "brightness(.4) saturate(.6)" }, { transform: "scale(1)", filter: "brightness(1) saturate(1)" }],
      { duration: T(1000), easing: "cubic-bezier(.16,1,.3,1)" });
    const ease = "cubic-bezier(.16,1,.3,1)";
    for (const card of c.cards) {
      const o = +card.dataset.enter, { nx, ny } = vec(card);
      const delay = 30 + o * 35;
      A(card, [
        { opacity: 0, transform: `translate3d(${nx * 9}rem, ${ny * 6 + 4}rem, -42rem) rotateX(${12 - ny * 6}deg) rotateY(${nx * -14}deg)` },
        { opacity: 1, offset: 0.55 },
        { opacity: 1, transform: "none" },
      ], { duration: T(700), delay: T(delay), easing: ease, fill: "backwards" });
      rise(c, card, delay + 100);
    }
  },
  close(c) {
    const { A, T } = c;
    const ease = "cubic-bezier(.55,0,.8,.25)";
    for (const card of c.cards) {
      const o = +card.dataset.enter, { nx, ny } = vec(card);
      A(card, [
        { opacity: 1, transform: "none" },
        { opacity: 1, offset: 0.35 },
        { opacity: 0, transform: `translate3d(${nx * 6}rem, ${ny * 4 + 3}rem, -34rem) rotateX(${-8 - ny * 5}deg) rotateY(${nx * -10}deg)` },
      ], { duration: T(525), delay: T((5 - o) * 28), easing: ease, fill: "forwards" });
    }
    A(c.sky, [{ transform: "scale(1)", filter: "brightness(1)" }, { transform: "scale(1.08)", filter: "brightness(.45)" }],
      { duration: T(750), easing: "cubic-bezier(.4,0,.6,1)", fill: "forwards" });
    fadeOpacity(c, bake((p) => ({ opacity: r4(1 - smooth(p)) }), 16), { duration: T(500), delay: T(150), easing: "linear", fill: "forwards" });
  },
};

// ---- zoom: the sky and every tile grow out of the centre of the screen, each on its own clock.
// All of them follow one scale curve S(tau); each tile runs it a little behind the sky (open) or
// ahead of it (close), so a tile is always smaller than the sky slab around it, and the lag is
// what makes the tiles move independently.
// s0: the size everything starts from (open); s1: the size it fades out at (close)
const ZOOM = { s0: 0.045, s1: 0.1 };
// The background blooms out of the centre with the tiles: a feathered core that grows on the
// tiles' own (log-scale) curve, always well around them. (r / a: the same bloom through the
// animated mask, used when the page has no #sky-veil.)
function zoomSky(c, { open, curve, dur, delay, total }) {
  const R = cornerR(c.g), VE = veilEnd(c.g);
  const e = open ? curve : (p) => 1 - curve(p);
  return skyRun(c, { mask: "bloom", dur, delay, total,
    v: (p) => lmix(0.08 * VE, VE, e(p)),
    r: (p) => R * lmix(0.08, 1, e(p)), a: open ? (p) => smooth(seg(p, 0.4, 1)) : (p) => 1 - smooth(seg(p, 0, 0.55)),
    o: open ? (p) => inO(p, 0.7) : (p) => outO(p, 0.4),
    k: (p) => mix(open ? 1.06 : 1.05, 1, e(p)), b: (p) => mix(0.55, 1, e(p)), s: (p) => mix(0.7, 1, e(p)) });
}
FX.zoom = {
  open(c) {
    const { g } = c, total = 1000, dur = 800;
    // fast out of the centre, long soft landing (in log-scale space, so the growth feels even)
    const curve = outPow(2.6);
    const cleanup = zoomSky(c, { open: true, curve: outPow(2.4), dur: 780, delay: 0, total });
    for (const q of g.cards) {
      // later tiles in the page are drawn on top, so they lag least: a tile drawn over another is
      // never the smaller (farther) one
      const delay = 36 + (5 - q.o) * 26;
      const kf = bake((p) => {
        const e = curve(p), a = lmix(ZOOM.s0, 1, e), u = 1 - e;
        return {
          opacity: r4(smooth(seg(p, 0, 0.16))),
          transform: tf({ x: -q.dx * (1 - a), y: -q.dy * (1 - a), rx: (12 - q.ny * 6) * u, ry: -q.nx * 14 * u, sx: a }),
        };
      });
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "backwards" });
      rise(c, q.el, delay + 190, { dur: 380, step: 14 });
    }
    return cleanup;
  },
  close(c) {
    const { g } = c, total = 750, dur = 670;
    // moves at once and accelerates away into the centre
    const curve = bezier(0.45, 0.06, 0.8, 0.52);
    for (const q of g.cards) {
      // the outer tiles leave first, so the slab never has a tile poking past its edge
      const delay = (1 - q.d / g.maxD) * 60;
      const kf = bake((p) => {
        const e = curve(p), a = lmix(1, ZOOM.s1, e);
        return {
          opacity: r4(1 - smooth(seg(p, 0.5, 0.92))),
          transform: tf({ x: -q.dx * (1 - a), y: -q.dy * (1 - a), rx: (-8 - q.ny * 5) * e, ry: -q.nx * 10 * e, sx: a }),
        };
      });
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "forwards" });
    }
    // the bloom folds back into the centre around the tiles, on their clock (it used to run ahead
    // and be gone while the half-size tiles were still crossing the bare desktop), fading over its
    // second half, so it is gone just before the last tile
    return zoomSky(c, { open: false, curve, dur: 650, delay: 30, total });
  },
};

// ---- shatter: tiles tumble in from beyond the edges while the sky floods in from the edges
// like ink; closing, they burst outwards from the centre and the sky clears from the middle
// The ink: a hole whose (heavily feathered) edge starts just beyond the screen corners and closes
// on the centre while the hole itself fills in; closing, the hole opens again from the centre.
function inkSky(c, { open, dur, delay, ease, total }) {
  const R = cornerR(c.g);
  if (open) {
    return skyRun(c, { mask: "ink", dur, delay, total,
      r: (p) => R * (1 - ease(p)), a: (p) => smooth(seg(p, 0.35, 1)), o: (p) => inO(p, 0.5),
      k: (p) => mix(1.05, 1, ease(p)), b: (p) => mix(0.6, 1, ease(p)), s: (p) => mix(0.7, 1, ease(p)) });
  }
  return skyRun(c, { mask: "ink", dur, delay, total,
    r: (p) => R * ease(p), a: (p) => 1 - smooth(seg(p, 0, 0.8)), o: (p) => outO(p, 0.45),
    k: (p) => mix(1, 1.05, ease(p)), b: (p) => mix(1, 0.6, ease(p)), s: (p) => mix(1, 0.7, ease(p)) });
}
const tumbleSide = (q) => (Math.abs(q.ux) > 0.25 ? Math.sign(q.ux) : q.o % 2 ? 1 : -1);
FX.shatter = {
  open(c) {
    const { g } = c, total = 1000;
    // the ink has closed behind every tile before it lands (the centre fills in last, by 62%)
    const cleanup = inkSky(c, { open: true, dur: 620, delay: 0, ease: bezier(0.3, 0.15, 0.35, 1), total });
    // separate springs for position, rotation and scale; only a touch of overshoot, along the path
    const pos = spring(0.025, 5.2), rot = spring(0.05, 5), sc = spring(0.04, 5.2);
    for (const q of g.cards) {
      const delay = 70 + q.o * 42, dur = 720;
      const m = 6 * g.rem + 0.22 * Math.max(q.w, q.h);
      const D = offDistance(q, q.ux, q.uy, m, g);
      const side = tumbleSide(q);
      const rz0 = -side * (22 + (q.o % 3) * 7), rx0 = -q.uy * 16, ry0 = q.ux * 18, s0 = 1.14;
      const kf = bake((p) => {
        const e = pos(p), u = 1 - e, ur = 1 - rot(p), bow = Math.sin(Math.PI * clamp01(u)) * 0.1 * D * side;
        return {
          opacity: r4(smooth(seg(p, 0, 0.12))),
          transform: tf({ x: q.ux * D * u - q.uy * bow, y: q.uy * D * u + q.ux * bow, rx: rx0 * ur, ry: ry0 * ur, rz: rz0 * ur, sx: mix(s0, 1, sc(p)) }),
        };
      });
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "backwards" });
      rise(c, q.el, delay + 150, { dur: 400, step: 16 });
    }
    return cleanup;
  },
  close(c) {
    const { g } = c, total = 750;
    // impulse then drag: the tiles keep flying (and fading) right to the end
    const blast = outPow(1.7);
    for (const q of g.cards) {
      const delay = 10 + (q.d / g.maxD) * 60, dur = 670; // the shock wave reaches the centre tiles first
      const m = 3 * g.rem + 0.35 * Math.max(q.w, q.h);
      const D = offDistance(q, q.ux, q.uy, m, g);
      const side = tumbleSide(q);
      const rz1 = side * (48 + (q.o % 3) * 14), rx1 = q.uy * 34, ry1 = -q.ux * 38;
      const G = 2 * g.rem;
      const kf = bake((p) => {
        const pre = smooth(seg(p, 0, 0.11)) * (1 - smooth(seg(p, 0.11, 0.24))); // gather before the burst
        const e = blast(seg(p, 0.11, 1));
        return {
          opacity: r4(1 - smooth(seg(p, 0.42, 1))),
          transform: tf({ x: q.ux * (D * e - pre * G), y: q.uy * (D * e - pre * G), rx: rx1 * e, ry: ry1 * e, rz: rz1 * e, sx: mix(1 - 0.06 * pre, 1.2, e) }),
        };
      });
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "forwards" });
    }
    // the sky clears from the centre and is gone just before the last tile
    return inkSky(c, { open: false, dur: 600, delay: 70, ease: bezier(0.45, 0.05, 0.55, 0.95), total });
  },
};

// ---- slide: each tile glides in from (and out to) a screen edge
function slideVector(q, g) {
  const m = 7 * g.rem; // shadow included
  const L = { ux: -1, uy: 0, D: q.r + m }, R = { ux: 1, uy: 0, D: g.W - q.l + m };
  const U = { ux: 0, uy: -1, D: q.b + m }, B = { ux: 0, uy: 1, D: g.H - q.t + m };
  // tiles in a side column below the top row share that column's edge, so the column moves as one
  const below = q.t > g.H * 0.22;
  if (below && q.l > g.W * 0.6) return R;
  if (below && q.r < g.W * 0.4) return L;
  return [L, R, U, B].reduce((a, b) => (b.D < a.D ? b : a));
}
FX.slide = {
  open(c) {
    const { g } = c, total = 1000;
    fadeSky(c, true, total);
    const glide = bezier(0.25, 0.75, 0.2, 1);
    for (const q of g.cards) {
      const v = slideVector(q, g), delay = 30 + q.o * 36, dur = 780;
      const kf = bake((p) => {
        const u = 1 - glide(p);
        return { transform: tf({ x: v.ux * v.D * u, y: v.uy * v.D * u }) };
      });
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "backwards" });
      rise(c, q.el, delay + 120, { dur: 400, step: 16 });
    }
  },
  close(c) {
    const { g } = c, total = 750;
    // moves on the first frame and accelerates out
    const go = bezier(0.32, 0, 0.78, 0.2);
    for (const q of g.cards) {
      const v = slideVector(q, g), delay = (5 - q.o) * 24, dur = 630;
      const kf = bake((p) => {
        const e = go(p);
        return { opacity: r4(1 - smooth(seg(p, 0.7, 1))), transform: tf({ x: v.ux * v.D * e, y: v.uy * v.D * e }) };
      });
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "forwards" });
    }
    fadeSky(c, false, total);
  },
};

// ---- swirl: tiles spiral out of the centre, all one size until they near their places; the
// sky opens from the centre with them, turning as it grows
const SWIRL = { turn: 155, spin: 64, start: 3.2 };
// e: 0 = at the centre, 1 = home (position, spin, tilt); m: 0 = common size, 1 = own size
function swirlPose(q, g, e, m, Sref) {
  const u = 1 - e;
  const th = Math.atan2(q.dy, q.dx) - (SWIRL.turn * Math.PI / 180) * u;
  const S = lmix(SWIRL.start * g.rem, Sref, e);
  const w = lmix(S, q.w, m), h = lmix(S, q.h, m);
  const rz = -SWIRL.spin * u;
  // keep the tile's (rotated) box on screen: limit the radius in its current direction
  const cr = Math.abs(Math.cos(rz * Math.PI / 180)), sr = Math.abs(Math.sin(rz * Math.PI / 180));
  const ex = cr * w / 2 + sr * h / 2, ey = sr * w / 2 + cr * h / 2, M = 1.25 * g.rem;
  const ct = Math.abs(Math.cos(th)), st = Math.abs(Math.sin(th));
  let lim = Infinity;
  if (ct > 1e-3) lim = Math.min(lim, (g.W / 2 - ex - M) / ct);
  if (st > 1e-3) lim = Math.min(lim, (g.H / 2 - ey - M) / st);
  // soft limit (no kink where it starts to bind), hardening towards home so the tile still
  // lands exactly on its place
  const free = q.d * e;
  const r = softmin(free, Math.max(0, lim), 0.03 * g.W * u + 1);
  return tf({
    x: g.cx + r * Math.cos(th) - q.x, y: g.cy + r * Math.sin(th) - q.y,
    rx: (10 - q.ny * 5) * u, ry: -q.nx * 12 * u, rz, sx: w / q.w, sy: h / q.h,
  });
}
// The background blooms out of the centre, turning as it grows (and back in, turning on)
function swirlSky(c, { open, dur, delay, ease, total }) {
  const R = cornerR(c.g), VE = veilEnd(c.g);
  const e = open ? ease : (p) => 1 - ease(p);
  return skyRun(c, { mask: "bloom", dur, delay, total,
    v: (p) => lmix(0.08 * VE, VE, e(p)),
    r: (p) => R * lmix(0.08, 1, e(p)), a: open ? (p) => smooth(seg(p, 0.4, 1)) : (p) => 1 - smooth(seg(p, 0, 0.55)),
    o: open ? (p) => inO(p, 0.7) : (p) => outO(p, 0.45),
    rot: (p) => (open ? -24 : 24) * Math.pow(1 - e(p), 3), k: (p) => mix(1.2, 1, e(p)),
    b: (p) => mix(0.6, 1, e(p)), s: (p) => mix(0.7, 1, e(p)) });
}
const swirlRef = (g) => Math.exp(g.cards.reduce((a, q) => a + Math.log(Math.sqrt(q.w * q.h)), 0) / g.cards.length) * 0.7;
FX.swirl = {
  open(c) {
    const { g } = c, total = 1000, Sref = swirlRef(g);
    const path = bezier(0.3, 0.3, 0.2, 1);
    const cleanup = swirlSky(c, { open: true, dur: 800, delay: 0, ease: path, total });
    for (const q of g.cards) {
      const delay = q.o * 34, dur = 790;
      // one common size for the whole spiral; each tile takes its own shape over the last 42%
      const kf = bake((p) => ({ opacity: r4(smooth(seg(p, 0, 0.16))), transform: swirlPose(q, g, path(p), smooth(seg(p, 0.58, 1)), Sref) }), 56);
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "backwards" });
      rise(c, q.el, delay + 0.5 * dur, { dur: 340, step: 12 });
    }
    return cleanup;
  },
  close(c) {
    const { g } = c, total = 750, Sref = swirlRef(g);
    const path = bezier(0.55, 0, 0.78, 0.5);
    for (const q of g.cards) {
      const delay = (5 - q.o) * 22, dur = 640;
      // the reverse: each tile first takes the common size, then spirals into the centre
      const kf = bake((p) => ({ opacity: r4(1 - smooth(seg(p, 0.74, 1))), transform: swirlPose(q, g, 1 - path(p), 1 - smooth(seg(p, 0, 0.42)), Sref) }), 56);
      c.A(q.el, kf, { duration: c.T(dur), delay: c.T(delay), easing: "linear", fill: "forwards" });
    }
    // the bloom closes with the tiles, fading over its second half, and is gone just before the
    // last of them
    return swirlSky(c, { open: false, dur: 690, delay: 40, ease: bezier(0.5, 0, 0.75, 0.5), total });
  },
};

// ---- reduced motion: a short cross-fade, whatever the type. Opening, the sky leads and the tiles
// follow; closing, the sky goes with the tiles, a little ahead of the last of them.
const REDUCED = {
  open(c) {
    const D = 260;
    skyOpacity(c, bake((p) => ({ opacity: r4(outPow(2)(p)) }), 8), { duration: c.T(D * 0.6), easing: "linear" }, D);
    for (const card of c.cards) c.A(card, [{ opacity: 0 }, { opacity: 1 }], { duration: c.T(D * 0.7), delay: c.T(D * 0.3), easing: "ease-out", fill: "backwards" });
  },
  close(c) {
    const D = 200;
    for (const card of c.cards) c.A(card, [{ opacity: 1 }, { opacity: 0 }], { duration: c.T(D), easing: "ease-in", fill: "forwards" });
    skyOpacity(c, bake((p) => ({ opacity: r4(1 - smooth(p)) }), 8), { duration: c.T(D * 0.8), delay: c.T(D * 0.1), easing: "linear" }, D);
  },
};
