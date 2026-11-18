"""Tests for the page's idle cost (hud/ui/app.js, sky.js), in headless Chrome.

  - a still head (detector jitter only) writes no parallax styles; a real head movement does
  - a sky with only clouds is drawn at about 20 fps, rain at the full frame rate
  - the first open shows the current theme at once; while open, a theme change still fades

Uses the fake hud-core and Chrome driver of test_page_tasks.py. Skipped (0/0) when Google
Chrome isn't installed. No network.

Run:  python3 tests/test_page_perf.py   (from hud/, with the venv active)
"""
import asyncio
import sys
import time

from test_page_tasks import CHROME, Chrome, FakeCore, data


def config(**kw):
    d = data()
    d["config"].update(kw)
    return d


async def session(fn):
    core, c = FakeCore(), Chrome()
    await core.start()
    await c.start()
    try:
        await fn(core, c)
    finally:
        await c.stop()
        await core.runner.cleanup()


async def open_page(core, c, query, first, awake=True):
    core.first = first
    await c.cmd("Page.navigate", url=f"http://127.0.0.1:{core.port}/?mac=1{'&awake=0' if awake else ''}{query}")
    if awake:
        await c.until("window.HUD && HUD.S.phase === 'awake' && !!document.querySelector('#stage .card')")
    else:
        await c.until("window.HUD && !!HUD.S.data")


# Counts parallax updates (style writes on the sky, which moves with every card: window.__w)
# and feeds HUD.onHead at 15 Hz:
# a head at (x, y), plus gaussian jitter of sd `sx` (position) and `sa` (yaw, pitch).
HEAD = """(() => {{ window.__w ??= 0; if (!window.__mo) {{
    window.__mo = new MutationObserver((l) => {{ window.__w += l.length; }});
    window.__mo.observe(document.getElementById('sky'), {{ attributes: true, attributeFilter: ['style'] }}); }}
  const g = () => {{ let u = 0; for (let i = 0; i < 6; i++) u += Math.random(); return (u - 3) * Math.SQRT2; }};
  clearInterval(window.__head);
  window.__head = setInterval(() => HUD.onHead({{ x: {x} + {sx} * g(), y: 0.45 + {sx} * g(),
    yaw: {sa} * g(), pitch: 0.6 + {sa} * g() }}), 66);
  return true; }})()"""


async def t_still_head_rests(core, c):
    await open_page(core, c, "&phase=day&wx=clear", config(parallax=True))
    # BlazeFace-like jitter on a still head: about 1-2 px of a 640 px frame
    await c.js(HEAD.format(x=0.5, sx=0.003, sa=0.01))
    await asyncio.sleep(2.5)                               # the first readings set the targets
    await c.js("window.__w = 0; true")
    await asyncio.sleep(5.0)
    # (it was 15 a second; the centre still drifts toward where you sit, so allow a step)
    assert await c.js("window.__w") <= 1, await c.js("window.__w")
    # a real lean to the side tilts the cards, and follows within a fraction of a second
    rot0 = await c.js("document.querySelector('#stage .card').style.rotate")
    await c.js(HEAD.format(x=0.56, sx=0.003, sa=0.01))
    await asyncio.sleep(0.4)
    assert await c.js("window.__w") > 0
    rot = await c.js("document.querySelector('#stage .card').style.rotate")
    assert rot != rot0 and float(rot.split()[-1][:-3]) > 0.7, (rot0, rot)
    # and comes to rest there
    await asyncio.sleep(1.5)
    await c.js("window.__w = 0; true")
    await asyncio.sleep(5.0)
    assert await c.js("window.__w") <= 1, await c.js("window.__w")
    await c.js("clearInterval(window.__head); true")


# Counts ambient.frame calls in window.__f.
DRAWS = """(() => { window.__f = 0; const f = HUD.ambient.frame.bind(HUD.ambient);
  HUD.ambient.frame = (n) => { window.__f++; return f(n); }; return true; })()"""


async def draws_per_s(c, s=3.0):
    await c.js(DRAWS)
    await asyncio.sleep(0.3)
    await c.js("window.__f = 0; true")
    await asyncio.sleep(s)
    return await c.js("window.__f") / s


async def t_cloudy_sky_20fps(core, c):
    await open_page(core, c, "&phase=day&wx=cloudy",
                    config(weather_detail="high", weather_animation=True, parallax=False))
    rate = await draws_per_s(c)
    assert 12 <= rate <= 24, rate
    assert await c.js("HUD.ambient.minFrameMs") > 0


async def t_rain_full_rate(core, c):
    await open_page(core, c, "&phase=day&wx=rain&lvl=1",
                    config(weather_detail="high", weather_animation=True, parallax=False))
    frames = await c.js("new Promise((r) => { let n = 0; const t0 = performance.now();"
                        " const f = () => (performance.now() - t0 < 1000 ? (n++, requestAnimationFrame(f)) : r(n));"
                        " requestAnimationFrame(f); })")
    rate = await draws_per_s(c)
    assert rate >= 0.8 * frames, (rate, frames)
    # rain stopping: still every frame while the drops fade out, then the cloud rate
    await c.js("HUD.ambient.set('day', { kind: 'cloudy', level: 0 }); true")
    assert await c.js("HUD.ambient.minFrameMs") == 0
    await c.until("HUD.ambient.minFrameMs > 0", 10)


INK = "getComputedStyle(document.body).getPropertyValue('--ink').trim()"


async def t_theme_snaps_on_open(core, c):
    await open_page(core, c, "&phase=day&wx=clear", config(open_animation_s=1.0, theme="adaptive"), awake=False)
    await asyncio.sleep(0.3)
    await core.push({"t": "wake"})
    t0 = time.monotonic()
    await c.until("HUD.S.phase === 'entering'", 3)
    assert time.monotonic() - t0 < 0.8
    light = await c.js(INK)                                # the day theme from the first frame on
    assert await c.js("document.body.dataset.tone") == "light"
    assert light in ("rgb(11, 22, 38)", "#0b1626", "#0B1626"), light
    await c.until("HUD.S.phase === 'awake'", 4)
    # on screen, a theme change still fades over 3 s
    await core.push(config(open_animation_s=1.0, theme="dark"))
    await asyncio.sleep(0.8)
    mid = await c.js(INK)
    assert mid != light, mid
    await asyncio.sleep(2.8)
    dark = await c.js(INK)
    assert dark not in (light, mid), (light, mid, dark)


TESTS = [t_still_head_rests, t_cloudy_sky_20fps, t_rain_full_rate, t_theme_snaps_on_open]


def main():
    if not CHROME:
        print("SKIP: Google Chrome not found (set CHROME=/path/to/chrome)\n\n0/0 passed")
        return 0
    failed = 0
    for fn in TESTS:
        try:
            asyncio.run(session(fn))
            print("PASS", fn.__name__)
        except Exception:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", fn.__name__)
            traceback.print_exc()
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
