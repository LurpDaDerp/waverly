// Adaptive sky: time phase x weather -> gradient + accent, plus a quiet ambient weather layer.

const rad = Math.PI / 180;

// ---------------------------------------------------------------- NOAA solar equations
// General Solar Position Calculations (NOAA Global Monitoring Division).
export function sunTimes(day, lat, lon) {
  if (lat == null || lon == null) {
    const at = (h, m) => new Date(day.getFullYear(), day.getMonth(), day.getDate(), h, m);
    return { dawn: at(6, 30), sunrise: at(7, 0), sunset: at(19, 0), dusk: at(19, 30) };
  }
  const y = day.getFullYear(), mo = day.getMonth(), d = day.getDate();
  const doy = Math.round((Date.UTC(y, mo, d) - Date.UTC(y, 0, 1)) / 864e5) + 1;
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const g = (2 * Math.PI / (leap ? 366 : 365)) * (doy - 1);
  const eqt = 229.18 * (0.000075 + 0.001868 * Math.cos(g) - 0.032077 * Math.sin(g)
    - 0.014615 * Math.cos(2 * g) - 0.040849 * Math.sin(2 * g));
  const decl = 0.006918 - 0.399912 * Math.cos(g) + 0.070257 * Math.sin(g) - 0.006758 * Math.cos(2 * g)
    + 0.000907 * Math.sin(2 * g) - 0.002697 * Math.cos(3 * g) + 0.00148 * Math.sin(3 * g);
  const la = lat * rad;
  const ha = (zenith) => {
    const c = Math.cos(zenith * rad) / (Math.cos(la) * Math.cos(decl)) - Math.tan(la) * Math.tan(decl);
    return Math.acos(Math.max(-1, Math.min(1, c))) / rad;
  };
  const at = (mins) => new Date(Date.UTC(y, mo, d) + mins * 60000);
  const h0 = ha(90.833), h6 = ha(96);
  return {
    dawn: at(720 - 4 * (lon + h6) - eqt),
    sunrise: at(720 - 4 * (lon + h0) - eqt),
    sunset: at(720 - 4 * (lon - h0) - eqt),
    dusk: at(720 - 4 * (lon - h6) - eqt),
  };
}

export function phaseAt(now, sun) {
  const M = 60000;
  if (now < sun.dawn || now >= sun.dusk) return "night";
  if (now < +sun.sunrise + 45 * M) return "dawn";
  if (now < +sun.sunset - 30 * M) return "day";
  return "dusk";
}

// ---------------------------------------------------------------- weather state
export function weatherState(w) {
  // Spec: fall back to the last answer if it is under 3 h old, otherwise clear.
  if (!w || !w.current || Date.now() / 1000 - w.fetched_at > 3 * 3600) return { kind: "clear", level: 0 };
  const c = w.current.weather_code, cc = w.current.cloud_cover ?? 0;
  if ([95, 96, 99].includes(c)) return { kind: "storm", level: 2 };
  if ([71, 73, 75, 77, 85, 86].includes(c)) return { kind: "snow", level: { 71: 0, 77: 0, 85: 0, 73: 1 }[c] ?? 2 };
  if ((c >= 51 && c <= 57) || (c >= 61 && c <= 67) || (c >= 80 && c <= 82))
    return { kind: "rain", level: [51, 56, 61, 66, 80].includes(c) ? 0 : [53, 63, 81].includes(c) ? 1 : 2 };
  if (c === 45 || c === 48) return { kind: "fog", level: 0 };
  if (c === 3 || cc >= 60) return { kind: "cloudy", level: 0 };
  return { kind: "clear", level: 0 };
}

