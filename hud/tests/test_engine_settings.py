"""hud-engine and the gesture settings (Settings › Controls): config.json's gesture_* and
auto_close_* keys reach the gesture engine live, also while the HUD is closed, and the
auto-close rules (nobody seen / the room dark) follow their switches.

Needs the engine's packages (OpenCV, MediaPipe, aiohttp): run with the venv's python.
No camera, models or hud-core are used: config.json, the frame socket and the state
folder are scratch files.

Run:  python3 tests/test_engine_settings.py      (from hud/)
"""
import asyncio
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

SCRATCH = Path(tempfile.mkdtemp(prefix="wv-eng-", dir="/tmp" if len(tempfile.gettempdir()) > 60 else None))
CONFIG = SCRATCH / "config.json"
os.environ.update(HUD_STATE=str(SCRATCH), HUD_CONFIG=str(CONFIG), HUD_FRAMES=str(SCRATCH / "frames.shm"),
                  HUD_FRAMES_SOCK=str(SCRATCH / "frames.sock"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from hud.engine import CONFIG_CHECK, EngineService  # noqa: E402
from hud.gestures import PALM, HandObs  # noqa: E402

failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"   [{detail}]" if detail else ""))
    if not ok:
        failures.append(name)


def write_config(**kw):
    """Write config.json and move its mtime on, so even two writes within one tick differ."""
    CONFIG.write_text(json.dumps({"http_port": 47999, **kw}))
    st = CONFIG.stat()
    bump = getattr(write_config, "n", 0) + 1
    write_config.n = bump
    os.utime(CONFIG, ns=(st.st_atime_ns, st.st_mtime_ns + bump * 1_000_000_000))


def service(**kw):
    write_config(**kw)
    svc = EngineService()
    svc.asked = []
    svc.request = lambda what, reason="": svc.asked.append((what, reason))
    return svc


def wave(svc, t0, seconds=2.0, fps=30):
    """Feed palm-facing sweeps across the view (0.2 <-> 0.8, 0.6 s each way) to the service's
    gesture engine (HUD closed); returns its events."""
    out = []
    n = round(0.6 * fps)
    for i in range(int(seconds * fps)):
        x = 0.2 + 0.6 * (1 - abs((i % (2 * n)) / n - 1))
        ev, _ = svc.engine.update(t0 + i / fps, [HandObs(x, 0.5, 0.15, PALM, 1.0, False, 0.98, 0.9, 1, None,
                                                         15.0, 10.0)], False, False)
        out += ev
    return out


