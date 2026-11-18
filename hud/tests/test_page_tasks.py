"""Tests for checking tasks off on the page itself (hud/ui/app.js), in headless Chrome.

A fake hud-core (aiohttp, free port) serves the real page and its /ws with made-up lists
and records what the page sends; Chrome is driven over the DevTools protocol with real
mouse clicks. Skipped (0/0) when Google Chrome isn't installed. No network.

Run:  python3 tests/test_page_tasks.py              (from hud/, with the venv active)
      python3 tests/test_page_tasks.py --shots DIR  (also saves screenshots of a task row)
"""
import asyncio
import base64
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import aiohttp
from aiohttp import web

# The page next to the Python package (inside the app bundle too: python/ may be a link).
UI = (Path(__file__).resolve().parents[1] / "python").resolve().parent / "ui"
CHROME = next((c for c in (os.environ.get("CHROME", ""),
                           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                           shutil.which("google-chrome") or "", shutil.which("chromium") or "") if c and os.path.exists(c)),
              None)
W, H = 1440, 900
UNDO_S = 4.0   # app.js UNDO_MS

# The made-up lists are placed around "now" (events 90 min before it, 6 h after it, a walk
# at 07:00): near midnight they would fall on another day. Run in a time zone where it is
# about noon; this process (the lists) and Chrome (the page; started with our environment)
# then agree on it.
os.environ["TZ"] = f"Etc/GMT{-(12 - time.gmtime().tm_hour):+d}"   # Etc/GMT-N is UTC+N
time.tzset()


def lists(drop=()):
    """Made-up lists in hud-core's format: "t1" is due today (in both lists), "t2" undated."""
    now = dt.datetime.now().astimezone()
    today = now.date().isoformat()
    eod = lambda n: (now.replace(hour=23, minute=59, second=59, microsecond=0) + dt.timedelta(days=n)).isoformat()  # noqa: E731
    at = lambda h, n=0: (now.replace(hour=h, minute=0, second=0, microsecond=0) + dt.timedelta(days=n)).isoformat()  # noqa: E731
    inbox, work = {"label": "Inbox", "color": "blue"}, {"label": "Work", "color": "teal"}
    left_tasks = [{"id": "t1", "list": "L1", "task": "t1", "title": "Water the plants", "due": today,
                   "overdue": False, "tag": inbox},
                  {"id": "t3", "list": "L2", "task": "t3", "title": "Send the weekly update", "due": today,
                   "overdue": False, "tag": work}]
    right = [{"id": "t:t1", "kind": "task", "list": "L1", "task": "t1", "title": "Water the plants", "allDay": True,
              "due": eod(0), "overdue": False, "tag": inbox},
             {"id": "e:e1", "kind": "event", "title": "Team review", "due": at(10, 1), "start": at(10, 1),
              "end": at(11, 1), "allDay": False, "tag": work},
             {"id": "t:t4", "kind": "task", "list": "L2", "task": "t4", "title": "Book a dentist appointment",
              "allDay": True, "due": eod(3), "overdue": False, "tag": work},
             {"id": "t:t2", "kind": "task", "list": "L1", "task": "t2", "title": "Fix the squeaky door", "allDay": True,
              "due": None, "overdue": False, "tag": inbox}]
    events = [{"id": "e0", "title": "Morning walk", "start": at(7), "end": at(8), "allDay": False, "location": "",
               "tag": inbox}]
    keep = lambda t: (t.get("list"), t.get("task")) not in drop  # noqa: E731
    return {"date": today, "left": {"events": events, "tasks": [t for t in left_tasks if keep(t)]},
            "right": {"items": [i for i in right if keep(i)]}}


def more(d, earlier=0, later=0, right=0):
    """`d` with made-up events around now in the left list (`earlier` before it, `later` after),
    and `right` more tasks ("t10", "t11", ...) in the right list."""
    now = dt.datetime.now().astimezone()
    tag = {"label": "Work", "color": "teal"}
    for i in range(-earlier, later):
        s = now + dt.timedelta(minutes=50 * i + (5 if i >= 0 else -40))
        d["lists"]["left"]["events"].append({"id": f"e{i}x", "title": f"Event {i + earlier + 1}", "start": s.isoformat(),
                                             "end": (s + dt.timedelta(minutes=30)).isoformat(), "allDay": False,
                                             "location": "", "tag": tag})
    for i in range(right):
        d["lists"]["right"]["items"].append({"id": f"t:t{10 + i}", "kind": "task", "list": "L2", "task": f"t{10 + i}",
                                             "title": f"Task {i + 1}", "allDay": True, "due": None, "overdue": False,
                                             "tag": tag})
    return d


