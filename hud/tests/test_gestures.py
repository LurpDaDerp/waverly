"""Behavioural tests for the gesture engine (hud/gestures.py).

The scroll, close and wake scenarios were validated against the Linux HUD and must
pass unchanged. The wake-confidence scenarios (phantom hands on a face, flicker,
the close-then-relax loop) were added with the hand evidence score. The palm
orientation scenarios (head scratching edge-on, the back of the hand, tilted palms)
were added with the facing requirement; since then a wave must also last longer
(WAVE_SWINGS swings over WAVE_MIN_TIME), so the wave scenarios run a little longer.

Synthetic hands carry a realistic orientation: an open hand faces the camera at
yaw +15, pitch +10 (real waving palms measured |yaw| ~10-20, pitch -20..+20), a fist
shows its back (yaw 160, as the calibration clip's fist does).

The gesture settings scenarios (Settings › Controls: each open / close gesture can be
turned off) check that a gesture turned off never fires, nor its prewake, while the
others and scrolling still work.

Run:  python3 tests/test_gestures.py      (from hud/, with the venv active)
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from hud.gestures import (FIST, OTHER, PALM, WAKE_AFTER_CLOSE, WAVE_MIN_TIME, WAVE_SWINGS,  # noqa: E402
                          GestureEngine, HandObs, Seen)

FPS = 30
ASPECT = 640 / 480
FACING = (15.0, 10.0)   # (yaw, pitch) of a palm toward the camera, as measured on real palms
BACK = (160.0, -10.0)   # the back of the hand (a fist shown to the camera)
failures = []


def pose(shape):
    return BACK if shape == FIST else FACING


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"   [{detail}]" if detail else ""))
    if not ok:
        failures.append(name)


def engine(cfg=None):
    """A GestureEngine with the gesture settings in cfg (config.json keys) applied."""
    e = GestureEngine()
    if cfg:
        e.configure(cfg)
    return e


def run(seq, awake=True, cfg=None):
    """seq: (x, y, shape, openness, seconds); x/y may be callables of 0..1 progress,
    shape None = no hand detected. Returns (events, messages) with timestamps."""
    e = engine(cfg)
    t = 100.0
    events, msgs = [], []
    for x, y, shape, op, dur in seq:
        n = int(round(dur * FPS))
        for i in range(n):
            f = i / max(n, 1)
            xx = x(f) if callable(x) else x
            yy = y(f) if callable(y) else y
            obs = [] if shape is None else [HandObs(xx, yy, 0.15, shape, 1.0, False, op, yaw=pose(shape)[0],
                                                    pitch=pose(shape)[1])]
            ev, ms = e.update(t, obs, awake, awake)
            events += [(round(t - 100, 3), v) for v in ev]
            msgs += [(round(t - 100, 3), m) for m in ms]
            t += 1 / FPS
    return events, msgs


def moved(msgs, target=None):
    return round(sum(m["d"] for _, m in msgs if m["kind"] == "move" and (target is None or m["target"] == target)), 3)


def targets(msgs):
    out = {}
    for _, m in msgs:
        if m["kind"] == "move":
            out[m["target"]] = round(out.get(m["target"], 0) + m["d"], 3)
    return out


def names(events):
    return [v for _, v in events]


# ---------------------------------------------------------------- scrolling
# (right hand: side_hint +1 -> vertical strokes scroll "deadlines")
_, m = run([(0.5, 0.3, PALM, 0.98, 0.6), (0.5, lambda f: 0.3 + 0.4 * f, PALM, 0.98, 0.35), (0.5, 0.7, PALM, 0.98, 0.5)])
check("down stroke scrolls deadlines down", targets(m).keys() == {"deadlines"} and moved(m) > 0.3, targets(m))
check("stroke ends with an 'end' message", any(x["kind"] == "end" for _, x in m))

_, m = run([(0.5, 0.7, PALM, 0.98, 0.6), (0.5, lambda f: 0.7 - 0.5 * f, PALM, 0.98, 0.12), (0.5, 0.2, PALM, 0.98, 0.5)])
check("fast stroke (4 frame/s) still scrolls (no upper speed limit)", moved(m) < -0.3, moved(m))

_, m = run([(0.5, 0.5, PALM, 0.98, 0.6), (0.5, lambda f: 0.5 + 0.1 * f, PALM, 0.98, 1.5)])
check("very slow drift (0.067 frame/s) does not scroll", moved(m) == 0, moved(m))

random.seed(1)
_, m = run([(lambda f: 0.5 + random.gauss(0, 0.004), lambda f: 0.5 + random.gauss(0, 0.004), PALM, 0.98, 4.0)])
check("resting hand with tracking jitter does not scroll", moved(m) == 0, moved(m))

_, m = run([(0.5, 0.3, PALM, 0.98, 0.6), (0, 0, None, 0, 0.3), (0.5, 0.6, PALM, 0.98, 0.4)])
check("hand vanishing and reappearing elsewhere never jumps", moved(m) == 0, moved(m))

_, m = run([(0.3, 0.5, PALM, 0.98, 0.6), (lambda f: 0.3 + 0.4 * f, 0.5, PALM, 0.98, 0.4), (0.7, 0.5, PALM, 0.98, 0.4),
            (lambda f: 0.7 - 0.4 * f, 0.5, PALM, 0.98, 0.4)])
xs = [x["d"] for _, x in m if x["kind"] == "move"]
check("right then left: weather right then back", sum(xs[: len(xs) // 2]) > 0.3 and abs(moved(m)) < 0.15, round(sum(xs[: len(xs) // 2]), 3))

for op, should in ((1.0, True), (0.95, True), (0.92, True), (0.9, False), (0.7, False)):
    _, m = run([(0.5, 0.3, PALM, op, 0.6), (0.5, lambda f: 0.3 + 0.4 * f, PALM, op, 0.4), (0.5, 0.7, PALM, op, 0.4)])
    check(f"openness {op:.2f} {'scrolls' if should else 'does not scroll'} (gate 92%)", (moved(m) > 0.3) == should, moved(m))

for ang, want in ((0, "weather"), (25, "weather"), (30, "weather"), (45, None), (60, "deadlines"), (90, "deadlines")):
    a = math.radians(ang)
    dx, dy = 0.35 * math.cos(a) / ASPECT, 0.35 * math.sin(a)
    _, m = run([(0.3, 0.5, PALM, 0.98, 0.6), (lambda f: 0.3 + dx * f, lambda f: 0.5 - dy * f, PALM, 0.98, 0.4),
                (0.3 + dx, 0.5 - dy, PALM, 0.98, 0.4)])
    got = set(targets(m))
    check(f"stroke {ang} deg above horizontal -> {want or 'ignored (diagonal)'}", got == ({want} if want else set()), targets(m))

_, m = run([(0.25, 0.5, PALM, 0.98, 0.6), (lambda f: 0.25 + 0.45 * f, lambda f: 0.5 - 0.08 * (2 * f - 1) ** 2 + 0.08, PALM, 0.98, 0.45),
            (0.7, 0.5, PALM, 0.98, 0.4)])
check("sideways sweep arcing from the elbow -> weather only", set(targets(m)) == {"weather"}, targets(m))

_, m = run([(0.3, lambda f: 0.85 - 0.2 * f, PALM, 0.98, 0.25), (lambda f: 0.3 + 0.4 * f, 0.65, PALM, 0.98, 0.4), (0.7, 0.65, PALM, 0.98, 0.4)])
check("raising the arm then sweeping -> weather only (arrival ignored)", set(targets(m)) == {"weather"}, targets(m))

_, m = run([(0.5, 0.3, PALM, 0.98, 0.6), (lambda f: 0.5 + 0.04 * math.sin(6 * math.pi * f), lambda f: 0.3 + 0.4 * f, PALM, 0.98, 0.5),
            (0.5, 0.7, PALM, 0.98, 0.4)])
check("vertical stroke with sideways wobble -> vertical only", set(targets(m)) == {"deadlines"}, targets(m))

# ---------------------------------------------------------------- close (awake)
def close_run(frames, cfg=None):
    seq = [(0.5, 0.5, FIST if op < 0.2 else PALM if op > 0.8 else OTHER, op, n / FPS) for op, n in frames]
    ev, _ = run(seq, awake=True, cfg=cfg)
    return [v for v in names(ev) if v == "sleep"]


check("close: open 98% -> fist 1%", close_run([(0.98, 15), (0.5, 3), (0.01, 10)]) == ["sleep"])
check("close: open 98% -> fist 4% (threshold)", close_run([(0.98, 15), (0.5, 3), (0.04, 10)]) == ["sleep"])
# a hand curled two-thirds to three-quarters of the way read 6-12% on the user's webcam: no close
for curl in (0.06, 0.08, 0.12):
    check(f"close: hand curled most of the way ({curl:.0%}) -> no close",
          close_run([(0.98, 15), (0.5, 3), (curl, 15)]) == [])
check("close: one 3% frame inside a 7% curl -> no close",
      close_run([(0.98, 15), (0.5, 3), (0.07, 5), (0.03, 1), (0.07, 5)]) == [])
check("close: started only 90% open -> no close", close_run([(0.90, 15), (0.05, 10)]) == [])
check("close: fist reached after 1.7 s -> no close", close_run([(0.98, 15), (0.6, 50), (0.05, 10)]) == [])
check("close: a single blurry low frame -> no close", close_run([(0.98, 15), (0.05, 1), (0.98, 15)]) == [])
check("close: relaxed hand (50%) -> fist -> no close", close_run([(0.5, 20), (0.03, 10)]) == [])
ev, _ = run([(0.5, 0.5, PALM, 0.98, 0.3), (0.5, lambda f: 0.5 + 0.3 * f, PALM, 0.98, 0.4), (0.5, 0.8, OTHER, 0.4, 0.1),
             (0.5, 0.8, FIST, 0.03, 0.4)], awake=True)
check("close works mid-scroll (open -> fist while moving)", "sleep" in names(ev), names(ev))

# ---------------------------------------------------------------- wake (asleep)
def wake_run(frames):
    ev, _ = run([(x, 0.5, sh, op, n / FPS) for sh, op, x, n in frames], awake=False)
    return names(ev)


w = wake_run([(FIST, 0.10, 0.5, 5), (OTHER, 0.6, 0.5, 15), (PALM, 0.98, 0.5, 5)])
check("wake: fist 0.15 s -> open 98% after 0.5 s", w == ["prewake", "wake"], w)
check("wake: fist only 0.07 s -> nothing", wake_run([(FIST, 0.10, 0.5, 2), (PALM, 0.98, 0.5, 5)]) == [])
w = wake_run([(FIST, 0.10, 0.5, 6), (OTHER, 0.6, 0.5, 51), (PALM, 0.98, 0.5, 5)])
check("wake: opened after 1.7 s -> prewake only", w == ["prewake"], w)
w = wake_run([(FIST, 0.10, 0.5, 6), (PALM, 0.9, 0.5, 20)])
check("wake: opened only to 90% -> prewake only", w == ["prewake"], w)
check("wake: open hand alone -> nothing", wake_run([(PALM, 0.98, 0.5, 30)]) == [])
w = wake_run([(FIST, 0.4, lambda f: 0.1 + 0.3 * f, 5), (OTHER, 0.7, 0.4, 4), (PALM, 0.98, 0.4, 6)])
check("wake: blurred fist moving into view (recognizer says fist) -> wake", w == ["prewake", "wake"], w)

e = GestureEngine()
t, out = 100.0, []
for i in range(45):
    x = 0.5 + 0.08 * math.sin(2 * math.pi * 2.4 * i / 30)
    ev, _ = e.update(t, [HandObs(x, 0.4, 0.15, PALM, 1.0, False, 0.98, yaw=FACING[0], pitch=FACING[1])], False, False)
    out += ev
    t += 1 / 30
check("wake by waving ~1.5 s", "wake" in out, out)
e = GestureEngine()
t, out = 100.0, []
for i in range(60):
    x = 0.5 + 0.12 * math.sin(2 * math.pi * 2.5 * i / 30)
    if i % 4 in (2, 3):
        t += 1 / 30
        continue
    ev, _ = e.update(t, [HandObs(x, 0.4, 0.15, PALM, 1.0, False, 0.98, yaw=FACING[0], pitch=FACING[1])], False, False)
    out += ev
    t += 1 / 30
check("wake by waving with half the frames lost to blur", "wake" in out, out)
e = GestureEngine()
t, out = 100.0, []
for i in range(45):
    ev, _ = e.update(t, [HandObs(0.5 + 0.02 * math.sin(2 * math.pi * 3 * i / 30), 0.4, 0.15, PALM, 1.0, False, 0.98,
                                 yaw=FACING[0], pitch=FACING[1])], False, False)
    out += ev
    t += 1 / 30
check("hand tremor (2% swings) does not wake", "wake" not in out, out)

# ---------------------------------------------------------------- wake confidence (asleep)
# Realistic detections: the replayed calibration clips score 0.85-0.95 hand evidence, and
# an edge-on waving hand flips handedness on up to 40% of its frames. A phantom hand on a
# face that leans toward the camera scores ~0.1 (it lies inside the face box, small next to it).
def asleep_run(frames, fps=FPS, cfg=None):
    """frames: (x, shape, openness, evidence, label, n frames[, (yaw, pitch)]); shape None
    = no hand. label, x and (yaw, pitch) may be callables of the frame index. (yaw, pitch)
    is the palm's true orientation (default: pose(shape)); like handfeatures.observe, a
    frame whose label flipped (-1: the hand is labelled +1) reads the opposite normal.
    Returns (events, engine)."""
    e = engine(cfg)
    t, out, k = 100.0, [], 0
    for x, sh, op, ev, lab, n, *rest in frames:
        for i in range(n):
            xx = x(k) if callable(x) else x
            ll = lab(k) if callable(lab) else lab
            yaw, pitch = (rest[0](k) if callable(rest[0]) else rest[0]) if rest else pose(sh)
            if ll == -1:
                yaw, pitch = (yaw + 360.0) % 360.0 - 180.0, -pitch
            obs = [] if sh is None else [HandObs(xx, 0.5, 0.15, sh, float(ll), False, op, ev, ll, None, yaw, pitch)]
            got, _ = e.update(t, obs, False, False)
            out += got
            t += 1 / fps
            k += 1
    return out, e


def wave_x(amp=0.08, hz=2.4, fps=FPS):
    return lambda k: 0.5 + amp * math.sin(2 * math.pi * hz * k / fps)


w, e = asleep_run([(wave_x(), PALM, 0.98, 0.85, 1, 45)])
check("wave with realistic evidence (0.85) wakes", "wake" in w, w)
check("an accepted wake is logged with its confidence",
      any(n.startswith("wake by wave accepted: confidence") for n in e.notes), e.notes[-1:])
w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.85, lambda k: -1 if k % 5 in (1, 3) else 1, 45)])
check("wave whose handedness flips on 40% of frames (edge-on hand) still wakes", "wake" in w, w)
w, _ = asleep_run([(wave_x(fps=15), PALM, 0.98, 0.85, 1, 23)], fps=15)
check("wave at 15 fps (the camera's rate to the engine) wakes", "wake" in w, w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.8, 1, 5), (0.5, OTHER, 0.6, 0.8, 1, 4), (0.5, PALM, 0.98, 0.8, 1, 5)])
check("fist -> open with realistic evidence (0.8) wakes", w == ["prewake", "wake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.8, 1, 3), (0.5, OTHER, 0.6, 0.8, 1, 2), (0.5, PALM, 0.98, 0.8, 1, 4)], fps=15)
check("quick fist -> open at 15 fps wakes", w == ["prewake", "wake"], w)

w, e = asleep_run([(wave_x(amp=0.12), PALM, 0.98, 0.09, lambda k: 1 if k % 3 else -1, 150)])
check("phantom hand on a face, swinging like a wave for 5 s -> nothing", w == [], w)
check("rejected wake candidates are logged with gesture and score breakdown",
      any(n.startswith("wake by wave rejected: confidence 0.09") and "frames look like a hand" in n
          and "same hand" in n for n in e.notes), e.notes)
check("rejections are rate-limited (one note per 2 s per kind)", 2 <= len(e.notes) <= 6, len(e.notes))
w, _ = asleep_run([(0.5, FIST, 0.05, 0.09, 1, 10), (0.5, PALM, 0.98, 0.09, 1, 10)])
check("phantom fist -> open on a face -> nothing (not even prewake)", w == [], w)
w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.45, 1, 60)])
check("low-confidence detections (evidence 0.45) waving -> no wake", "wake" not in w and "prewake" not in w, w)
w, _ = asleep_run([(0.5, FIST, 0.05, 0.9, 1, 1), (0.5, None, 0, 0, 0, 45), (0.5, FIST, 0.05, 0.9, 1, 1),
                   (0.5, None, 0, 0, 0, 2), (0.5, PALM, 0.98, 0.9, 1, 1)])
check("one-frame flickers: fist, 1.5 s later fist, then open -> nothing", w == [], w)
w, _ = asleep_run([(0.5, FIST, 0.05, 0.9, 1, 2), (0.5, None, 0, 0, 0, 18), (0.5, FIST, 0.05, 0.9, 1, 2),
                   (0.5, PALM, 0.98, 0.9, 1, 3)])
check("a fist that drops out of view for 0.6 s does not count as held", "wake" not in w, w)
w, _ = asleep_run([(0.5, FIST, 0.05, 0.9, 1, 2), (0.5, PALM, 0.98, 0.9, 1, 1)], fps=8)
check("a 3-frame fist -> open burst (8 fps) that vanishes (too few frames) -> no wake", "wake" not in w, w)
w, _ = asleep_run([(0.5, FIST, 0.05, 0.9, 1, 2), (0.5, PALM, 0.98, 0.9, 1, 1), (0.5, None, 0, 0, 0, 2),
                   (0.5, PALM, 0.98, 0.9, 1, 2)], fps=8)
check("the same with the open hand seen again a moment later -> wake", "wake" in w, w)
w, _ = asleep_run([(wave_x(amp=0.1, hz=3), PALM, 0.98, 0.9, 1, 9)])
check("a 0.3 s burst of side-to-side jitter -> no wake", "wake" not in w, w)


def close_then(after, gap=0):
    """Awake: open hand, then a fist closes the HUD. Then (asleep) `after` frames
    (shape, openness, n), optionally after `gap` frames without a hand."""
    e = GestureEngine()
    t, awake, out = 100.0, True, []
    seq = [(PALM, 0.98, 15), (FIST, 0.02, 6)] + [(None, 0, gap)] + after
    for sh, op, n in seq:
        for _ in range(n):
            obs = [] if sh is None else [HandObs(0.5, 0.5, 0.15, sh, 1.0, False, op, 0.9, 1, None, *pose(sh))]
            ev, _ = e.update(t, obs, awake, awake)
            out += ev
            if "sleep" in ev:
                awake = False
            t += 1 / FPS
    return out


w = close_then([(FIST, 0.05, 15), (PALM, 0.98, 60)])
check("close with a fist, then relax the hand open -> the HUD stays closed", w == ["sleep"], w)
w = close_then([(FIST, 0.05, 6), (OTHER, 0.25, 1), (FIST, 0.05, 8), (PALM, 0.98, 60)])
check("... even if one noisy frame of the held fist reads 25% open", w == ["sleep"], w)

e = GestureEngine()  # rejection notes: rate-limited, but an accepted wake resets the limit
e.seen.extend(Seen(100 + k / 30, 0.1, 1, None, *FACING, False) for k in range(15))
e.seen.extend(Seen(100.5 + k / 30, 0.9, 1, None, *FACING, False) for k in range(45))
got = [e._sure("fist", "wake", 100.0, 100.2, 4), e._sure("fist", "wake", 100.0, 100.3, 4),
       e._sure("fist", "wake", 100.5, 101.0, 4), e._sure("fist", "wake", 100.0, 101.1, 4)]
check("after an accepted wake the next rejection is logged at once, without a stale count",
      got == [False, False, True, False] and len(e.notes) == 3 and "similar" not in e.notes[-1], e.notes)
w = close_then([(PALM, 0.98, int(WAKE_AFTER_CLOSE * FPS)), (FIST, 0.05, 6), (OTHER, 0.6, 3), (PALM, 0.98, 5)])
check("close, open, then a new fist -> open wakes again", w == ["sleep", "prewake", "wake"], w)
w = close_then([(FIST, 0.05, 6), (OTHER, 0.6, 3), (PALM, 0.98, 5)], gap=60)
check("close, the hand leaves, later a fist -> open wakes", w == ["sleep", "prewake", "wake"], w)

# ---------------------------------------------------------------- palm orientation (asleep)
# A wake counts only with the palm toward the camera: |yaw| <= 30, |pitch| <= 45. Measured on
# the calibration clips: real waving palms read |yaw| ~10-20 and pitch -20..+20; the back of
# the hand |yaw| 130-180; a hand seen edge-on |yaw| 40-90.
def wakes(w):
    return "wake" in w


for yaw in (60, 75, 90, -60, -90):
    w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 90, (yaw, 5.0))])
    check(f"edge-on hand (yaw {yaw}) waving 3 s, like scratching the head sideways -> nothing", w == [], w)
for pose_ in ((180.0, 0.0), (160.0, -10.0), (-150.0, 20.0)):
    w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 90, pose_)])
    check(f"back of the hand (yaw {pose_[0]:.0f}) waving 3 s -> nothing", w == [], w)
w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.9, lambda k: -1 if k % 5 in (2, 3) else 1, 90, BACK)])
check("back of the hand waving, its label flipping on 40% of frames (would read as a palm) -> nothing", w == [], w)
for pitch in (60.0, -60.0):
    w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 90, (10.0, pitch))])
    check(f"palm tilted {'up' if pitch > 0 else 'down'} 60 deg, waving 3 s -> nothing", w == [], w)
for pose_ in ((35.0, 0.0), (0.0, 50.0)):
    w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 90, pose_)])
    check(f"palm just outside the tolerance (yaw {pose_[0]:.0f}, pitch {pose_[1]:.0f}) -> no wake", not wakes(w), w)
for pose_ in ((25.0, 40.0), (-25.0, -40.0), (25.0, -40.0), (-25.0, 40.0), (0.0, 0.0)):
    w, e = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 45, pose_)])
    check(f"palm facing within tolerance (yaw {pose_[0]:+.0f}, pitch {pose_[1]:+.0f}) waving 1.5 s -> wake", wakes(w), w)
    if pose_ == (25.0, 40.0):
        check("the wake log line gives the palm's yaw, pitch and facing share",
              any(n.startswith("wake by wave accepted") and "palm facing 38 of 38 open frames (100%" in n
                  and "|yaw| median 25" in n and "pitch median +40" in n and "yaw/pitch now +25/+40" in n
                  for n in e.notes), [n for n in e.notes if n.startswith("wake")])
w, e = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 90, (75.0, 5.0))])
check("a rejected wave is logged with the palm's orientation",
      any(n.startswith("wake by wave rejected") and "palm facing 0 of" in n and "|yaw| median 75" in n for n in e.notes),
      e.notes)


def scratch(k):
    """Raise the hand palm-first (0.4 s), scratch the head sideways, edge-on, for 2 s
    (now and then the palm flashes toward the camera), then lower it palm-first."""
    if k < 12 or k >= 72:
        return (15.0, 10.0)
    return (15.0, 10.0) if k % 9 == 0 else (70.0 + 15 * math.sin(k), 5.0)


def scratch_x(k):
    return 0.5 + (0.06 * math.sin(2 * math.pi * 3 * (k - 12) / FPS) if 12 <= k < 72 else 0.0)


w, _ = asleep_run([(scratch_x, PALM, 0.97, 0.9, 1, 87, scratch)])
check("scratching the head sideways (edge-on, swinging 2 s) between a palm-first raise and lower -> nothing",
      w == [], w)
w, _ = asleep_run([(scratch_x, OTHER, 0.7, 0.9, lambda k: -1 if k % 3 == 0 else 1, 87, scratch)])
check("... with curled fingers and the label flipping on a third of the frames -> nothing", w == [], w)


def flap(k, hz=2.0):
    """A wave from the wrist, as on calibration/waving.mov: the palm faces the camera at
    the top of each flap and the hand folds forward (back of the hand, pitch -60) between."""
    return (15.0, 10.0) if math.cos(2 * math.pi * hz * k / FPS) > -0.2 else (150.0, -60.0)


w, _ = asleep_run([(wave_x(amp=0.08, hz=2.0), PALM, 0.98, 0.9, 1, 60, flap)])
check("a wave from the wrist (palm to the camera at the top of each flap) wakes", wakes(w), w)

# waving takes a little longer now: 4 swings over at least WAVE_MIN_TIME s
w, _ = asleep_run([(wave_x(), PALM, 0.98, 0.9, 1, 24)])
check("a quick 0.8 s wave (4 swings; 3 used to wake) -> no wake", not wakes(w), w)
e = GestureEngine()
t, woke = 100.0, None
for k in range(60):
    ev, _ = e.update(t, [HandObs(wave_x()(k), 0.5, 0.15, PALM, 1.0, False, 0.98, 0.9, 1, None, *FACING)], False, False)
    if "wake" in ev and woke is None:
        woke = t - 100.0
    t += 1 / FPS
check(f"the same wave kept up for 2 s wakes, after at least {WAVE_MIN_TIME} s and {WAVE_SWINGS} swings",
      woke is not None and WAVE_MIN_TIME - 1e-6 <= woke <= WAVE_MIN_TIME + 0.2, woke)
w, _ = asleep_run([(wave_x(hz=1.2), PALM, 0.98, 0.9, 1, 75)])
check("a slow wave (1.2 Hz) for 2.5 s wakes", wakes(w), w)
w, _ = asleep_run([(0.5, PALM, 0.98, 0.9, 1, 60), (lambda k: wave_x()(k - 60), PALM, 0.98, 0.9, 1, 24)])
check("a palm held still for 2 s, then a quick 0.8 s wave -> no wake (the wave's time starts with the swinging)",
      not wakes(w), w)

# fist -> open: the open hand must face the camera (the fist itself is exempt)
for pose_ in ((80.0, 5.0), (-75.0, 0.0), (170.0, 0.0), (10.0, -65.0)):
    w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.6, 0.9, 1, 4, pose_), (0.5, PALM, 0.98, 0.9, 1, 30, pose_)])
    check(f"fist -> open hand ending edge-on / away (yaw {pose_[0]:.0f}, pitch {pose_[1]:.0f}) -> prewake only",
          w == ["prewake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.6, 0.9, 1, 3, (80.0, 0.0)),
                   (0.5, PALM, 0.98, 0.9, 1, 4, (60.0, 0.0)), (0.5, PALM, 0.98, 0.9, 1, 6)])
check("fist -> opens edge-on, then turns the palm to the camera within 1.5 s -> wake", w == ["prewake", "wake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.6, 0.9, 1, 3, (80.0, 0.0)), (0.5, PALM, 0.98, 0.9, 1, 1),
                   (0.5, PALM, 0.98, 0.9, 1, 1, (80.0, 0.0)), (0.5, PALM, 0.98, 0.9, 1, 30, (80.0, 0.0))])
check("fist -> open with a single facing frame among edge-on ones -> no wake", w == ["prewake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6, (10.0, 0.0)), (0.5, PALM, 0.98, 0.9, 1, 3)])
check("fist (seen from the front) -> open facing at once -> wake", w == ["prewake", "wake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, PALM, 0.98, 0.9, 1, 6, (None, None))])
check("an open hand of unknown orientation never wakes", "wake" not in w, w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, PALM, 0.98, 0.9, 1, 6, (float("nan"), 0.0)),
                   (0.5, PALM, 0.98, 0.9, 1, 6, (10.0, None))])
check("an open hand with a non-finite or half-known orientation never wakes (and does not crash)", "wake" not in w, w)
# (seen at 12 fps on calibration/waving.mov: a fist, then the hand opens palm-down with one frame
# misread as facing, then sweeps on edge-on / palm-down: the old rule woke on that single frame)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 4), (0.5, PALM, 0.98, 0.9, 1, 1),
                   (0.5, PALM, 0.98, 0.9, 1, 15, (110.0, -5.0))], fps=12)
check("fist -> one facing open frame right after the fist, then palm-down / edge-on (12 fps) -> prewake only",
      w == ["prewake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 4), (0.5, PALM, 0.98, 0.9, 1, 2),
                   (0.5, PALM, 0.98, 0.9, 1, 15, (110.0, -5.0))], fps=12)
check("... two facing open frames -> still prewake only (the open hand must face on 3)", w == ["prewake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 4), (0.5, PALM, 0.98, 0.9, 1, 4)], fps=12)
check("fist -> open hand facing for 0.3 s (12 fps) -> wake", w == ["prewake", "wake"], w)

# ---------------------------------------------------------------- the first try (asleep)
# Real use (MacBook Air camera): a fist shown back to the camera turns round as it opens, and the
# hand model loses it edge-on for 0.6-1.6 s ("wake by fist missed: the hand left view for 1.1s; after
# the fist the hand opened to at most 78%"): the armed fist used to be dropped after 0.5 s out of
# view, so the first try missed and only a second, palm-first fist woke. An armed fist that was
# clearly a real hand now survives WAKE_DROPOUT s out of detection, not counted in WAKE_WITHIN.
EDGE = (90.0, -10.0)


def turning(lost_s, fps=FPS, ev=0.9, end=FACING, fist_frames=6):
    """A fist back to the camera, the hand turning edge-on as it opens, lost for lost_s,
    then the open hand (pose `end`) held for 0.3 s."""
    return [(0.5, FIST, 0.08, ev, 1, fist_frames), (0.5, OTHER, 0.5, ev, 1, max(1, round(0.1 * fps)), EDGE),
            (0.5, None, 0, 0, 0, round(lost_s * fps)), (0.5, PALM, 0.98, ev, 1, max(3, round(0.3 * fps)), end)]


for lost in (0.6, 1.1, 1.6, 1.9):
    w, e = asleep_run(turning(lost))
    check(f"first try: fist back to the camera, lost {lost} s while turning, opens facing -> wake",
          w == ["prewake", "wake"], (w, e.notes[-2:]))
check("... and the log says the hand was lost but the fist stayed armed",
      any(n.startswith("wake by fist: the hand was out of view for 1.9s") and "still armed" in n for n in e.notes),
      e.notes)
w, _ = asleep_run(turning(1.1, fps=12, fist_frames=3), fps=12)
check("first try at 12 fps (lost 1.1 s while turning) -> wake", w == ["prewake", "wake"], w)
w, e = asleep_run(turning(2.6))
check("lost longer than WAKE_DROPOUT (2.6 s) -> prewake only, and the miss is logged while the hand is gone",
      w == ["prewake"] and any("wake by fist missed: the hand left view for 2.0s (2.0s in all, more than the 2.0s" in n
                               for n in e.notes), (w, e.notes))
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, None, 0, 0, 0, 36), (0.5, OTHER, 0.5, 0.9, 1, 3, EDGE),
                   (0.5, None, 0, 0, 0, 36), (0.5, PALM, 0.98, 0.9, 1, 9)])
check("lost twice, 2.4 s in all (over WAKE_DROPOUT) -> prewake only", w == ["prewake"], w)
w, _ = asleep_run(turning(1.1, end=BACK))
check("lost while turning, then the back of the open hand -> prewake only (the palm rule stands)",
      w == ["prewake"], w)
w, _ = asleep_run(turning(1.1, end=EDGE))
check("lost while turning, then an edge-on open hand (head scratching) -> prewake only", w == ["prewake"], w)
w, _ = asleep_run([(0.5, FIST, 0.05, 0.09, 1, 10), (0.5, None, 0, 0, 0, 30), (0.5, PALM, 0.98, 0.9, 1, 9)])
check("a phantom fist on a face, then 1 s later a real facing palm -> nothing (only a real fist may be lost)",
      w == [], w)
w, _ = asleep_run([(0.5, FIST, 0.05, 0.9, 1, 2), (0.5, None, 0, 0, 0, 30), (0.5, PALM, 0.98, 0.9, 1, 9)])
check("a fist too brief to arm, lost 1 s, then a facing palm -> nothing", w == [], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.6, 0.9, 1, 51), (0.5, PALM, 0.98, 0.9, 1, 9)])
check("in view all along, opened only after 1.7 s -> prewake only (WAKE_WITHIN unchanged)", w == ["prewake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.5, 0.9, 1, 3, EDGE), (0.5, None, 0, 0, 0, 30),
                   (0.5, FIST, 0.08, 0.9, 1, 6, (10.0, 0.0)), (0.5, PALM, 0.98, 0.9, 1, 6)])
check("lost while turning, the hand comes back as a fist (trying again), then opens -> one prewake, then wake",
      w == ["prewake", "wake"], w)
w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.5, 0.9, 1, 3, EDGE), (0.5, None, 0, 0, 0, 36),
                   (0.5, FIST, 0.08, 0.9, 1, 6, (10.0, 0.0)), (0.5, OTHER, 0.5, 0.9, 1, 3, EDGE),
                   (0.5, None, 0, 0, 0, 36), (0.5, PALM, 0.98, 0.9, 1, 9)])
check("lost 1.2 s, back as a fist, lost 1.2 s again (2.4 s in all) -> prewake only (WAKE_DROPOUT is a total, "
      "the fist coming back does not refill it)", w == ["prewake"], w)
# The confidence is averaged since the fist: a real fist's frames must not vouch for a phantom
# "open palm" (a face leaning in, ~0.1 evidence) seen after the hand was lost for a moment.
for lost in (0.3, 0.8, 1.5, 1.9):
    for n in (3, 8):
        w, _ = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 9), (0.5, None, 0, 0, 0, round(lost * FPS)),
                           (0.5, PALM, 0.97, 0.09, 1, n)])
        check(f"a real fist, lost {lost} s, then {n} phantom facing 'open palm' frames on a face -> prewake only",
              w == ["prewake"], w)
w, e = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 9), (0.5, None, 0, 0, 0, 30), (0.5, PALM, 0.97, 0.09, 1, 3),
                   (0.5, PALM, 0.98, 0.9, 1, 6)])
check("... and a real facing palm right after the phantom frames still wakes (the last open frames count)",
      w == ["prewake", "wake"], (w, e.notes[-3:]))
w, e = asleep_run([(0.5, FIST, 0.08, 0.9, 1, 9), (0.5, None, 0, 0, 0, 30), (0.5, PALM, 0.98, 0.9, 1, 1),
                   (0.5, PALM, 0.98, 0.47, 1, 1), (0.5, PALM, 0.98, 0.9, 1, 1), (0.5, None, 0, 0, 0, 30)])
check("a real palm with one frame just under GOOD_FRAME (0.47, seen on calibration/waving.mov) still wakes",
      w == ["prewake", "wake"], (w, e.notes[-3:]))


# wake_pending: the engine keeps full-rate frames while a fist -> open could still complete
def pending_trace(frames, fps=FPS):
    """asleep_run, also recording (t - 100, wake_pending) after every frame."""
    e = engine()
    t, trace, out = 100.0, [], []
    for x, sh, op, ev, lab, n, *rest in frames:
        for _ in range(n):
            yaw, pitch = rest[0] if rest else pose(sh)
            obs = [] if sh is None else [HandObs(x, 0.5, 0.15, sh, 1.0, False, op, ev, lab, None, yaw, pitch)]
            got, _ = e.update(t, obs, False, False)
            out += got
            trace.append((round(t - 100, 3), e.wake_pending(t)))
            t += 1 / fps
    return trace, out, e


def pending_at(trace, t0, t1):
    return [p for t, p in trace if t0 <= t <= t1 + 1e-9]


trace, out, e = pending_trace(turning(1.9))
check("wake_pending: on from the armed fist through 1.9 s out of view until the wake, then off",
      all(pending_at(trace, 0.2, 2.15)) and out == ["prewake", "wake"] and not trace[-1][1], trace[::10])
trace, _, _ = pending_trace(turning(4.0)[:3] + [(0.5, None, 0, 0, 0, 1)])
off = next((t for t, p in trace if t > 0.2 and not p), None)
check("wake_pending: a hand lost for good stops holding the camera WAKE_DROPOUT s after it was last seen",
      off is not None and 2.2 <= off <= 2.45, off)
trace, _, _ = pending_trace([(0.5, FIST, 0.05, 0.9, 1, 300)])
off = next((t for t, p in trace if t > 0.2 and not p), None)
check("wake_pending: a fist held still (a chin on it) holds the camera at most WAKE_PENDING_FIST s",
      off is not None and 2.9 <= off <= 3.1, off)
trace, _, _ = pending_trace([(0.5, FIST, 0.05, 0.09, 1, 30), (0.5, None, 0, 0, 0, 30)])
check("wake_pending: never for a phantom fist on a face", not any(p for _, p in trace))
trace, _, _ = pending_trace([(0.5, FIST, 0.08, 0.9, 1, 6), (0.5, OTHER, 0.6, 0.9, 1, 60)])
off = next((t for t, p in trace if t > 0.2 and not p), None)
check("wake_pending: a hand in view that never opens fully lets go WAKE_WITHIN s after the fist",
      off is not None and 1.6 <= off <= 1.75, off)
loose = [(0.5, OTHER, 0.24, 0.9, 1, 1) if k % 30 == 29 else (0.5, FIST, 0.12, 0.9, 1, 1) for k in range(20 * FPS)]
trace, _, _ = pending_trace(loose)
off = next((t for t, p in trace if t > 0.2 and not p), None)
check("wake_pending: a resting fist that reads loose (24%) one frame a second still lets go after "
      "WAKE_PENDING_FIST s (a fist that loosens in view does not re-arm)",
      off is not None and off <= 3.2 and not any(p for t, p in trace if t > 3.2), off)
loose = [(0.5, OTHER, 0.24, 0.9, 1, 1) if k % 60 == 59 else (0.5, FIST, 0.12, 0.9, 1, 1) for k in range(20 * FPS)]
trace, _, _ = pending_trace(loose)
check("wake_pending: ... also with a loose frame every 2 s", not any(p for t, p in trace if t > 3.2),
      next((t for t, p in trace if t > 3.2 and p), None))
e = engine({"gesture_open_fist": False})
e.update(100.0, [HandObs(0.5, 0.5, 0.15, FIST, 1.0, False, 0.05, 0.9, 1, None, *BACK)], False, False)
check("wake_pending: never with the fist wake turned off", not e.wake_pending(100.0))


# The app's engine sees 10-16 fps with a hand in view. On calibration/waving.mov at 10-12 fps a
# wrist wave is detected mostly at the top of each flap (palm facing) and now and then folded
# down (back of the hand), with gaps of up to ~0.5 s when it blurs at the bottom.
def wrist_wave_10fps(k):
    """10 fps: palm raised at x 0.15, then (0.2 s later) folded down at x 0.30, then lost."""
    return [(0.15, FACING), None, (0.30, BACK), None][k % 4]


frames = [(0.5, None, 0, 0, 0, 1) if wrist_wave_10fps(k) is None else
          (wrist_wave_10fps(k)[0], PALM, 0.98, 0.9, 1, 1, wrist_wave_10fps(k)[1]) for k in range(24)]
w, _ = asleep_run(frames, fps=10)
check("a wrist wave at 10 fps, detections alternating palm / back of the hand, 2.4 s -> wake", wakes(w), w)
w, _ = asleep_run([(0.15 if k % 2 == 0 else 0.30, PALM, 0.98, 0.9, 1, 1, FACING if k % 4 == 0 else BACK)
                   for k in range(24)], fps=10)
check("... but with the palm shown on only a quarter of the frames -> no wake", not wakes(w), w)
w, _ = asleep_run([(wave_x(fps=12), PALM, 0.98, 0.9, 1, 11), (0.5, None, 0, 0, 0, 6),
                   (lambda k: wave_x(fps=12)(k - 6), PALM, 0.98, 0.9, 1, 11)], fps=12)
check("a wave (12 fps) that blurs out of detection for 0.55 s halfway still wakes (0.9 s + 0.9 s)", wakes(w), w)
w, _ = asleep_run([(wave_x(fps=12), PALM, 0.98, 0.9, 1, 11), (0.5, None, 0, 0, 0, 9),
                   (lambda k: wave_x(fps=12)(k - 9), PALM, 0.98, 0.9, 1, 11)], fps=12)
check("... but a 0.8 s gap splits it into two short waves -> no wake", not wakes(w), w)

# ---------------------------------------------------------------- gesture settings (Settings › Controls)
WAVE = [(wave_x(), PALM, 0.98, 0.9, 1, 60)]
FIST_OPEN = [(0.5, FIST, 0.08, 0.9, 1, 5), (0.5, OTHER, 0.6, 0.9, 1, 4), (0.5, PALM, 0.98, 0.9, 1, 5)]
CLOSE = [(0.98, 15), (0.5, 3), (0.02, 10)]
DOWN_STROKE = [(0.5, 0.3, PALM, 0.98, 0.6), (0.5, lambda f: 0.3 + 0.4 * f, PALM, 0.98, 0.35), (0.5, 0.7, PALM, 0.98, 0.5)]

w, _ = asleep_run(WAVE)
check("settings default: a wave wakes", wakes(w), w)
w, _ = asleep_run(WAVE, cfg={"gesture_open_wave": False})
check("wave turned off: a wave wakes nothing, not even a prewake", w == [], w)
w, _ = asleep_run(FIST_OPEN, cfg={"gesture_open_wave": False})
check("wave turned off: fist -> open still wakes", w == ["prewake", "wake"], w)
w, _ = asleep_run(FIST_OPEN, cfg={"gesture_open_fist": False})
check("fist -> open turned off: it wakes nothing, not even a prewake", w == [], w)
w, _ = asleep_run(WAVE, cfg={"gesture_open_fist": False})
check("fist -> open turned off: a wave still wakes", wakes(w), w)
off = {"gesture_open_wave": False, "gesture_open_fist": False}
w, e = asleep_run(WAVE + [(0.5, None, 0, 0, 0, 30)] + FIST_OPEN, cfg=off)
check("both open gestures off: neither a wave nor fist -> open wakes", w == [] and not e.can_wake, w)
check("close turned off: open palm -> fist closes nothing", close_run(CLOSE, cfg={"gesture_close_fist": False}) == [])
check("close turned off: the wake gestures' settings don't matter to it",
      close_run(CLOSE, cfg={"gesture_open_wave": False, "gesture_open_fist": False}) == ["sleep"])
_, m = run(DOWN_STROKE, cfg={"gesture_close_fist": False, **off})
check("every gesture off: hand scrolling still works", targets(m).keys() == {"deadlines"} and moved(m) > 0.3, targets(m))
ev, _ = run([(0.5, 0.5, PALM, 0.98, 0.5), (0.5, 0.5, FIST, 0.05, 0.5), (0.5, 0.5, PALM, 0.98, 0.5)],
            cfg={"gesture_close_fist": False})
check("close turned off: a fist while awake leaves the HUD open (no events at all)", names(ev) == [], names(ev))

e = GestureEngine()
check("configure reports what changed", e.configure({"gesture_open_wave": False, "gesture_open_fist": True})
      == ["open_wave"] and e.configure({"gesture_open_wave": False}) == [], (e.open_wave, e.open_fist))
check("configure: a missing key means on", e.configure({}) == ["open_wave"] and e.open_wave and e.close_fist)

# turning the wave off halfway through a wave forgets its swings; on again, it starts afresh
e, t, out = GestureEngine(), 100.0, []
for i in range(120):
    if i == 30:
        e.configure({"gesture_open_wave": False})
    if i == 50:
        e.configure({"gesture_open_wave": True})
    x = wave_x()(i)
    ev, _ = e.update(t, [HandObs(x, 0.5, 0.15, PALM, 1.0, False, 0.98, 0.9, 1, None, *FACING)], False, False)
    out += [(i, v) for v in ev]
    t += 1 / FPS
first = next((i for i, v in out if v == "wake"), None)
check("wave turned off mid-wave, then on: nothing while off, a fresh full wave wakes after",
      first is not None and first >= 50 + int(WAVE_MIN_TIME * FPS) and all(i < 30 or i >= 50 for i, _ in out), out)

# turning the close off between the fist's first frame and its second, then on again while
# the fist is still held: it does not close (it starts again from an open hand)
e, t, out = GestureEngine(), 100.0, []
for i, (shape, op) in enumerate([(PALM, 0.98)] * 15 + [(FIST, 0.05)] * 15):
    if i == 16:
        e.configure({"gesture_close_fist": False})
    if i == 20:
        e.configure({})
    ev, _ = e.update(t, [HandObs(0.5, 0.5, 0.15, shape, 1.0, False, op, yaw=pose(shape)[0], pitch=pose(shape)[1])],
                     True, True)
    out += [(i, v) for v in ev]
    t += 1 / FPS
check("close turned off mid-gesture, then on: the fist still held closes nothing",
      out == [], out)

# per-frame hand evidence (needs mediapipe: run with the venv's python)
try:
    import numpy as np
    from hud.handfeatures import hand_evidence, palm_orientation
except ImportError as err:
    print(f"SKIP hand evidence checks ({err})")
else:
    def hand(cx=0.5, cy=0.6, s=0.25, finger=1.0):
        """21 image landmarks of an open right hand, about s tall, middle finger scaled by finger."""
        p = np.zeros((21, 2), dtype=np.float32)
        p[0] = (0, 0.5)
        for k, (dx, ang) in enumerate(((-0.25, -0.9), (-0.1, -0.15), (0.0, 0.0), (0.1, 0.12), (0.2, 0.3))):
            base = np.array((dx * 0.6, 0.1 if k == 0 else 0.0))
            seg = np.array((math.sin(ang), -math.cos(ang))) * (0.11 if k else 0.09)
            seg = seg * (finger if k == 2 else 1.0)
            for j in range(4):
                p[1 + 4 * k + j] = base + seg * j
        return (np.array((cx, cy)) + p * s).astype(np.float32)

    def ev(pts, hs=0.97, cat="Open_Palm", faces=()):
        return hand_evidence(pts, pts * np.array((640 / 480, 1.0), dtype=np.float32), hs, cat, 0.9, faces)

    real, parts = ev(hand())
    check("a well-formed, confidently labelled hand has evidence ~1", real >= 0.95, (round(real, 2), parts))
    face = (0.3, 0.2, 0.45, 0.6)  # a face filling much of the frame (leaning in)
    small = hand(cx=0.52, cy=0.6, s=0.12)
    got, parts = ev(small, cat="None", faces=[face])
    check("a small 'hand' wholly inside a big face -> evidence <= 0.1", got <= 0.1, (round(got, 2), parts))
    got, _ = ev(hand(cx=0.12, cy=0.55, s=0.25), faces=[face])
    check("a hand beside the face is not penalised", got >= 0.95, round(got, 2))
    got, _ = ev(hand(cx=0.5, cy=0.42, s=0.5), faces=[(0.35, 0.3, 0.3, 0.3)])
    check("a hand in front of the face (as big as it) is not penalised", got >= 0.95, round(got, 2))
    got, _ = ev(hand(cx=0.5, cy=0.4, s=0.7), faces=[(0.2, 0.05, 0.6, 0.9)])
    check("a hand wholly inside a face's box but not small next to it (44%) is not penalised", got >= 0.95,
          round(got, 2))
    got, _ = ev(hand(), hs=0.5)
    check("a coin-toss handedness (0.5) halves the evidence", 0.45 <= got <= 0.55, round(got, 2))
    got, parts = ev(hand(finger=5.0))
    check("implausible proportions (middle finger 3x the hand's size) halve the evidence", got <= 0.55,
          (round(got, 2), parts))


    def world_hand(yaw=0.0, pitch=0.0):
        """3D world landmarks (metres) of a flat open hand, fingers up, whose palm faces
        the camera for the model label "Right" (index knuckle toward +x), then turned
        by yaw (about the vertical axis) and pitch (about the horizontal)."""
        p = np.zeros((21, 3))
        for k, dx in enumerate((-0.035, 0.03, 0.01, -0.01, -0.03)):  # thumb, index .. pinky
            base = np.array((dx if k else 0.035, -0.08 if k else -0.03, 0.0))
            for j in range(4):
                p[1 + 4 * k + j] = base + np.array((0.0, -0.025 * j, 0.0))
        a, b = math.radians(-yaw), math.radians(-pitch)
        ry = np.array(((math.cos(a), 0, math.sin(a)), (0, 1, 0), (-math.sin(a), 0, math.cos(a))))
        rx = np.array(((1, 0, 0), (0, math.cos(b), -math.sin(b)), (0, math.sin(b), math.cos(b))))
        return p @ (ry @ rx).T

    def centred(cx=0.5, cy=0.5):
        return np.full((21, 2), (cx, cy))

    errs = []
    for yaw in (-60, -25, 0, 15, 25, 60):
        for pitch in (-40, 0, 20, 40):
            y, pp = palm_orientation(world_hand(yaw, pitch), centred(), ASPECT, "Right")
            errs.append(max(abs(y - yaw), abs(pp - pitch)))
    check("palm_orientation recovers yaw / pitch of a hand in the image centre (within 0.5 deg)", max(errs) < 0.5,
          round(max(errs), 3))
    y, pp = palm_orientation(world_hand(0, 0), centred(), ASPECT, "Left")
    check("the same knuckles labelled as the other hand read as the back of the hand (|yaw| 180)",
          abs(abs(y) - 180) < 0.5 and abs(pp) < 0.5, (round(y, 1), round(pp, 1)))
    y, pp = palm_orientation(world_hand(180, 0), centred(), ASPECT, "Right")
    check("a hand turned 180 deg shows its back (|yaw| 180)", abs(abs(y) - 180) < 0.5, round(y, 1))
    y, _ = palm_orientation(world_hand(90, 0), centred(), ASPECT, "Right")
    check("an edge-on hand reads |yaw| 90", abs(abs(y) - 90) < 0.5, round(y, 1))
    # perspective: at the left edge of the frame the camera is ~29 deg to the right (diagonal
    # field of view 70 deg), so a palm turned 29 deg right faces the lens, and one parallel to
    # the screen is turned 29 deg away from it
    y, pp = palm_orientation(world_hand(29.2, 0), centred(0.0, 0.5), ASPECT, "Right")
    check("a palm aimed at the lens from the frame's left edge reads ~0", abs(y) < 1.0 and abs(pp) < 1.0,
          (round(y, 1), round(pp, 1)))
    y, _ = palm_orientation(world_hand(0, 0), centred(0.0, 0.5), ASPECT, "Right")
    check("a palm parallel to the screen at the frame's left edge reads ~-29", abs(y + 29.2) < 1.0, round(y, 1))
    y, pp = palm_orientation(world_hand(0, -22.3), centred(0.5, 0.0), ASPECT, "Right")
    check("a palm aimed at the lens from the frame's top edge reads ~0", abs(y) < 1.0 and abs(pp) < 1.0,
          (round(y, 1), round(pp, 1)))
    flat = np.zeros((21, 3))
    check("degenerate knuckles -> orientation unknown", palm_orientation(flat, centred(), ASPECT, "Right") == (None, None))
    nan = world_hand(0, 0)
    nan[5] = np.nan
    check("a non-finite landmark -> orientation unknown", palm_orientation(nan, centred(), ASPECT, "Right") == (None, None))

    from types import SimpleNamespace as NS
    from hud.handfeatures import observe

    def fake_result(world):
        pts = hand()
        lm = [NS(x=float(x), y=float(y), z=0.0) for x, y in pts]
        return NS(hand_landmarks=[lm], gestures=[[NS(category_name="Open_Palm", score=0.9)]],
                  handedness=[[NS(category_name="Right", score=0.95)]],
                  hand_world_landmarks=[[NS(x=float(a), y=float(b), z=float(c)) for a, b, c in world]] if world is not None else [])

    o = observe(fake_result(world_hand(10, 5)), 0, ASPECT)
    check("observe() reads the palm's orientation from the world landmarks", o.facing and abs(o.yaw - 10) < 3,
          (o.yaw, o.pitch))
    try:
        o = observe(fake_result(None), 0, ASPECT)
        check("observe() without world landmarks: orientation unknown (never wakes), no crash",
              o.yaw is None and not o.facing and 0.0 <= o.openness <= 1.0, (o.yaw, o.openness))
    except Exception as err:  # noqa: BLE001
        check("observe() without world landmarks: orientation unknown (never wakes), no crash", False, repr(err))

print()
print(f"{len(failures)} failure(s)" if failures else "all gesture tests passed")
sys.exit(1 if failures else 0)