// ---------------------------------------------------------------- palettes (top, middle, bottom, accent)
const P = {
  dawn: {
    clear: ["#6E8FD0", "#E7A6A1", "#F8D29A", "#B4462C"], cloudy: ["#8C93A8", "#C3A7A5", "#E2CBB5", "#8E4B3A"],
    fog: ["#B3B1BA", "#D4C6C2", "#EADDD2", "#7E5244"], rain: ["#5F6A84", "#9C8C98", "#C9B3AE", "#93413A"],
    snow: ["#9DA9C6", "#D6C7CF", "#F1E4E0", "#8C4A5C"], storm: ["#3E4560", "#74657A", "#A3878A", "#8A3A52"],
  },
  day: {
    clear: ["#2E7FD8", "#5FA6EA", "#A9D3F5", "#165EB8"], cloudy: ["#7C8EA3", "#9EAEC0", "#C8D2DD", "#33506F"],
    fog: ["#A9B3BC", "#C3CAD0", "#DDE1E4", "#435463"], rain: ["#4E6278", "#6F8398", "#98A9BA", "#22579A"],
    snow: ["#8FA6C0", "#B8C8D9", "#E4EBF2", "#2F5F8F"], storm: ["#2E3A4C", "#4A5668", "#6F7A8A", "#4C3FB0"],
  },
  dusk: {
    clear: ["#1F2752", "#7A3E6E", "#E07A4F", "#FFB27A"], cloudy: ["#262A3E", "#594658", "#9A6A62", "#F2A98A"],
    fog: ["#33333F", "#5A5059", "#8A7470", "#EDBBA7"], rain: ["#1C2233", "#3E3B52", "#6E5260", "#F3A293"],
    snow: ["#2C3150", "#6A5A78", "#B08A94", "#F7C3CC"], storm: ["#16182A", "#33284A", "#5E3550", "#D8A2FF"],
  },
  night: {
    clear: ["#040610", "#0A0F20", "#151B30", "#A3BEFF"], cloudy: ["#0E121B", "#1A202C", "#2A313E", "#AFBCD2"],
    fog: ["#161A20", "#232830", "#353B44", "#BCC6D0"], rain: ["#0A0F18", "#141C2A", "#222C3C", "#93B6EC"],
    snow: ["#141A2C", "#222B42", "#3A4560", "#CBD8FF"], storm: ["#07070F", "#14122A", "#241E3E", "#BBA2FF"],
  },
};

const COVER = { clear: 0, cloudy: 0.3, fog: 0.22, rain: 0.38, snow: 0.24, storm: 0.5 };

// The tone a sky calls for: dark cards and light ink at dusk and night, the reverse by day.
export const skyTone = (phase) => (phase === "dawn" || phase === "day" ? "light" : "dark");
// A theme forced against the sky (light at night, dark by day) borrows the accent of the
// nearest phase whose tone matches, so highlights stay legible on the cards.
const ACCENT_FROM = { light: { dusk: "dawn", night: "day" }, dark: { dawn: "dusk", day: "night" } };

// theme: "adaptive" (the cards follow the sky), "light" or "dark" (the cards keep that
// tone while the sky still follows the time and the weather).
export function applyTheme(phase, wx, theme = "adaptive") {
  const [top, mid, bot] = P[phase][wx.kind];
  const sky = skyTone(phase);
  const tone = theme === "light" || theme === "dark" ? theme : sky;
  const accent = P[tone === sky ? phase : ACCENT_FROM[tone][phase]][wx.kind][3];
  const b = document.body, s = b.style;
  s.setProperty("--sky-top", top);
  s.setProperty("--sky-mid", mid);
  s.setProperty("--sky-bot", bot);
  s.setProperty("--accent", accent);
  b.dataset.tone = tone;
  b.dataset.sky = sky;
  b.dataset.phase = phase;
  b.dataset.wx = wx.kind;
  s.setProperty("--glow", wx.kind === "clear" && (phase === "day" || phase === "dawn") ? 1 : 0);
  s.setProperty("--moon", wx.kind === "clear" && phase === "night" ? 1 : 0);
  s.setProperty("--cover", COVER[wx.kind]);
  return tone;
}

// ---------------------------------------------------------------- ambient layer
const rnd = (a, b) => a + Math.random() * (b - a);
const approach = (cur, target, dt, tau) => cur + (target - cur) * (1 - Math.exp(-dt / tau));

