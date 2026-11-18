// Waverly website: the try-it demo (a small copy of the dashboard on a laptop that opens with
// a wave, a fist or a button), plus the nav hairline. Plain script, no dependencies; the hand
// tracker (assets/js/hands.js and MediaPipe) loads only after "Try it with your camera".
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduceMQ = matchMedia("(prefers-reduced-motion: reduce)");
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

  // ------------------------------------------------------------------ nav: a hairline once the page scrolls
  const nav = $(".nav");
  if (nav) {
    const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
    addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }

  const demo = $("[data-demo]");
  if (!demo) return;

  // ------------------------------------------------------------------ icons (from the app)
  const SUN_RAYS = (cx, cy, r1, r2) => Array.from({ length: 8 }, (_, i) => {
    const a = (i * Math.PI) / 4;
    return `M${(cx + Math.cos(a) * r1).toFixed(2)} ${(cy + Math.sin(a) * r1).toFixed(2)}L${(cx + Math.cos(a) * r2).toFixed(2)} ${(cy + Math.sin(a) * r2).toFixed(2)}`;
  }).join("");
  const MOON = (cx, cy, r) => `M${cx + r * 0.25} ${cy - r}a${r} ${r} 0 1 0 ${r * 0.75} ${r * 1.55}A${r * 0.82} ${r * 0.82} 0 0 1 ${cx + r * 0.25} ${cy - r}z`;
  const SMALL_CLOUD = "M9.2 20.4h8.6a3.6 3.6 0 0 0 .45-7.17 4.9 4.9 0 0 0-9.5 1.15A3 3 0 0 0 9.2 20.4z";
  let maskN = 0;
  const partMask = (id) => `<mask id="${id}" maskUnits="userSpaceOnUse" x="-4" y="-4" width="32" height="32"><rect x="-4" y="-4" width="32" height="32" fill="#fff"/><path d="${SMALL_CLOUD}" fill="#000" stroke="#000" stroke-width="3.6"/></mask>`;
  const ICONS = {
    sun: () => `<circle cx="12" cy="12" r="4.2"/><path d="${SUN_RAYS(12, 12, 7, 9.6)}"/>`,
    moon: () => `<path d="${MOON(11, 12, 7)}"/>`,
    partly: () => { const id = `pm${++maskN}`; return `<defs>${partMask(id)}</defs><g mask="url(#${id})"><circle cx="9" cy="8.6" r="3.3"/><path d="${SUN_RAYS(9, 8.6, 5.3, 7.1)}"/></g><path d="${SMALL_CLOUD}"/>`; },
    partlyNight: () => { const id = `pm${++maskN}`; return `<defs>${partMask(id)}</defs><g mask="url(#${id})"><path d="${MOON(8.4, 8.8, 4.6)}"/></g><path d="${SMALL_CLOUD}"/>`; },
    sunrise: () => `<path d="M5 18.5a7 7 0 0 1 14 0"/><path d="M2.5 21.5h19"/><path d="M12 3.2v6.4M9.2 6.2L12 3.2l2.8 3"/>`,
    sunset: () => `<path d="M5 18.5a7 7 0 0 1 14 0"/><path d="M2.5 21.5h19"/><path d="M12 9.6V3.2M9.2 6.6L12 9.6l2.8-3"/>`,
  };
  const icon = (n) => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${ICONS[n]()}</svg>`;

  // ------------------------------------------------------------------ formatting
  const pad2 = (n) => String(n).padStart(2, "0");
  const fmtDate = new Intl.DateTimeFormat("en-US", { weekday: "long", month: "long", day: "numeric" });
  const fmtShort = new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric" });
  const fmtWd = new Intl.DateTimeFormat("en-US", { weekday: "short" });
  const parts = (d) => ({ t: `${d.getHours() % 12 || 12}:${pad2(d.getMinutes())}`, ap: d.getHours() < 12 ? "AM" : "PM" });
  const plain = (d) => { const p = parts(d); return `${p.t} ${p.ap}`; };
  const timeHTML = (d) => { const p = parts(d); return `${p.t}<small>${p.ap}</small>`; };
  const range = (a, b) => `${parts(a).t}–${plain(b)}`;
  const hourLabel = (d) => `${d.getHours() % 12 || 12} ${d.getHours() < 12 ? "AM" : "PM"}`;
  const deg = (f) => `${f}°`;
  const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const daysBetween = (a, b) => Math.round((startOfDay(b) - startOfDay(a)) / 864e5);
  const greeting = (h) => (h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening") + ", Alex";
  const isDayHour = (h) => h >= 7 && h < 17;

  // ------------------------------------------------------------------ a sample day at plausible clock times
  const T0 = new Date();
  const M = 60000, H = 60 * M;
  const sod = startOfDay(T0);
  const at = (h, m = 0) => new Date(sod.getFullYear(), sod.getMonth(), sod.getDate(), h, m);
  const TAGS = {
    work: ["Work", "c-blue"], personal: ["Personal", "c-amber"], fitness: ["Fitness", "c-teal"],
    family: ["Family", "c-rose"], travel: ["Travel", "c-violet"], errands: ["Errands", "c-green"],
  };
  const pill = (t) => `<span class="tag ${TAGS[t][1]}">${TAGS[t][0]}</span>`;
  const EVENTS = [
    { title: "Morning run", tag: "fitness", s: at(7), e: at(7, 40) },
    { title: "Team standup", tag: "work", s: at(9), e: at(9, 15) },
    { title: "Design review", tag: "work", s: at(10, 30), e: at(11, 30), loc: "Room 4" },
    { title: "Lunch with Sam", tag: "personal", s: at(12, 30), e: at(13, 30) },
    { title: "Focus time", tag: "work", s: at(14), e: at(15, 30) },
    { title: "School pickup", tag: "family", s: at(16), e: at(16, 30) },
    { title: "Piano lesson", tag: "family", s: at(17), e: at(17, 45) },
    { title: "Dinner with Sam", tag: "personal", s: at(19), e: at(20, 30) },
    { title: "Pack for the trip", tag: "travel", s: at(21), e: at(21, 30) },
    { title: "Read before bed", tag: "personal", s: at(22, 15), e: at(23) },
  ];
  // the two "soon" tasks count down from page load and roll forward when they reach zero
  const TASKS = [
    { title: "Pick up dry cleaning", tag: "errands", due: new Date(+T0 + 47 * M + 13000), roll: 3 * H + 20 * M },
    { title: "Submit expense report", tag: "work", due: new Date(+T0 + 2 * H + 14 * M + 8000), roll: 5 * H + 40 * M },
    { title: "Water the plants", tag: "errands", due: new Date(+sod + 24 * H + 9 * H) },
    { title: "Book flights", tag: "travel", due: new Date(+sod + 2 * 24 * H + 18 * H) },
    { title: "Call the plumber", tag: "errands", due: new Date(+sod + 3 * 24 * H + 10 * H) },
    { title: "Long run", tag: "fitness", due: new Date(+sod + 4 * 24 * H + 8 * H) },
    { title: "Renew passport", tag: "personal", due: new Date(+sod + 9 * 24 * H + 12 * H) },
    { title: "Plan Sam's birthday", tag: "family", due: new Date(+sod + 12 * 24 * H + 12 * H) },
    { title: "Quarterly report", tag: "work", due: new Date(+sod + 15 * 24 * H + 17 * H) },
  ];
  // a gentle daily temperature curve, warmest mid-afternoon
  const tempAt = (d) => Math.round(53 + 9 * Math.cos(((d.getHours() + d.getMinutes() / 60 - 15) / 24) * 2 * Math.PI));

  function countdown(due, now) {
    const ms = due - now;
    if (ms < 864e5) {
      const s = Math.max(0, Math.floor(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
      return { html: h ? `${h}:${pad2(m)}:${pad2(x)}` : `${m}:${pad2(x)}`, cls: "soon" };
    }
    const days = Math.max(1, daysBetween(now, due));
    return { html: `${days}<small>${days === 1 ? "day" : "days"}</small>`, cls: "" };
  }

  // ------------------------------------------------------------------ render
  const setK = (k, html) => { for (const el of $$(`[data-k="${k}"]`)) if (el.innerHTML !== html) el.innerHTML = html; };

  function renderEvents(now) {
    const out = [];
    let placed = false;
    const nowLine = `<div class="now-line" data-now><span class="now-pill">Now<b>${plain(now)}</b></span></div>`;
    for (const e of EVENTS) {
      if (!placed && e.s > now) { out.push(nowLine); placed = true; }
      const state = e.e <= now ? "past" : e.s <= now ? "current" : "";
      let left = "", extra = "";
      if (state === "current") {
        const p = Math.min(1, (now - e.s) / (e.e - e.s));
        const mins = Math.max(1, Math.round((e.e - now) / M));
        left = `<span class="left">${mins >= 60 ? `${Math.floor(mins / 60)} h ${mins % 60} min` : `${mins} min`} left</span>`;
        extra = `<div class="progress" data-p="${p.toFixed(3)}"><i></i></div>`;
      }
      const loc = e.loc ? `<span>${e.loc}</span>` : "";
      out.push(`<div class="ev ${state}"${state === "current" ? " data-current" : ""}><div class="ev-time">${timeHTML(e.s)}</div><div><div class="ev-title">${e.title}</div><div class="meta">${pill(e.tag)}${loc}<span>${range(e.s, e.e)}</span>${left}</div>${extra}</div></div>`);
    }
    if (!placed) out.push(nowLine);
    setK("events", out.join(""));
    // set through the CSSOM: the site's CSP allows no inline style attributes
    for (const el of $$(".progress[data-p] i")) el.style.width = `${parseFloat(el.parentNode.dataset.p) * 100}%`;
  }

  function renderTasks(now) {
    setK("tasks", [...TASKS].sort((a, b) => a.due - b.due).map((t) => {
      const when = daysBetween(now, t.due) === 0 ? `Today, ${plain(t.due)}` : fmtShort.format(t.due);
      const c = countdown(t.due, now);
      return `<li class="dl"><span class="dot ${TAGS[t.tag][1]}"></span><div><div class="dl-title">${t.title}</div><div class="meta">${pill(t.tag)}<span>${when}</span></div></div><div class="count ${c.cls}" data-due="${+t.due}">${c.html}</div></li>`;
    }).join(""));
  }

  function renderWeather(now) {
    const day = isDayHour(now.getHours());
    setK("wxicon", icon(day ? "sun" : "moon"));
    setK("temp", deg(tempAt(now)));
    setK("cond", day ? "Sunny" : "Clear");
    setK("hilo", `<span>H ${deg(62)}</span><span>L ${deg(44)}</span>`);
    setK("chips", [["Feels like", deg(tempAt(now) - 2)], ["Wind", "6 mph"], ["Humidity", "64%"], ["Rain", "10%"]]
      .map(([a, b]) => `<div class="chip"><span>${a}</span><b>${b}</b></div>`).join(""));
    const h0 = new Date(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours());
    const items = [];
    for (let i = 0; i < 13; i++) {
      const d = new Date(+h0 + i * H);
      const h = d.getHours();
      const ic = isDayHour(h) ? (i % 4 === 2 ? "partly" : "sun") : (i % 4 === 2 ? "partlyNight" : "moon");
      items.push({ t: +d, html: `<div class="hr${i === 0 ? " is-now" : ""}"><span class="h">${i === 0 ? "Now" : hourLabel(d)}</span>${icon(ic)}<span class="tv">${deg(tempAt(i === 0 ? now : d))}</span></div>` });
    }
    // sunrise and sunset, when they fall inside the window
    for (const [hh, mm, kind] of [[6, 58, "sunrise"], [16, 41, "sunset"]]) {
      for (const dayOff of [0, 1]) {
        const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + dayOff, hh, mm);
        if (d > now && d < +h0 + 12 * H) items.push({ t: +d, html: `<div class="hr sun"><span class="h">${kind === "sunrise" ? "Sunrise" : "Sunset"}</span>${icon(kind)}<span class="tv">${parts(d).t}</span></div>` });
      }
    }
    items.sort((a, b) => a.t - b.t);
    setK("hourly", items.map((x) => x.html).join(""));
  }

  function renderClock(now) {
    const h = now.getHours();
    setK("hm", `${h % 12 || 12}:${pad2(now.getMinutes())}`);
    setK("ampm", h < 12 ? "AM" : "PM");
    setK("sec", pad2(now.getSeconds()));
    setK("date", fmtDate.format(now));
    setK("hello", greeting(h));
    setK("menuclock", `${fmtWd.format(now)} ${plain(now)}`);
  }

  // ------------------------------------------------------------------ scrolling the lists
  const hud = $(".demo-hud", demo);
  const sky = $(".hud-sky", hud);
  const cards = $$(".hc", hud);
  const SCROLLERS = {
    schedule: { card: $(".hc.sched", hud), axis: "y" },
    deadlines: { card: $(".hc.dead", hud), axis: "y" },
    weather: { card: $(".hc.weather", hud), axis: "x" },
  };
  for (const s of Object.values(SCROLLERS)) {
    s.vp = s.axis === "y" ? $(".viewport", s.card) : $(".hourly-vp", s.card);
    s.track = $(".track", s.vp);
    s.pos = 0;
    s.touched = -1e9;
  }
  const maxOf = (s) => (s.axis === "y" ? Math.max(0, s.track.scrollHeight - s.vp.clientHeight) : Math.max(0, s.track.scrollWidth - s.vp.clientWidth));
  function setPos(s, p) {
    s.pos = clamp(p, 0, maxOf(s));
    s.track.style.transform = s.axis === "y" ? `translateY(${(-s.pos).toFixed(1)}px)` : `translateX(${(-s.pos).toFixed(1)}px)`;
  }
  // keep "now" (or the current event) in the middle of the calendar, like the app
  function centerSchedule(force) {
    const s = SCROLLERS.schedule;
    if (!force && performance.now() - s.touched < 30000) return;
    const anchor = $("[data-current]", s.track) || $("[data-now]", s.track);
    if (anchor) setPos(s, anchor.offsetTop + anchor.offsetHeight / 2 - s.vp.clientHeight / 2);
  }

  function renderAll() {
    const now = new Date();
    renderClock(now);
    renderEvents(now);
    renderTasks(now);
    renderWeather(now);
    centerSchedule(true);
  }
  let lastMinute = Math.floor(Date.now() / M);
  function tick() {
    const now = new Date();
    renderClock(now);
    for (const el of $$(".count[data-due]", hud)) {
      const c = countdown(new Date(+el.dataset.due), now);
      if (el.innerHTML !== c.html) el.innerHTML = c.html;
      el.className = `count ${c.cls}`;
    }
    let rolled = false;
    for (const t of TASKS) if (t.roll && t.due <= now) { t.due = new Date(+now + t.roll); rolled = true; }
    if (rolled) renderTasks(now);
    // re-render when the minute changes (timers in background tabs skip seconds)
    const minute = Math.floor(+now / M);
    if (minute !== lastMinute) { lastMinute = minute; renderEvents(now); renderWeather(now); centerSchedule(false); }
  }
  renderAll();
  setTimeout(() => { tick(); setInterval(tick, 1000); }, 1000 - (Date.now() % 1000));
  addEventListener("resize", () => { centerSchedule(true); for (const s of Object.values(SCROLLERS)) setPos(s, s.pos); });
  document.fonts?.ready.then(() => centerSchedule(true));

  // ------------------------------------------------------------------ the demo's state
  const debug = new URLSearchParams(location.search).has("debug");
  const log = (...a) => { if (debug) console.info("[demo]", ...a); };
  const screen = $(".lap-screen", demo);
  const video = $(".pip video", demo);
  const hintEl = $("[data-demo-hint]", demo);
  const handEl = $("[data-demo-hand]", demo);
  const statusEl = $("#demo-status");
  const act = (a) => $(`[data-act="${a}"]`, demo);
  const say = document.createElement("p"); // short announcements for screen readers
  say.className = "sr-only";
  say.setAttribute("aria-live", "polite");
  demo.append(say);

  let isOpen = false, anims = [], scrolled = false;
  let cam = "off";           // off, loading, on, paused, denied, unsupported, error
  let wanted = false;        // the visitor turned the camera on (and has not turned it off)
  let inView = false;
  let hand = "none";         // none, hand, open, fist
  let hands = null;          // the hands.js module, once loaded
  let lostTimer = 0;
  let restingFist = false;   // the fist that just closed the dashboard is still up (it can't reopen it)

  const STATUS = {
    off: "",
    loading: "Getting things ready. The first time takes a few seconds.",
    on: "Your camera is on. The video stays on this page.",
    paused: "The camera is resting while this part of the page is out of view.",
    denied: "The camera isn't available, and that's okay. The buttons below work just as well.",
    unsupported: "This browser can't run the camera demo, and that's okay. The buttons below work just as well.",
    error: "The camera demo didn't start this time. The buttons below still work.",
  };
  const HAND = { none: "No hand yet", hand: "I see your hand", open: "Open hand", fist: "Fist" };

  function hint() {
    if (cam === "loading") return "Getting things ready…";
    if (cam === "on") {
      if (!isOpen) {
        if (hand === "none") return "Raise your hand, palm toward the camera";
        if (hand === "fist") return restingFist ? "All tucked away. Wave whenever you like" : "Now open your hand";
        return "Now give it a little wave";
      }
      if (hand === "fist") return "Hold that fist a moment";
      if (!scrolled) return "There it is. Move your open hand up or down to scroll";
      return "Make a fist to close it";
    }
    return isOpen ? "Press Scroll to move the lists, or Close" : "Press Open, or Shift H";
  }
  let lastHint = "";
  function refresh() {
    demo.dataset.cam = cam;
    demo.dataset.hud = isOpen ? "open" : "closed";
    demo.dataset.hand = cam === "on" ? hand : "none";
    const h = hint();
    if (h !== lastHint) {
      lastHint = h;
      hintEl.textContent = h;
      hintEl.classList.remove("fresh");
      void hintEl.offsetWidth;
      hintEl.classList.add("fresh");
    }
    handEl.textContent = HAND[hand];
    if (statusEl.textContent !== STATUS[cam]) statusEl.textContent = STATUS[cam];
    const label = cam === "denied" || cam === "error" ? "Try the camera again" : "Try it with your camera";
    const camBtn = act("camera");
    if (camBtn.lastChild.textContent !== label) camBtn.lastChild.textContent = label;
    act("stop").hidden = !wanted;
    act("open").disabled = isOpen;
    act("close").disabled = !isOpen;
    act("scroll").disabled = !isOpen;
  }

  // ------------------------------------------------------------------ open and close: Waverly's "fade"
  // The cards fly in from the screen's edges and lead; the sky comes up underneath at the same
  // time as a soft glow whose edges are so feathered they never show (mask-size grows a blurry
  // radial mask until it covers everything), so the cards stay the main event.
  const A = (el, kf, opt) => { const a = el.animate(kf, opt); anims.push(a); return a; };
  const stopAnims = () => { for (const a of anims) a.cancel(); anims = []; };
  function vec(el) {
    const r = el.getBoundingClientRect(), s = screen.getBoundingClientRect();
    return { nx: ((r.left + r.width / 2 - s.left) / s.width) * 2 - 1, ny: ((r.top + r.height / 2 - s.top) / s.height) * 2 - 1 };
  }
  function finish(open) {
    const mine = anims.slice();
    Promise.allSettled(mine.map((a) => a.finished)).then(() => {
      if (anims.length !== mine.length || anims.some((a, i) => a !== mine[i])) return; // a newer run took over
      if (isOpen === open) { stopAnims(); hud.classList.remove("moving"); }
    });
  }
  function openHud(by) {
    if (isOpen) return;
    isOpen = true;
    stopAnims();
    hud.classList.add("moving");
    refresh();
    if (reduceMQ.matches) {
      A(hud, [{ opacity: 0 }, { opacity: 1 }], { duration: 220, easing: "ease-out" });
    } else {
      A(sky, [
        { opacity: 0, maskSize: "70% 70%", filter: "brightness(.55) saturate(.7)" },
        { opacity: 0.85, offset: 0.55 },
        { opacity: 1, maskSize: "300% 300%", filter: "brightness(1) saturate(1)" },
      ], { duration: 1000, easing: "cubic-bezier(.3,0,.2,1)", fill: "backwards" });
      const ease = "cubic-bezier(.16,1,.3,1)";
      for (const card of cards) {
        const o = +card.dataset.enter || 0, { nx, ny } = vec(card);
        const delay = 30 + o * 35;
        A(card, [
          { opacity: 0, transform: `translate3d(${(nx * 15).toFixed(1)}em, ${(ny * 10 + 7).toFixed(1)}em, -70em) rotateX(${(12 - ny * 6).toFixed(1)}deg) rotateY(${(nx * -14).toFixed(1)}deg)` },
          { opacity: 1, offset: 0.55 },
          { opacity: 1, transform: "none" },
        ], { duration: 700, delay, easing: ease, fill: "backwards" });
        $$(".date, .hello, .time, .chips, .word", card).forEach((el, i) => {
          A(el, [{ opacity: 0, transform: "translate3d(0, 2.4em, 0)" }, { opacity: 1, transform: "none" }],
            { duration: 450, delay: delay + 100 + i * 20, easing: "cubic-bezier(.2,.8,.2,1)", fill: "backwards" });
        });
      }
    }
    finish(true);
    say.textContent = "The dashboard is open.";
    log("open", by);
  }
  function closeHud(by) {
    if (!isOpen) return;
    isOpen = false;
    stopAnims();
    hud.classList.add("moving");
    refresh();
    if (reduceMQ.matches) {
      A(hud, [{ opacity: 1 }, { opacity: 0 }], { duration: 200, easing: "ease-in", fill: "forwards" });
    } else {
      const ease = "cubic-bezier(.55,0,.8,.25)";
      for (const card of cards) {
        const o = +card.dataset.enter || 0, { nx, ny } = vec(card);
        A(card, [
          { opacity: 1, transform: "none" },
          { opacity: 1, offset: 0.35 },
          { opacity: 0, transform: `translate3d(${(nx * 10).toFixed(1)}em, ${(ny * 7 + 5).toFixed(1)}em, -58em) rotateX(${(-8 - ny * 5).toFixed(1)}deg) rotateY(${(nx * -10).toFixed(1)}deg)` },
        ], { duration: 525, delay: (5 - o) * 28, easing: ease, fill: "forwards" });
      }
      A(sky, [
        { opacity: 1, maskSize: "300% 300%", filter: "brightness(1)" },
        { opacity: 0, maskSize: "80% 80%", filter: "brightness(.5)" },
      ], { duration: 640, delay: 120, easing: "cubic-bezier(.4,0,.6,1)", fill: "forwards" });
    }
    finish(false);
    say.textContent = "The dashboard is closed.";
    log("close", by);
  }
  const toggle = (by) => (isOpen ? closeHud(by) : openHud(by));

  // ------------------------------------------------------------------ scrolling (hand, buttons, keys)
  let scrollIdle = 0;
  function handScroll(target, d) {
    const s = SCROLLERS[target];
    if (!s || !isOpen) return;
    hud.classList.add("hand-scroll");
    for (const c of Object.values(SCROLLERS)) c.card.classList.toggle("scrolling", c === s);
    // one comfortable stroke, about half the camera's view, runs through the whole list
    setPos(s, s.pos + (d / 0.45) * maxOf(s));
    s.touched = performance.now();
    if (!scrolled) { scrolled = true; refresh(); }
    clearTimeout(scrollIdle);
    scrollIdle = setTimeout(endScroll, 600);
  }
  function endScroll() {
    hud.classList.remove("hand-scroll");
    for (const c of Object.values(SCROLLERS)) c.card.classList.remove("scrolling");
  }
  function stepScroll(which, frac, wrap = false) {
    for (const k of which) {
      const s = SCROLLERS[k], max = maxOf(s), size = s.axis === "y" ? s.vp.clientHeight : s.vp.clientWidth;
      let p = s.pos + frac * size;
      if (wrap && frac > 0 && s.pos >= max - 1) p = 0; // at the end: back to the top
      setPos(s, p);
      s.touched = performance.now();
    }
    if (!scrolled) { scrolled = true; refresh(); }
  }

  // ------------------------------------------------------------------ buttons and keys
  act("open").addEventListener("click", () => openHud("button"));
  act("close").addEventListener("click", () => closeHud("button"));
  act("scroll").addEventListener("click", () => stepScroll(["schedule", "deadlines", "weather"], 0.5, true));
  act("camera").addEventListener("click", () => { wanted = true; startCamera(); });
  act("stop").addEventListener("click", () => { wanted = false; stopCamera("off"); act("camera").focus(); });
  screen.addEventListener("pointerdown", (e) => { if (!e.target.closest("button")) screen.focus({ preventScroll: true }); });
  screen.addEventListener("keydown", (e) => {
    if (e.target.closest("button")) return;
    if (e.key === " " || e.key === "Enter") { e.preventDefault(); toggle("key"); }
    else if (e.key === "Escape" && isOpen) { e.preventDefault(); closeHud("key"); }
    else if (isOpen && (e.key === "ArrowDown" || e.key === "ArrowUp")) { e.preventDefault(); stepScroll(["schedule", "deadlines"], e.key === "ArrowDown" ? 0.2 : -0.2); }
    else if (isOpen && (e.key === "ArrowRight" || e.key === "ArrowLeft")) { e.preventDefault(); stepScroll(["weather"], e.key === "ArrowRight" ? 0.3 : -0.3); }
  });
  // Shift H anywhere while the demo is on screen (like the app's shortcut), Esc to close
  addEventListener("keydown", (e) => {
    if (!inView || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target.closest?.("input, textarea, select, [contenteditable]")) return;
    if (e.shiftKey && e.code === "KeyH") { e.preventDefault(); toggle("shortcut"); }
    else if (e.key === "Escape" && isOpen && !e.target.closest?.(".lap-screen")) closeHud("key");
  });

  // ------------------------------------------------------------------ the camera
  // It runs only while the demo is on screen and the tab is visible; the tracks are stopped
  // (camera light off) the moment either changes, and it comes back if the visitor had started it.
  let startId = 0;
  async function startCamera() {
    if (!wanted || cam === "loading" || cam === "on") return;
    if (!navigator.mediaDevices?.getUserMedia || !window.WebAssembly) { wanted = false; cam = "unsupported"; refresh(); return; }
    const id = ++startId;
    cam = "loading";
    refresh();
    try {
      hands = hands || await import("./hands.js?v=4");
      if (id !== startId) return; // turned off or scrolled away while loading
      const ok = await hands.start(video, onHands, { debug });
      if (id !== startId) return;
      if (!ok) return; // stopped meanwhile
      cam = "on";
      log("camera on, delegate", hands.delegate());
    } catch (e) {
      if (id !== startId) return;
      const name = e?.name || "";
      wanted = false;
      cam = name === "NotAllowedError" || name === "SecurityError" || name === "NotFoundError" || name === "OverconstrainedError" || name === "NotReadableError" ? "denied" : "error";
      console.warn("Waverly demo:", e);
      hands?.stop();
    }
    hand = "none";
    refresh();
  }
  function stopCamera(next) {
    startId++;
    clearTimeout(lostTimer);
    lostTimer = 0;
    hands?.stop();
    cam = next;
    hand = "none";
    restingFist = false;
    endScroll();
    refresh();
  }
  function syncCamera() {
    const ok = inView && !document.hidden;
    if (ok && wanted && (cam === "paused" || cam === "off")) startCamera();
    else if (!ok && (cam === "on" || cam === "loading")) stopCamera(wanted ? "paused" : "off");
  }
  new IntersectionObserver(([en]) => { inView = en.isIntersecting; syncCamera(); }, { threshold: 0.15 }).observe($(".laptop", demo));
  document.addEventListener("visibilitychange", syncCamera);

  // events from the hand tracker (hands.js)
  function onHands(ev) {
    if (ev.t === "hand") {
      // a fast-moving hand blurs out of detection for a frame or two: only say it's gone after a moment
      if (ev.state === "none") {
        if (hand !== "none" && !lostTimer) lostTimer = setTimeout(() => { lostTimer = 0; hand = "none"; restingFist = false; refresh(); }, 700);
      } else {
        clearTimeout(lostTimer);
        lostTimer = 0;
        if (ev.state !== "fist") restingFist = false;
        if (ev.state !== hand) { hand = ev.state; refresh(); }
      }
    } else if (ev.t === "wake") {
      openHud(ev.by);
    } else if (ev.t === "sleep") {
      restingFist = ev.by === "fist";
      closeHud(ev.by);
    } else if (ev.t === "scroll") {
      handScroll(ev.target, ev.d);
    } else if (ev.t === "end") {
      clearTimeout(scrollIdle);
      scrollIdle = setTimeout(endScroll, 250);
    }
    return isOpen; // the tracker asks whether the dashboard is open
  }

  if (debug) {
    window.__wvDemo = {
      state: () => ({ cam, open: isOpen, hand, wanted, inView, scroll: Object.fromEntries(Object.entries(SCROLLERS).map(([k, s]) => [k, Math.round(s.pos)])) }),
      track: () => hands?.lastTrack() || null,
    };
  }
  refresh();
})();