try:
    # ------------------------------------------------------------ config -> gesture engine
    svc = service()
    e = svc.engine
    check("defaults: every gesture on", e.open_wave and e.open_fist and e.close_fist and e.can_wake)
    svc = service(gesture_open_wave=False, gesture_close_fist=False)
    check("settings at start-up reach the gesture engine",
          not svc.engine.open_wave and svc.engine.open_fist and not svc.engine.close_fist)

    # live reload while the HUD is closed
    svc = service()
    assert svc.state == "asleep"
    now = time.monotonic()
    svc._reload_config(now)                      # first look: nothing changed
    write_config(gesture_open_wave=False)
    svc._reload_config(now + 0.5)
    check("asleep: a change is not looked for again within CONFIG_CHECK", svc.engine.open_wave)
    svc._reload_config(now + CONFIG_CHECK + 0.1)
    check("asleep: config.json is re-read every CONFIG_CHECK s and the wave turns off",
          not svc.engine.open_wave and svc.cfg["gesture_open_wave"] is False)
    check("asleep, wave turned off live: a wave wakes nothing", wave(svc, 500.0) == [])
    write_config(gesture_open_wave=True, gesture_open_fist=False)
    svc._reload_config(now + 2 * CONFIG_CHECK + 0.2)
    check("asleep: turned back on live, a wave wakes again", "wake" in wave(svc, 600.0) and not svc.engine.open_fist)
    write_config(gesture_open_wave=False, gesture_open_fist=False)
    svc._reload_config(now + 3 * CONFIG_CHECK + 0.3)
    check("both open gestures off: the engine knows nothing can wake (frames are skipped while closed)",
          not svc.engine.can_wake)
    CONFIG.write_text("{ not json")
    svc._reload_config(now + 4 * CONFIG_CHECK + 0.4)
    check("a broken config.json keeps the current gesture settings",
          not svc.engine.open_wave and not svc.engine.open_fist and svc.cfg["gesture_close_fist"])

    # a wake looks at config.json at once
    svc = service()

    async def wake():
        svc.loop, svc.out = asyncio.get_running_loop(), asyncio.Queue()
        svc.slept, svc.rewake = asyncio.Event(), asyncio.Event()
        svc.overlay_ready, svc.overlay_hidden = asyncio.Event(), asyncio.Event()
        svc.cfg_checked = time.monotonic()
        job = asyncio.ensure_future(svc._transition("wake", "test"))
        await asyncio.sleep(0.05)
        svc.overlay_ready.set()
        await job

    asyncio.run(wake())
    write_config(gesture_close_fist=False)
    svc._reload_config(time.monotonic())
    check("after a wake, config.json is read on the very next pass",
          svc.state == "awake" and not svc.engine.close_fist)

    # ------------------------------------------------------------ the worker skips the models when nothing can wake
    import numpy as np
    from types import SimpleNamespace as NS
    import hud.engine as engine_mod

    class Stop(Exception):
        pass

    def worker_runs(state, **kw):
        """Run the worker on 5 lit frames; returns how many times the hand model ran."""
        s = service(**kw)
        s.state = state
        calls = []
        empty = NS(hand_landmarks=[], gestures=[], handedness=[], hand_world_landmarks=[])
        fake = NS(gesture=NS(recognize_for_video=lambda img, ts: calls.append(ts) or empty),
                  face=NS(detect_for_video=lambda img, ts: NS(detections=[])),
                  pose=NS(detect_for_video=lambda img, ts: NS(pose_landmarks=[])),
                  ts=lambda kind, t: int(t * 1000))
        frame = np.full((480, 640, 3), 120, np.uint8)
        left = iter(range(5))

        def wait(timeout):
            if next(left, None) is None:
                raise Stop
            return 1, frame
        s.frames.wait = wait
        real = engine_mod.Models
        engine_mod.Models = lambda: fake
        try:
            s.worker()
        except Stop:
            pass
        finally:
            engine_mod.Models = real
        return len(calls)

    off = {"gesture_open_wave": False, "gesture_open_fist": False}
    check("closed, a wake gesture on: the hand model runs on each frame", worker_runs("asleep") == 5)
    check("closed, both open gestures off: the hand model never runs", worker_runs("asleep", **off) == 0)
    check("open, both open gestures off: the hand model runs (scrolling, closing, presence)",
          worker_runs("awake", **off) == 5)

    # ------------------------------------------------------------ camera-want holds through a wake gesture
    # The app's camera sends full-rate frames only while the engine wants them (camera-want); once
    # it stops, the stage-1 Vision gate has to see the hand move again (~0.6 s) before frames come
    # back. A fist -> open wake must not be cut in the middle: the engine keeps wanting frames
    # while the gesture could still complete (GestureEngine.wake_pending), also when the hand is
    # still or lost from view for a moment and a prewake's hold has run out.
    from hud.engine import PREWAKE_HOLD
    from hud.gestures import FIST, OTHER

    def camera_run(script, pending=True, until=8.0, fps=30, gate_delay=0.6):
        """Run the service's gesture side against a simulated camera (HUD closed). script(t) ->
        (shape, openness, (yaw, pitch)) or None (no hand detected). Returns (events, the
        times the camera went idle, frames the engine got)."""
        s = service()
        if not pending:
            s.engine.wake_pending = lambda t: False
        t0, active, gate_at, gate_until = 1000.0, True, None, 1000.75   # a hand just opened the gate
        events, idle_at, got, before = [], [], 0, None
        for k in range(int(until * fps)):
            now = t0 + k / fps
            hand = script(now - t0)
            if not active and hand is not None and hand != before and gate_at is None:
                gate_at = now + gate_delay  # Vision sees the hand move, the camera goes active again
            before = hand                   # (a hand that sits still makes no motion: the gate stays shut)
            if gate_at is not None and now >= gate_at:
                active, gate_at, gate_until = True, None, now + 0.75
            if active:  # one worker pass (engine.worker), as for a real frame
                got += 1
                hands = [] if hand is None else [HandObs(0.5, 0.5, 0.15, hand[0], 1.0, False, hand[1], 0.9, 1, None,
                                                         *hand[2])]
                if hands and s._hand_active(hands):
                    s.last_activity = now
                ev, _ = s.engine.update(now, hands, False, False)
                if ev:
                    s.last_activity = now
                for e_ in ev:
                    events.append((round(now - t0, 2), e_))
                    if e_ == "prewake" and now > s.prewake_until:  # as EngineService._transition
                        s.prewake_until = now + PREWAKE_HOLD
                if "wake" in ev:
                    break
            s._camera_want(now)
            if active and not s.want_active and now >= gate_until:
                active = False
                idle_at.append(round(now - t0, 2))
        return events, idle_at, got

    BACK, EDGE, FACE = (160.0, -10.0), (90.0, -10.0), (15.0, 10.0)

    def retry(t):
        """The user's first try: a fist back to the camera, opened only part way (60%), given
        up; 2 s later a second fist (still within the first prewake's hold, so no new hold), held
        0.5 s, turning round as it opens: lost from view for 1.8 s, then the palm faces the camera."""
        if t < 0.2 or 2.0 <= t < 2.5:
            return FIST, 0.08, BACK
        if t < 1.9:
            return OTHER, 0.6, EDGE
        if 2.5 <= t < 2.6:
            return OTHER, 0.5, EDGE
        if 4.4 <= t:
            return PALM, 0.98, FACE
        return None

    ev, idle, _ = camera_run(retry)
    check("a fist -> open lost from view 1.8 s mid-gesture: the camera stays at full rate and it wakes",
          [e for _, e in ev].count("wake") == 1 and idle == [], (ev, idle))
    ev, idle, _ = camera_run(retry, pending=False)
    check("(without wake_pending the camera went idle mid-gesture and the wake was missed: the old behaviour)",
          "wake" not in [e for _, e in ev] and idle and 3.9 <= idle[0] <= 4.3, (ev, idle))

    def chin(t):  # a chin resting on a fist, still, for a long time
        return FIST, 0.05, BACK

    ev, idle, got = camera_run(chin, until=20.0)
    check("a fist held still (a chin on it): full-rate frames stop after the prewake's hold, as before",
          idle and idle[0] <= PREWAKE_HOLD + 0.3 and got <= (PREWAKE_HOLD + 0.3) * 30 + 1, (ev, idle, got))

    def chin_loose(t):  # the same, the fist reading loose (24%, not a fist) one frame a second
        return (OTHER, 0.24, BACK) if int(t * 30) % 30 == 29 else (FIST, 0.05, BACK)

    ev, idle, got = camera_run(chin_loose, until=20.0)
    check("a resting fist that reads loose now and then: the engine still lets the camera idle after the "
          "prewake's hold (it used to re-arm the wake each second and keep 30 fps indefinitely)",
          idle and idle[0] <= PREWAKE_HOLD + 0.3, (ev, idle, got))

    def lowered(t):  # a fist, then the hand is lowered out of view for good
        return (FIST, 0.08, BACK) if t < 0.3 else None

    ev, idle, got = camera_run(lowered, until=10.0)
    check("a fist, then the hand gone for good: frames stop with the prewake's hold (no extra time)",
          idle and idle[0] <= PREWAKE_HOLD + 0.3, (ev, idle, got))

    # ------------------------------------------------------------ auto-close rules
    def awake(**kw):
        s = service(**kw)
        s.state, s.awake_since = "awake", 1000.0
        return s

    s = awake()
    s._presence_tick(1004.0, 1000.0, True)
    check("away: nobody seen for 4 s -> still open", s.asked == [])
    s._presence_tick(1005.5, 1000.0, True)
    check("away: nobody seen for 5.5 s -> closes (away)", s.asked == [("sleep", "away")], s.asked)
    s = awake(auto_close_away=False)
    s._presence_tick(1060.0, 1000.0, True)
    check("away turned off: nobody seen for a minute -> stays open", s.asked == [], s.asked)

    s = awake()
    s._darkness(1001.0, True)
    s._presence_tick(1005.5, 1001.0, True)
    check("dark: 4.5 s of darkness -> still open", s.asked == [], s.asked)
    s._presence_tick(1006.5, 1001.0, True)
    check("dark: 5.5 s of darkness -> closes (dark)", s.asked == [("sleep", "dark")], s.asked)
    s = awake(auto_close_dark=False)
    s._darkness(1001.0, True)
    s._presence_tick(1100.0, 1001.0, True)
    check("dark turned off: 99 s of darkness -> stays open (the away rule can't judge the dark)", s.asked == [], s.asked)
    s._darkness(1100.0, False)
    s._presence_tick(1104.0, 1001.0, True)
    check("... the light comes back, nobody there: the away rule counts from then (4 s -> open)", s.asked == [], s.asked)
    s._presence_tick(1105.5, 1001.0, True)
    check("... 5.5 s after the light came back -> closes (away)", s.asked == [("sleep", "away")], s.asked)
    s = awake(auto_close_away=False)
    s._darkness(1001.0, True)
    s._presence_tick(1006.5, 1001.0, True)
    check("away off, dark on: darkness still closes it", s.asked == [("sleep", "dark")], s.asked)
    s = awake(auto_close_away=False, auto_close_dark=False)
    s._darkness(1001.0, True)
    s._presence_tick(2000.0, 1001.0, True)
    s._darkness(2000.0, False)
    s._presence_tick(3000.0, 1001.0, True)
    check("both auto-close rules off: it never closes by itself", s.asked == [], s.asked)
    s = awake()
    for k in range(40):  # frames flickering around the darkness threshold, nobody there
        t = 1000.0 + 0.25 * k
        s._darkness(t, k % 8 < 4)
        s._presence_tick(t, 1000.0, True)
        if s.asked:
            break
    check("both rules on, frames flickering dark / lit, nobody there: closes after 5 s as before",
          s.asked[:1] in ([("sleep", "away")], [("sleep", "dark")]) and 1005.0 < t <= 1005.5, (s.asked, t))
    s = awake()
    s._presence_tick(1100.0, 1000.0, False)
    check("closed HUD: no auto-close requests", s.asked == [])
finally:
    shutil.rmtree(SCRATCH, ignore_errors=True)

print()
print(f"{len(failures)} failure(s)" if failures else "all engine settings tests passed")
sys.exit(1 if failures else 0)