function cloudSprite(seed) {
  const c = document.createElement("canvas");
  c.width = 900; c.height = 380;
  const x = c.getContext("2d");
  let s = seed;
  const r = () => ((s = (s * 9301 + 49297) % 233280) / 233280);
  for (let i = 0; i < 22; i++) {
    const t = i / 21;
    const cx = 120 + t * 660 + (r() - 0.5) * 80;
    const cy = 230 - Math.sin(t * Math.PI) * (70 + r() * 60) + (r() - 0.5) * 30;
    const rr = 70 + Math.sin(t * Math.PI) * 90 + r() * 40;
    const g = x.createRadialGradient(cx, cy, 0, cx, cy, rr);
    g.addColorStop(0, "rgba(255,255,255,0.55)");
    g.addColorStop(0.55, "rgba(255,255,255,0.22)");
    g.addColorStop(1, "rgba(255,255,255,0)");
    x.fillStyle = g;
    x.fillRect(cx - rr, cy - rr, rr * 2, rr * 2);
  }
  // The tallest puffs reach past the sprite's top (and the end ones past its sides):
  // fade the edges out so a cloud never shows a straight cut line, least of all in a
  // still (unanimated) sky where it would stay put.
  x.globalCompositeOperation = "destination-in";
  const fade = (x0, y0, x1, y1, stops) => {
    const g = x.createLinearGradient(x0, y0, x1, y1);
    for (const [at, a] of stops) g.addColorStop(at, `rgba(0,0,0,${a})`);
    x.fillStyle = g;
    x.fillRect(0, 0, c.width, c.height);
  };
  fade(0, 0, 0, c.height, [[0, 0], [0.3, 1], [0.94, 1], [1, 0]]);
  fade(0, 0, c.width, 0, [[0, 0], [0.09, 1], [0.91, 1], [1, 0]]);
  return c;
}

function blobSprite(w, h, alpha) {
  const c = document.createElement("canvas");
  c.width = w; c.height = h;
  const x = c.getContext("2d");
  x.translate(w / 2, h / 2);
  x.scale(w / h, 1);
  const g = x.createRadialGradient(0, 0, 0, 0, 0, h / 2);
  g.addColorStop(0, `rgba(255,255,255,${alpha})`);
  g.addColorStop(1, "rgba(255,255,255,0)");
  x.fillStyle = g;
  x.fillRect(-h / 2, -h / 2, h, h);
  return c;
}

// Weather detail: high = everything; medium = the clouds and about half the particles, no
// fog and no storm washes (and app.js animates it at 30 fps); low = no ambient layer at all
// (the sky is its gradient and cover).
// The share of rain, snow and stars each level keeps:
const DETAIL = { high: 1, medium: 0.5, low: 0 };
// With animation off the layer is drawn once, in its settled state, and drawn again only
// when the phase, weather, detail, size or title layout changes: no per-frame sky work.

export class Ambient {
  constructor(canvas) {
    this.cv = canvas;
    this.ctx = canvas.getContext("2d");
    this.running = false;
    this.t0 = performance.now();
    this.last = 0;
    this.avoid = [];
    this.avoidKey = "";
    this.detail = "high";
    this.animated = true;
    this.dirty = true;            // a static layer must be drawn again
    this.storm = false;
    this.target = { far: 0.1, near: 0.06, fog: 0, rain: 0, snow: 0, stars: 0, streak: 0.3 };
    this.cur = { ...this.target };
    this.sprites = [cloudSprite(7), cloudSprite(91), cloudSprite(313)];
    this.fogSprite = blobSprite(1400, 220, 0.5);
    this.flake = blobSprite(24, 24, 0.95);
    this.resize();
    window.addEventListener("resize", () => this.resize());
  }

  get enabled() { return this.detail !== "low"; }
  // true when the page should call frame() on the next animation frame
  get needsFrame() { return this.running && this.enabled && (this.animated || this.dirty); }
  // The longest gap (ms) between animated draws that still looks the same. Clouds drift
  // 6-20 px/s at low alpha and stars twinkle slowly: about 20 fps is enough, and every draw
  // re-blurs the cards' backdrops. Rain, snow and fog (and particles still fading out) need
  // every frame.
  get minFrameMs() {
    const T = this.target;
    const busy = T.rain || T.snow || T.fog || this.cur.fog > 0.01
      || this.drops.some((d) => d.w > 0.01) || this.flakes.some((f) => f.w > 0.01);
    return busy ? 0 : 46; // every 3rd frame at 60 Hz
  }

  configure({ detail, animated }) {
    detail = Object.hasOwn(DETAIL, detail) ? detail : "high";
    animated = animated !== false;
    if (detail === this.detail && animated === this.animated) return;
    const wasEnabled = this.enabled;
    this.detail = detail;
    this.animated = animated;
    if (!this.enabled) {
      // low: no canvas at all (its backing store is released too)
      this.cv.style.display = "none";
      this.cv.width = this.cv.height = 0;
    } else if (!wasEnabled) {
      this.cv.style.display = "";
      this.resize();
    }
    if (this.wx) this.set(this.phase, this.wx);
    this.dirty = true;
  }