# Every frame for `ms`: [ms, top of each of `sels` (null when absent)], in window.__tr.
TRACE = """(() => {{ window.__tr = []; const t0 = performance.now(), sels = {sels};
  const f = () => {{ window.__tr.push([performance.now() - t0, ...sels.map((s) => {{ const e = document.querySelector(s);
      return e ? e.getBoundingClientRect().top : null; }})]);
    if (performance.now() - t0 < {ms}) requestAnimationFrame(f); }};
  requestAnimationFrame(f); return true; }})()"""


async def trace(c, sels, ms):
    """Starts tracing the on-screen tops of `sels`; await the result to get them per column."""
    await c.js(TRACE.format(sels=json.dumps(sels), ms=ms))

    async def result():
        await asyncio.sleep(ms / 1000 + 0.3)
        tr = await c.js("window.__tr")
        return [[r[i] for r in tr if r[i] is not None] for i in range(1, len(sels) + 1)]
    return result()


def data(theme="dark", can_complete=True, state="ok", drop=()):
    cfg = {"name": "", "place": "", "lat": None, "lon": None, "temperature_unit": "fahrenheit", "wind_unit": "mph",
           "clock": "12h", "titles": {"left": "Calendar", "right": "Tasks"}, "countdowns": True, "theme": theme,
           "parallax": False, "weather_animation": False, "weather_detail": "low", "open_animation_s": 0,
           "close_animation_s": 0, "open_animation": "fade", "close_animation": "fade"}
    return {"t": "data", "config": cfg, "palette": [], "google": {"state": state, "can_complete": can_complete},
            "lists": lists(drop), "weather": None, "word": None, "fact": None, "google_at": time.time()}