  resize() {
    if (!this.enabled) return; // sized again when the layer comes back
    // the sky layer overhangs the screen a little (room for parallax): match its real size
    this.w = this.cv.width = Math.round(this.cv.clientWidth || window.innerWidth);
    this.h = this.cv.height = Math.round(this.cv.clientHeight || window.innerHeight);
    const W = this.w, H = this.h;
    this.far = Array.from({ length: 4 }, (_, i) => ({ x: (i / 4) * W * 1.4 - W * 0.2, y: rnd(0.02, 0.32) * H, s: rnd(1.3, 1.8), k: i % 3, v: rnd(6, 10) }));
    this.near = Array.from({ length: 3 }, (_, i) => ({ x: (i / 3) * W * 1.5 - W * 0.25, y: rnd(0.18, 0.55) * H, s: rnd(1.9, 2.5), k: (i + 1) % 3, v: rnd(14, 20) }));
    this.fogBands = Array.from({ length: 5 }, (_, i) => ({ x: rnd(-0.3, 0.9) * W, y: (0.52 + i * 0.1) * H, s: rnd(1, 1.6), v: rnd(-12, 12) || 6 }));
    this.drops = Array.from({ length: 52 }, (_, i) => ({ i, x: rnd(0, W), y: rnd(-H, H), len: rnd(38, 72), v: rnd(1350, 1850), w: 0 }));
    this.flakes = Array.from({ length: 36 }, (_, i) => ({ i, x: rnd(0, W), y: rnd(-H, H), r: rnd(3, 7), v: rnd(36, 80), ph: rnd(0, 6.28), sw: rnd(14, 34), w: 0 }));
    this.stars = Array.from({ length: 44 }, () => ({ x: rnd(0.02, 0.98) * W, y: rnd(0.02, 0.6) * H, r: rnd(0.7, 1.9), ph: rnd(0, 6.28), sp: rnd(0.6, 1.6) }));
    this.dirty = true;
  }

  setAvoid(rects) {
    // screen rects -> canvas coordinates
    const o = this.cv.getBoundingClientRect();
    this.avoid = rects.map((r) => ({ left: r.left - o.left, right: r.right - o.left, top: r.top - o.top, bottom: r.bottom - o.top }));
    const key = this.avoid.map((r) => `${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.right)},${Math.round(r.bottom)}`).join(";");
    if (key !== this.avoidKey) { this.avoidKey = key; this.dirty = true; }
  }

  // Particles thin out over titles: 1 away from titles, 0.2 inside them.
  thin(x, y) {
    let f = 1;
    for (const r of this.avoid) {
      const dx = Math.max(r.left - x, 0, x - r.right), dy = Math.max(r.top - y, 0, y - r.bottom);
      const d = Math.hypot(dx, dy);
      if (d < 80) f = Math.min(f, 0.2 + 0.8 * (d / 80));
    }
    return f;
  }

  set(phase, wx) {
    this.phase = phase;
    this.wx = wx;
    const k = DETAIL[this.detail];
    const pf = { day: 1, dawn: 0.95, dusk: 0.7, night: 0.45 }[phase];
    const base = { clear: [0.1, 0.06], cloudy: [0.42, 0.34], fog: [0.2, 0.14], rain: [0.36, 0.3], snow: [0.3, 0.24], storm: [0.48, 0.4] }[wx.kind];
    const target = {
      far: base[0] * pf, near: base[1] * pf,
      fog: wx.kind === "fog" && this.detail === "high" ? 1 : 0,
      rain: Math.round(k * (wx.kind === "rain" ? [24, 36, 52][wx.level] : wx.kind === "storm" ? 52 : 0)),
      snow: Math.round(k * (wx.kind === "snow" ? [16, 26, 36][wx.level] : 0)),
      stars: wx.kind === "clear" && phase === "night" ? 1 : 0,
      streak: phase === "day" || phase === "dawn" ? 0.42 : 0.26,
    };
    const storm = wx.kind === "storm";
    if (storm === this.storm && Object.keys(target).every((key) => target[key] === this.target[key])) return;
    this.target = target;
    this.storm = storm;
    this.dirty = true;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.dirty = true;
    this.last = performance.now();
    this.nextWash = this.last + rnd(4000, 8000);
  }

  stop() { this.running = false; }

  frame(now) {
    if (!this.running || !this.enabled) return;
    // animated: everything moves and eases toward the target; static: one still picture
    // of the settled state (particles spread over the whole height, nothing moves)
    const live = this.animated;
    const dt = live ? Math.min(0.1, (now - this.last) / 1000) : 0; // (a cloudy sky draws every 50 ms)
    this.last = now;
    this.dirty = false;
    const t = (now - this.t0) / 1000;
    const c = this.cur, T = this.target;
    if (live) for (const k of ["far", "near", "fog", "stars", "streak"]) c[k] = approach(c[k], T[k], dt, 1.0);
    else Object.assign(c, T);
    const x = this.ctx, W = this.w, H = this.h;
    const wrap = (y) => (live || y >= 0 ? y : y + H);
    x.clearRect(0, 0, W, H);

    // stars and clouds (medium: every other star)
    if (c.stars > 0.01) {
      x.fillStyle = "#fff";
      const step = this.detail === "high" ? 1 : 2;
      for (let i = 0; i < this.stars.length; i += step) {
        const s = this.stars[i];
        x.globalAlpha = c.stars * (0.35 + 0.45 * (0.5 + 0.5 * Math.sin(t * s.sp + s.ph))) * this.thin(s.x, s.y);
        x.beginPath(); x.arc(s.x, s.y, s.r, 0, 6.283); x.fill();
      }
    }
    const drawLayer = (arr, a) => {
      if (a < 0.005) return;
      x.globalAlpha = a;
      for (const k of arr) {
        k.x += k.v * dt;
        const sp = this.sprites[k.k], w = sp.width * k.s, h = sp.height * k.s;
        if (k.x > W + 40) k.x = -w - rnd(0, W * 0.2);
        x.drawImage(sp, k.x, k.y - h / 2, w, h);
      }
    };
    drawLayer(this.far, c.far);
    drawLayer(this.near, c.near);

    // fog (high detail only)
    if (c.fog > 0.01) {
      x.globalAlpha = c.fog * 0.55;
      for (const b of this.fogBands) {
        b.x += b.v * dt;
        const w = this.fogSprite.width * b.s, h = this.fogSprite.height * b.s;
        if (b.x > W + 50) b.x = -w; else if (b.x < -w - 50) b.x = W;
        x.drawImage(this.fogSprite, b.x, b.y - h / 2, w, h);
      }
    }

    // rain: thin slanted streaks
    const slant = 0.2;
    x.strokeStyle = "#fff"; x.lineWidth = 1.4; x.lineCap = "round";
    for (const d of this.drops) {
      d.w = live ? approach(d.w, d.i < T.rain ? 1 : 0, dt, 0.9) : d.i < T.rain ? 1 : 0;
      if (d.w < 0.01) continue;
      d.y += d.v * dt; d.x += d.v * slant * dt;
      if (d.y - d.len > H) { d.y = -rnd(0, 200); d.x = rnd(-0.2 * W, W); }
      const y = wrap(d.y);
      x.globalAlpha = d.w * c.streak * this.thin(d.x, y);
      x.beginPath(); x.moveTo(d.x, y); x.lineTo(d.x - d.len * slant, y - d.len); x.stroke();
    }
    // snow: swaying flakes
    for (const f of this.flakes) {
      f.w = live ? approach(f.w, f.i < T.snow ? 1 : 0, dt, 0.9) : f.i < T.snow ? 1 : 0;
      if (f.w < 0.01) continue;
      f.y += f.v * dt;
      if (f.y > H + 20) { f.y = -20; f.x = rnd(0, W); }
      const sx = f.x + Math.sin(t * 0.9 + f.ph) * f.sw, y = wrap(f.y);
      x.globalAlpha = f.w * 0.85 * this.thin(sx, y);
      x.drawImage(this.flake, sx - f.r, y - f.r, f.r * 2, f.r * 2);
    }
    x.globalAlpha = 1;

    // storm: a soft wash about every 10 s (0.7 s up, 1.4 s down), never a flash
    // (animated, high detail only)
    if (live && this.storm && this.detail === "high" && now >= this.nextWash) {
      this.nextWash = now + rnd(8500, 11500);
      document.querySelector(".sky-wash")?.animate(
        [{ opacity: 0 }, { opacity: 0.32, offset: 0.333 }, { opacity: 0 }],
        { duration: 2100, easing: "ease-in-out" });
    }
  }
}