class FakeCore:
    """Serves the page and /ws; keeps what the page sent."""

    def __init__(self):
        self.got = []
        self.ws = None
        self.first = data()

    async def index(self, request):
        return web.FileResponse(UI / "index.html", headers={"Cache-Control": "no-store"})

    async def socket(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.ws = ws
        await ws.send_json(self.first)
        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                d = json.loads(msg.data)
                if d.get("t") not in ("hb", "perf"):
                    self.got.append(d)
        return ws

    def sent(self, t):
        return [m for m in self.got if m.get("t") == t]

    async def push(self, m):
        await self.ws.send_json(m)

    async def start(self):
        app = web.Application()
        app.router.add_get("/", self.index)
        app.router.add_get("/ws", self.socket)
        app.router.add_static("/static", UI)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        self.port = site._server.sockets[0].getsockname()[1]


class Chrome:
    """Headless Chrome (its own throwaway profile) and one page, over the DevTools protocol."""

    async def start(self):
        self.dir = tempfile.mkdtemp(prefix="waverly-chrome-")
        self.proc = subprocess.Popen([CHROME, "--headless=new", "--remote-debugging-port=0", f"--user-data-dir={self.dir}",
                                      f"--window-size={W},{H}", "--force-device-scale-factor=1", "--hide-scrollbars",
                                      "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                                      "--mute-audio", "about:blank"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        port_file = Path(self.dir) / "DevToolsActivePort"
        for _ in range(200):
            if port_file.exists() and port_file.read_text().count("\n") >= 1:
                break
            await asyncio.sleep(0.05)
        port = int(port_file.read_text().split("\n")[0])
        self.http = aiohttp.ClientSession()
        async with self.http.get(f"http://127.0.0.1:{port}/json/list") as r:
            page = next(t for t in await r.json() if t["type"] == "page")
        self.ws = await self.http.ws_connect(page["webSocketDebuggerUrl"], max_msg_size=0)
        self.n, self.waiting = 0, {}
        self.reader = asyncio.ensure_future(self._read())
        await self.cmd("Page.enable")
        await self.cmd("Emulation.setDeviceMetricsOverride", width=W, height=H, deviceScaleFactor=1, mobile=False)

    async def _read(self):
        async for msg in self.ws:
            d = json.loads(msg.data)
            f = self.waiting.pop(d.get("id"), None)
            if f and not f.done():
                f.set_result(d)

    async def cmd(self, method, **params):
        self.n += 1
        f = asyncio.get_running_loop().create_future()
        self.waiting[self.n] = f
        await self.ws.send_json({"id": self.n, "method": method, "params": params})
        d = await asyncio.wait_for(f, 20)
        if "error" in d:
            raise RuntimeError(f"{method}: {d['error']}")
        return d["result"]

    async def js(self, expr):
        r = await self.cmd("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
        if "exceptionDetails" in r:
            raise RuntimeError(f"{expr[:80]}: {r['exceptionDetails'].get('exception', {}).get('description')}")
        return r["result"].get("value")

    async def until(self, expr, timeout=8):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if await self.js(expr):
                return True
            await asyncio.sleep(0.05)
        raise AssertionError(f"timed out waiting for {expr}")

    async def click(self, x, y):
        for kind in ("mouseMoved", "mousePressed", "mouseReleased"):
            await self.cmd("Input.dispatchMouseEvent", type=kind, x=x, y=y, button="left", clickCount=1)

    async def shot(self, path, clip):
        r = await self.cmd("Page.captureScreenshot", format="png", clip={**clip, "scale": 2})  # a Retina screen
        Path(path).write_bytes(base64.b64decode(r["data"]))

    async def stop(self):
        self.reader.cancel()
        await self.ws.close()
        await self.http.close()
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.dir, ignore_errors=True)


# The centre of the ring of task `key` ("<list> <task>") in list `side` (schedule | deadlines).
RING = """(() => {{ const r = [...document.querySelectorAll('#{side} .has-check')].find(e => e.dataset.key === '{key}');
  if (!r) return null; const b = r.querySelector('.check').getBoundingClientRect();
  return [b.left + b.width / 2, b.top + b.height / 2, b.width]; }})()"""
ROWS = "[...document.querySelectorAll('#stage .has-check')].filter(e => e.dataset.key === '{key}')"


async def ring(c, key, side="schedule"):
    return await c.js(RING.format(side=side, key=key))


async def checked(c, key):
    return await c.js(f"{ROWS.format(key=key)}.map(e => e.classList.contains('checked'))")


async def session(fn, shots=None):
    core, c = FakeCore(), Chrome()
    await core.start()
    await c.start()
    try:
        await c.cmd("Page.navigate", url=f"http://127.0.0.1:{core.port}/?mac=1&awake=0")
        await c.until("window.HUD && HUD.S.phase === 'awake' && !!document.querySelector('#schedule .task')")
        await fn(core, c, shots)
    finally:
        await c.stop()
        await core.runner.cleanup()


# ---------------------------------------------------------------------- tests
async def t_controls(core, c, shots):
    # tasks get a ring button in both lists, events never
    assert await c.js("document.querySelectorAll('#schedule .task .check').length") == 2
    assert await c.js("document.querySelectorAll('#deadlines .dl .check').length") == 3
    assert await c.js("document.querySelectorAll('.ev .check, .dl[data-start] .check').length") == 0
    assert await c.js("document.querySelector('#deadlines').classList.contains('checks')")
    # the hit target is at least 24 px each way (from the ring's left edge: the list clips
    # to its left), and the cursor says it's clickable
    for key, side in (("L1 t1", "schedule"), ("L2 t4", "deadlines")):
        x, y, w = await ring(c, key, side)
        assert await c.js(f"getComputedStyle(document.elementFromPoint({x}, {y})).cursor") == "pointer"
        left = x - w / 2
        for px, py in ((left + 0.5, y), (left + 23.5, y), (x, y - 11.8), (x, y + 11.8)):
            hit = await c.js(f"!!document.elementFromPoint({px}, {py}).closest('.check')")
            assert hit, f"{side}: no hit at {px - x:+.1f},{py - y:+.1f} px from the ring's centre (ring {w:.1f} px)"
        # and it stops short of the title
        title = await c.js(f"(() => {{ const r = [...document.querySelectorAll('#{side} .has-check')].find(e => e.dataset.key === '{key}');"
                           f" return r.querySelector('.t-title, .dl-title').getBoundingClientRect().left; }})()")
        assert not await c.js(f"!!document.elementFromPoint({title + 1}, {y}).closest('.check')"), side


async def t_click_pending_undo(core, c, shots):
    x, y, _ = await ring(c, "L1 t1")
    await c.click(x, y)
    assert await checked(c, "L1 t1") == [True, True]     # the same task in both lists
    assert await c.js("document.querySelector('#schedule .checked .t-title').closest('.task') !== null")
    assert await c.js("getComputedStyle(document.querySelector('#schedule .checked .t-title')).textDecorationLine") == "line-through"
    assert await c.js("document.querySelector('#schedule .checked .check').getAttribute('aria-pressed')") == "true"
    await asyncio.sleep(1.0)
    assert core.sent("task-complete") == []               # still inside the undo window
    await c.click(x, y)                                    # undo
    assert await checked(c, "L1 t1") == [False, False]
    await asyncio.sleep(UNDO_S + 0.6)
    assert core.sent("task-complete") == [], core.got     # nothing was sent
    assert await c.js("HUD.checks.size") == 0


async def t_window_end_sends(core, c, shots):
    x, y, _ = await ring(c, "L2 t4", "deadlines")
    await c.click(x, y)
    await asyncio.sleep(UNDO_S - 0.6)
    assert core.sent("task-complete") == []
    await asyncio.sleep(1.0)
    assert core.sent("task-complete") == [{"t": "task-complete", "list": "L2", "task": "t4"}]
    # the row collapses away, the rest of the list keeps no leftover transforms
    await c.until(f"{ROWS.format(key='L2 t4')}.length === 0", 3)
    assert await c.js("[...document.querySelectorAll('#deadlines .dl')].every(e => !e.getAnimations().length)")
    assert await c.js("document.querySelectorAll('#deadlines .dl').length") == 3
    # hud-core confirms: fresh data without the task, then task-done
    await core.push(data(drop={("L2", "t4")}))
    await core.push({"t": "task-done", "list": "L2", "task": "t4"})
    await c.until("HUD.checks.size === 0")
    assert await c.js("document.querySelectorAll('#deadlines .dl').length") == 3


async def t_sleep_sends_at_once(core, c, shots):
    x, y, _ = await ring(c, "L2 t3")
    await c.click(x, y)
    await asyncio.sleep(0.3)
    await core.push({"t": "sleep"})
    await c.until("HUD.S.phase === 'asleep'")
    for _ in range(20):
        if core.sent("task-complete"):
            break
        await asyncio.sleep(0.05)
    assert core.sent("task-complete") == [{"t": "task-complete", "list": "L2", "task": "t3"}]
    # back on screen: the task stays off the lists until hud-core answers
    await core.push({"t": "wake"})
    await c.until("HUD.S.phase === 'awake'")
    assert await c.js(f"{ROWS.format(key='L2 t3')}.length") == 0


async def t_error_restores(core, c, shots):
    x, y, _ = await ring(c, "L1 t2", "deadlines")
    await c.click(x, y)
    await asyncio.sleep(UNDO_S + 0.4)
    assert core.sent("task-complete") == [{"t": "task-complete", "list": "L1", "task": "t2"}]
    await c.until(f"{ROWS.format(key='L1 t2')}.length === 0", 3)
    msg = "Couldn't reach Google. Try again."
    await core.push({"t": "task-error", "list": "L1", "task": "t2", "reason": "offline", "message": msg})
    await c.until(f"{ROWS.format(key='L1 t2')}.length === 1")
    assert await checked(c, "L1 t2") == [False]
    note = f"{ROWS.format(key='L1 t2')}[0].querySelector('.check-note')"
    assert await c.js(f"{note}.textContent") == msg
    assert await c.js("HUD.checks.size") == 0
    # a click on it again clears the note and starts over
    x, y, _ = await ring(c, "L1 t2", "deadlines")
    await c.click(x, y)
    assert await c.js(f"{note}") is None and await checked(c, "L1 t2") == [True]


async def t_esc_and_wheel(core, c, shots):
    x, y, _ = await ring(c, "L1 t1")
    await c.click(x, y)
    await c.click(x, y)
    # trackpad scrolling over the list still drives it
    before = await c.js("HUD.scrollers.schedule.target")
    await c.cmd("Input.dispatchMouseEvent", type="mouseWheel", x=x + 200, y=y, deltaX=0, deltaY=400)
    await c.until(f"HUD.scrollers.schedule.target !== {before} || HUD.scrollers.schedule.max === 0")
    # Esc still asks to close after a click
    await c.cmd("Input.dispatchKeyEvent", type="keyDown", key="Escape", code="Escape", windowsVirtualKeyCode=27)
    await c.cmd("Input.dispatchKeyEvent", type="keyUp", key="Escape", code="Escape", windowsVirtualKeyCode=27)
    for _ in range(20):
        if core.sent("force"):
            break
        await asyncio.sleep(0.05)
    assert core.sent("force") == [{"t": "force", "awake": False}]
    assert core.sent("task-complete") == []


async def t_no_controls_without_permission(core, c, shots):
    for d in (data(can_complete=False), data(state="error"), {**data(), "google": {"state": "ok"}}):
        await core.push(d)
        await asyncio.sleep(0.2)
        assert await c.js("document.querySelectorAll('.check, .has-check').length") == 0
        assert await c.js("document.querySelectorAll('#schedule .task > span.ring').length") == 2
        assert await c.js("document.querySelectorAll('#deadlines .dl > .dot').length") == 4
        assert not await c.js("document.querySelector('#deadlines').classList.contains('checks')")


async def t_permission_lost_drops_pending(core, c, shots):
    x, y, _ = await ring(c, "L1 t1")
    await c.click(x, y)
    await core.push(data(can_complete=False))
    await asyncio.sleep(UNDO_S + 0.4)
    assert core.sent("task-complete") == [] and await c.js("HUD.checks.size") == 0


async def t_late_error_ignored(core, c, shots):
    # a task-error for an attempt the page is no longer waiting on leaves a new check alone
    x, y, _ = await ring(c, "L2 t4", "deadlines")
    await c.click(x, y)
    await asyncio.sleep(UNDO_S + 0.4)
    await c.until(f"{ROWS.format(key='L2 t4')}.length === 0", 3)
    await core.push({"t": "task-error", "list": "L2", "task": "t4", "reason": "offline", "message": "Nope."})
    await c.until(f"{ROWS.format(key='L2 t4')}.length === 1")
    x, y, _ = await ring(c, "L2 t4", "deadlines")
    await c.click(x, y)                                    # checked again: pending
    await core.push({"t": "task-error", "list": "L2", "task": "t4", "reason": "offline", "message": "Nope."})
    await core.push({"t": "task-done", "list": "L2", "task": "t4"})
    await asyncio.sleep(0.3)
    assert await checked(c, "L2 t4") == [True]
    assert await c.js(f"{ROWS.format(key='L2 t4')}[0].querySelector('.check-note')") is None
    assert await c.js("HUD.checks.get('L2 t4').state") == "pending"


async def t_scrolled_list_stays(core, c, shots):
    # a list scrolled by hand doesn't drift back home with the checked row while it is checked off
    await core.push(more(data(), right=12))
    await asyncio.sleep(0.4)
    vx, vy = await c.js("(() => { const b = document.getElementById('deadlines-vp').getBoundingClientRect();"
                        " return [b.left + b.width / 2, b.top + b.height / 2]; })()")
    await c.cmd("Input.dispatchMouseEvent", type="mouseWheel", x=vx, y=vy, deltaX=0, deltaY=300)
    await asyncio.sleep(9.5)                               # the list drifts home 12 s after the last input
    off = await c.js("HUD.scrollers.deadlines.off")
    assert off > 100, off
    x, y, _ = await ring(c, "L2 t15", "deadlines")
    await c.click(x, y)
    await asyncio.sleep(UNDO_S + 0.2)
    assert await c.js("HUD.scrollers.deadlines.off") == off
    assert core.sent("task-complete") == [{"t": "task-complete", "list": "L2", "task": "t15"}]
    await asyncio.sleep(2.5)
    assert await c.js("HUD.scrollers.deadlines.off") == off


async def t_collapses_overlap_smoothly(core, c, shots):
    # two tasks checked a moment apart: the event below them only ever moves up, without jumps,
    # and ends where the redrawn list puts it
    x1, y1, _ = await ring(c, "L1 t1")
    x3, y3, _ = await ring(c, "L2 t3")
    done = await trace(c, ["#schedule .ev"], 6000)
    await c.click(x1, y1)
    await asyncio.sleep(0.25)
    await c.click(x3, y3)
    ev, = await done
    steps = [b - a for a, b in zip(ev, ev[1:])]
    assert max(steps) < 0.5 and min(steps) > -20, (max(steps), min(steps))
    assert await c.js("document.querySelectorAll('#schedule .has-check').length") == 0
    assert abs(ev[-1] - await c.js("document.querySelector('#schedule .ev').getBoundingClientRect().top")) < 0.5


async def t_centred_list_keeps_now(core, c, shots):
    # left alone, the left list keeps "now" in the middle: checking off a task above it moves
    # the rows above down into the gap; "now" stays put, during the collapse and after
    await core.push(more(data(), earlier=2, later=8))   # with the morning walk: 3 events before now
    await asyncio.sleep(2.5)
    auto = await c.js("HUD.scrollers.schedule.auto")
    assert auto > 80, auto
    x, y, _ = await ring(c, "L2 t3")
    done = await trace(c, ["#now-line", "#schedule .task"], UNDO_S * 1000 + 2500)
    await c.click(x, y)
    now_line, task = await done
    assert max(now_line) - min(now_line) < 0.5, (min(now_line), max(now_line))
    assert all(b >= a - 0.5 for a, b in zip(task, task[1:])) and task[-1] > task[0] + 30
    assert await c.js("HUD.scrollers.schedule.off === HUD.scrollers.schedule.auto")


async def t_screenshots(core, c, shots):
    """Light and dark: normal, checked (in the undo window) and the error note, cropped to the lists."""
    if not shots:
        return
    Path(shots).mkdir(parents=True, exist_ok=True)
    box = await c.js("""(() => { const a = document.querySelector('.schedule').getBoundingClientRect(),
      b = document.querySelector('.deadlines').getBoundingClientRect();
      return { x: a.left - 20, y: a.top - 20, width: b.right - a.left + 40, height: Math.min(a.height, 520) + 40 }; })()""")
    for theme in ("light", "dark"):
        await core.push(data(theme))
        await asyncio.sleep(3.4)   # the theme cross-fades for 3 s
        await c.cmd("Input.dispatchMouseEvent", type="mouseMoved", x=5, y=5)
        await c.shot(f"{shots}/{theme}-1-normal.png", box)
        x, y, _ = await ring(c, "L2 t4", "deadlines")
        await c.cmd("Input.dispatchMouseEvent", type="mouseMoved", x=x, y=y)
        await asyncio.sleep(0.4)
        await c.shot(f"{shots}/{theme}-2-hover.png", box)
        x, y, _ = await ring(c, "L1 t1")
        await c.click(x, y)
        await c.cmd("Input.dispatchMouseEvent", type="mouseMoved", x=5, y=5)
        await asyncio.sleep(0.5)
        await c.shot(f"{shots}/{theme}-3-checked.png", box)
        await asyncio.sleep(UNDO_S)
        await core.push({"t": "task-error", "list": "L1", "task": "t1", "reason": "offline",
                         "message": "Couldn't reach Google. Try again."})
        await asyncio.sleep(0.6)
        await c.shot(f"{shots}/{theme}-4-error.png", box)
        await asyncio.sleep(8.6)   # the note fades out


TESTS = [t_controls, t_click_pending_undo, t_window_end_sends, t_sleep_sends_at_once, t_error_restores,
         t_esc_and_wheel, t_no_controls_without_permission, t_permission_lost_drops_pending, t_late_error_ignored,
         t_scrolled_list_stays, t_collapses_overlap_smoothly, t_centred_list_keeps_now]


def main():
    if not CHROME:
        print("SKIP: Google Chrome not found (set CHROME=/path/to/chrome)\n\n0/0 passed")
        return 0
    shots = sys.argv[sys.argv.index("--shots") + 1] if "--shots" in sys.argv else None
    tests = TESTS + ([t_screenshots] if shots else [])
    failed = 0
    for fn in tests:
        try:
            asyncio.run(session(fn, shots))
            print("PASS", fn.__name__)
        except Exception:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", fn.__name__)
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
