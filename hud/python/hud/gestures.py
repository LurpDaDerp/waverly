"""Gesture interpretation, independent of the camera so it can be unit tested.

Coordinates are normalised to the *mirrored* camera image (0..1), so x grows
toward the user's right and y grows downward, like looking in a mirror.

Scrolling follows the hand:
  * Moving the hand scrolls the list the same way: up scrolls up, down scrolls
    down, left scrolls left, right scrolls right. One comfortable stroke (about
    half the camera's view) covers the whole list.
  * Only deliberate movement counts. Hand speed is measured continuously; very
    slow drift and jitter (below MOVE_MIN) and very fast whips (above MOVE_MAX,
    such as snapping the hand back for another stroke) are ignored.
  * The first clear direction of a stroke locks its axis, so a vertical scroll
    never leaks into the weather timeline; a clear turn to the other axis
    switches it. Vertical strokes move the left list with the left hand and the
    right list with the right; sideways strokes move the weather timeline.
  * A hand that disappears (fast motion blur) and reappears elsewhere never
    causes a jump: movement is only counted between detections close in time.

Wake is forgiving (fist, then open hand; or a wave: one sweep of the open hand
across the camera's view), but only for a real hand
showing its palm: every wake candidate gets a confidence from the frames of its
gesture (how much each detection looks like a hand) and opens the HUD only above
WAKE_CONFIDENCE, and only while the palm faces the camera (within FACING_YAW left /
right and FACING_PITCH up / down), so a hand scratching the head (edge-on to the
camera) or the back of a hand never wakes it.
A fist often starts with its back to the camera and turns round as it opens; mid-turn,
edge-on, the hand model loses it for a moment. An armed fist that was clearly a real
hand survives that (WAKE_DROPOUT), and while it could still complete, the engine keeps
the camera at full rate (wake_pending), so the first try wakes. The open hand must
then look like a hand on its own (its last frames' evidence, not only the average
since the fist), so a real fist cannot vouch for a phantom palm on a face.
Close is strict: a fully open palm facing the camera, held steady, then a clear
fist held steady.

Each wake gesture and the close gesture can be turned off (Settings › Controls:
config.json gesture_open_wave, gesture_open_fist, gesture_close_fist; see
GestureEngine.configure). A gesture that is off never fires, nor does its prewake;
scrolling is always on.
"""
from __future__ import annotations

import math
from collections import deque, namedtuple
from dataclasses import dataclass, field

FIST, PALM, OTHER = "fist", "palm", "other"


@dataclass
class HandObs:
    x: float
    y: float
    size: float
    shape: str
    side_hint: float       # +1 strongly right hand, -1 strongly left hand
    strict: bool = False   # PALM: fully open and facing the camera. FIST: a clear fist.
    openness: float = 1.0  # 0 = fist, 1 = every finger straight
    evidence: float = 1.0  # how much the detection looks like a real hand (handfeatures.hand_evidence)
    label: int = 0         # the model's own handedness (+1 right, -1 left, 0 unknown), uncorrected; logged only
    parts: dict | None = None  # the factors behind evidence, for the wake log
    yaw: float | None = None    # degrees the palm is turned left / right of facing the camera (None: unknown)
    pitch: float | None = None  # degrees the palm is turned up / down (handfeatures.palm_orientation)

    @property
    def facing(self) -> bool:
        return palm_facing(self.yaw, self.pitch)


def palm_facing(yaw: float | None, pitch: float | None) -> bool:
    """The palm faces the camera: within FACING_YAW left / right and FACING_PITCH up /
    down. The back of the hand (|yaw| near 180) and an edge-on hand (near 90) do not;
    an unknown orientation does not either."""
    return yaw is not None and pitch is not None and abs(yaw) <= FACING_YAW and abs(pitch) <= FACING_PITCH  # (NaN: False)


# One frame of the hand watched for wake gestures (asleep): its time, hand evidence, the
# model's handedness label (+1 / -1, 0 unknown), the evidence's factors, the palm's
# orientation (yaw, pitch; computed with that frame's own label) and whether it was a fist.
Seen = namedtuple("Seen", "t evidence label parts yaw pitch fist")


class OneEuro:
    def __init__(self, mincutoff=1.8, beta=12.0, dcutoff=1.0):
        self.mincutoff, self.beta, self.dcutoff = mincutoff, beta, dcutoff
        self.x = None
        self.dx = 0.0
        self.t = None

    def reset(self):
        self.x = None
        self.dx = 0.0

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x, t):
        if self.x is None:
            self.x, self.t = x, t
            return x
        dt = max(t - self.t, 1e-3)
        self.t = t
        dx = (x - self.x) / dt
        a_d = self._alpha(self.dcutoff, dt)
        self.dx = a_d * dx + (1 - a_d) * self.dx
        cutoff = self.mincutoff + self.beta * abs(self.dx)
        a = self._alpha(cutoff, dt)
        self.x = a * x + (1 - a) * self.x
        return self.x


@dataclass
class Segment:
    shape: str
    start: float
    end: float
    x1: float
    y1: float
    path: float = 0.0   # raw distance travelled (frame units)
    n: int = 0          # frames
    ns: int = 0         # frames that met the strict test

    @property
    def mean_speed(self) -> float:
        return self.path / max(self.end - self.start, 1e-3)

    @property
    def strict_share(self) -> float:
        return self.ns / max(self.n, 1)


@dataclass
class Track:
    id: int
    x: float
    y: float
    size: float
    first_seen: float
    last_seen: float
    side_score: float = 0.0
    fx: OneEuro = field(default_factory=OneEuro)
    fy: OneEuro = field(default_factory=OneEuro)
    hist: deque = field(default_factory=lambda: deque(maxlen=12))  # raw (t, x, y)
    # shape debouncing
    cand: str = OTHER
    cand_since: float = 0.0
    cand_n: int = 0
    cand_ns: int = 0
    stable: str | None = None
    segments: list = field(default_factory=list)
    fired_sleep_for: float = -1.0
    # wave-to-wake: one sweep of the hand across the view
    wave_dir: int = 0           # direction of the current sweep (+1 right, -1 left, 0 not moving yet)
    wave_run: deque = field(default_factory=deque)  # (t, x, y) of the current sweep, oldest first
    wave_ext: tuple = (0.0, 0.0, 0.0)               # (t, x, y) where it got furthest
    # scrolling
    px: float | None = None     # previous filtered position used for deltas
    py: float = 0.0
    pt: float = 0.0
    vx: float = 0.0             # smoothed velocity (frame units / s)
    vy: float = 0.0
    axis: str | None = None
    target: str | None = None
    ax: float = 0.0             # displacement gathered before the axis is chosen
    ay: float = 0.0
    perp: float = 0.0           # recent movement across the locked axis
    along: float = 0.0          # recent movement along the locked axis
    quiet_since: float | None = None
    last_move: float = -1e9
    pending: list = field(default_factory=list)  # one frame of movement held back
    open: float = 1.0           # smoothed openness
    arrived: bool = False       # past the arrival window
    open_high_at: float = -1e9  # last time the hand was over 95% open
    closed_frames: int = 0      # (unused)
    fist_since: float | None = None  # when the closing fist reached 0%
    whip_until: float = -1e9
    rx: float = 0.0             # recent signed movement (for axis switches)
    ry: float = 0.0
    # close gesture: the steady, fully open, camera-facing palm right before the fist
    palm_hold_since: float | None = None
    palm_hold_start: float = -1e9
    palm_hold_end: float = -1e9

    @property
    def side(self) -> str:
        return "R" if self.side_score >= 0 else "L"


HOLD = {FIST: 0.07, PALM: 0.07, OTHER: 0.14}
STILL = 0.75         # frame units / s: slower counts as holding still
FIST_STILL = 2.0     # a wake fist may still be rising into view (fast waving wakes anyway)
LOST_AFTER = 0.25    # s without a detection before a hand is dropped

MOVE_MIN = 0.08      # frame units / s: slower is drift or jitter, ignored
MOVE_MAX = 3.2       # (unused: there is no upper speed limit on scrolling)
MAX_GAP = 0.12       # s: movement across a longer detection gap is not counted
AXIS_LOCK = 0.06     # frame units of movement before a stroke's axis is chosen (decisive, not drift)
AXIS_RATIO = 1.5      # vertical strokes: within ~34 degrees of vertical; diagonals are ignored
AXIS_RATIO_X = 1.5    # sideways strokes: within ~34 degrees (sideways sweeps arc from the elbow)
ASPECT = 640 / 480    # camera width / height: x and y are fractions of different lengths
ARRIVAL = 0.35        # s after a hand appears during which up/down movement is the arm
                      # rising into view, not a scroll (sideways swipes count at once)
STROKE_END = 0.28    # s of no qualifying movement that ends a stroke
SCROLL_OPEN = 0.92   # the hand must be at least 92% open to scroll

SWEEP_DIST = 0.40    # wave: one sweep of the open hand across the camera's view, at least this far sideways
                     # (frame widths; the hand model finds a hand from ~0.1 to ~0.9 of the width)...
SWEEP_TIME = 1.2     # ...within this many seconds (slower is the hand drifting, not a wave)...
SWEEP_SLOPE = 1.0    # ...and no more up / down than sideways (within 45 degrees of horizontal, in pixels)
SWEEP_BACK = 0.04    # frame units the hand may move back without ending the sweep (jitter); more turns it
WAVE_GAP = 0.6       # s a sweeping hand may blur out of detection without starting again

WAKE_FIST = 0.20          # wake: a fist (20% open or less)...
WAKE_FIST_HOLD = 0.0      # ...no hold: a single fist frame arms it...
WAKE_OPEN = 0.95          # ...then opened to 95% or more...
WAKE_WITHIN = 1.5         # ...within this many seconds of the fist (for a fist that armed and was clearly a
                          # real hand, time out of detection - gaps over WAKE_GAP, up to WAKE_DROPOUT - does not count)
WAKE_GAP = 0.5            # s: the hand may drop out of detection this long between the fist and the open hand
                          # (a fist not yet armed, or not clearly a real hand, starts again after a longer gap)
WAKE_DROPOUT = 2.0        # s in all an armed fist that was clearly a real hand (its prewake accepted) may be lost
                          # from detection before the hand opens. A fist shown back to the camera turns round as
                          # it opens, and the hand model loses it edge-on: in real-use logs (MacBook Air camera,
                          # Nov 2026) 8 of 9 such fists missed the wake, the hand lost for 0.6-1.6 s (up to 3.4 s);
                          # fists shown palm side first woke on the first try 83 times in 87.
WAKE_PENDING_FIST = 3.0   # s: a fist held longer than this is resting (a chin on it), not a wake under way:
                          # wake_pending (full-rate frames) no longer holds the camera for it
WAKE_AFTER_CLOSE = 1.2    # s after a close gesture before a wake gesture counts
WAKE_UNBLOCK = 0.5        # the fist that closed the HUD counts as released once the hand is this open
CLOSE_FROM = 0.95         # close: from 95% open or more...
CLOSE_TO = 0.05           # ...to 5% open or less (a full fist: real fists read 0-3%; a hand curled
                          # two-thirds to three-quarters of the way reads 6-12%, and must not close)...
CLOSE_WITHIN = 1.5        # ...within this many seconds...
CLOSE_HOLD = 0.0          # no hold: closes once the fist reads two frames in a row
CLOSE_PALM_MIN = 0.30     # s the open palm must be held
CLOSE_PALM_SHARE = 0.7    # share of those frames that must be fully open and facing
CLOSE_FIST_MIN = 0.25     # s the fist must be held
PALM_STEADY = 0.3         # frame units / s over 150 ms: steadier counts as a held palm

# Wake confidence. A wake gesture (and the prewake that wakes the display) only fires
# for a real hand: its confidence is the mean hand evidence (handfeatures.hand_evidence)
# of the gesture's frames, and enough of those frames must look like a hand. Phantom
# hands (MediaPipe firing on a face that leans toward the camera) score ~0.1 and come
# in bursts of a few frames; real gestures on the calibration clips score 0.85-0.95.
# (Handedness flips are logged but not scored: an edge-on waving hand flips as often
# as a phantom does, down to 60% agreement within a wave.)
WAKE_CONFIDENCE = 0.6     # wake only at this confidence or more
GOOD_FRAME = 0.5          # evidence for a frame to count as a good hand frame (and the average the open
                          # hand's last FIST_FACING_LAST frames need for a fist -> open wake)
SWEEP_MIN_FRAMES = 4      # good frames a wave (one sweep) needs (the engine gets 10-16 fps with a hand in view)
FIST_MIN_FRAMES = 4       # good frames from the start of the fist to the open hand
PREWAKE_MIN_FRAMES = 3    # good frames before a prewake
NOTE_EVERY = 2.0          # s between log notes about rejected candidates of one kind

# Palm orientation. A wake only counts with the palm facing the camera: within FACING_YAW
# degrees left / right and FACING_PITCH up / down (handfeatures.palm_orientation). A wave
# (one sweep across the view) must show the palm on SWEEP_FACING_SHARE of its frames; fist ->
# open must end on a facing open hand (the fist itself is exempt: a fist shows no palm). A
# palm held flat to the screen reads up to ~30 degrees of yaw near the frame's left and right
# edges (it is seen from the side there), so a sweep is not asked to face on every frame. A
# hand swept sideways palm-down or edge-on faces on 4-13% of its frames (measured on
# calibration/waving.mov); a hand scratching the head, edge-on, ~0.
# Check changes at the app's frame rate too (tools/replay_video.py --fps 12): the engine
# sees 10-16 fps with a hand in view, and frame counts mean more time there.
FACING_YAW = 30.0         # degrees left / right
FACING_PITCH = 45.0       # degrees up / down
SWEEP_FACING_SHARE = 0.5  # share of a wave's frames with the palm facing
FIST_FACING_LAST = 3      # fist -> open: the open hand's last 3 frames (fist frames before them do not
                          # count) face the camera, so one noisy frame right after the fist cannot wake
FIST_AWAY_MAX = 0.35      # fist -> open: s in all the open hand may be turned away (|yaw| > FACING_YAW) since
                          # the fist, so a hand held open sideways or back-on that comes round to the camera
                          # for its last frames (moving into frame) cannot wake, while one that opens edge-on
                          # and turns at once still does (~0.2 s). Real-use logs (Nov 2026): real wakes |yaw|
                          # median 2-28; the false one 62 (palm facing 3 of 14 open frames, its last 3: ~0.5 s away)


# The gestures that can be turned off: GestureEngine attribute -> config.json key.
GESTURE_SETTINGS = {"open_wave": "gesture_open_wave", "open_fist": "gesture_open_fist",
                    "close_fist": "gesture_close_fist"}


class GestureEngine:
    def __init__(self):
        # which gestures are on (configure); scrolling always is
        self.open_wave = True     # wake by waving
        self.open_fist = True     # wake by a fist, then an open hand
        self.close_fist = True    # close by an open palm, then a fist
        self.tracks: list[Track] = []
        self._next_id = 1
        self.last_wake = -1e9
        self.last_sleep = -1e9
        # wave-to-wake is tracked per engine, not per track: a fast wave blurs the
        # hand out of detection now and then, which can split it into new tracks
        self.wave = Track(0, 0.0, 0.0, 0.0, 0.0, -1e9)
        self.departed = []  # (time, x, y, side_score) of hands that just left the view
        # fist-to-open wake, tracked per engine (robust to the hand's track splitting)
        self.wf_since = None      # when the current fist began
        self.wf_last = -1e9       # last frame the hand was a fist
        self.wf_ok = False        # a fist was held long enough
        self.wf_start = 0.0       # when the fist that armed the wake began
        self.wf_seen = -1e9       # last frame a hand was seen while asleep
        self.wf_prewoke = False   # the armed fist already sent its prewake
        self.wf_block = False     # the fist that closed the HUD: no wake until the hand opens or leaves
        self.wf_peak = 0.0        # the most open the hand got since the armed fist (for the log)
        self.wf_lost = 0.0        # s the hand was out of detection (gaps over WAKE_GAP) since the last fist frame
        self.wf_lost_all = 0.0    # s it was out of detection since the fist armed (at most WAKE_DROPOUT)
        self.wf_dropped = False   # the hand of the armed fist dropped out of detection since the fist armed
        self.seen = deque(maxlen=150)  # Seen frames of the hand watched for wake gestures (5 s at 30 fps)
        self.notes: list[str] = []    # log lines about wake decisions; the caller drains them
        self._noted = {}              # (what, gesture) -> (time of the last rejection note, rejections since)

    def configure(self, cfg: dict) -> list[str]:
        """Turn gestures on or off from a merged config (common.merge_config). A gesture
        turned off forgets what it had gathered, so turning it back on starts afresh.
        Returns the names of the settings that changed."""
        changed = []
        for attr, key in GESTURE_SETTINGS.items():
            on = cfg.get(key, True) is not False
            if on != getattr(self, attr):
                setattr(self, attr, on)
                changed.append(attr)
        if not self.open_wave:
            # (last_seen too: turned back on, the wave starts from where the hand is then)
            self.wave.wave_run.clear()
            self.wave.wave_dir, self.wave.last_seen = 0, -1e9
        if not self.open_fist:
            self.wf_since, self.wf_ok, self.wf_prewoke = None, False, False
        if not self.close_fist:
            for tr in self.tracks:  # a fist half-way through its hold must not close on turning back on
                tr.fist_since, tr.open_high_at = None, -1e9
        return changed

    @property
    def can_wake(self) -> bool:
        """Whether any wake gesture is on (otherwise only the keyboard or menu opens the HUD)."""
        return self.open_wave or self.open_fist

    # ------------------------------------------------------------------ tracks
    def _match(self, t: float, obs: list[HandObs]):
        pairs = []
        free = list(self.tracks)
        for o in sorted(obs, key=lambda o: -o.size):
            best, bd = None, None
            for tr in free:
                # compare with where the hand should be now: its last raw detection
                # moved on by its velocity (the smoothed position lags fast motion)
                gap = min(t - tr.last_seen, 0.3)
                lx, ly = (tr.hist[-1][1], tr.hist[-1][2]) if tr.hist else (tr.x, tr.y)
                d = math.hypot(lx + tr.vx * gap - o.x, ly + tr.vy * gap - o.y)
                if d < 0.25 + 2.5 * gap and (bd is None or d < bd):
                    best, bd = tr, d
            if best is None:
                # Did a hand just vanish near here? Then this is probably the same hand
                # torn away by a fast snap: ignore its first moments. A hand simply
                # entering the frame starts scrolling at once.
                torn = any(t - tr.last_seen < 0.3 and math.hypot(tr.x - o.x, tr.y - o.y) < 0.5 for tr in free)
                best = Track(self._next_id, o.x, o.y, o.size, t, t, cand_since=t)
                best.side_score = o.side_hint
                # The same hand coming back into view (e.g. after going past the
                # bottom edge while scrolling) is not a new arrival: it scrolls at once.
                back = [d for d in self.departed if t - d[0] < 1.5 and math.hypot(d[1] - o.x, d[2] - o.y) < 0.6]
                if back:
                    best.arrived = True
                    best.side_score = back[-1][3]
                del torn  # (snaps are no longer filtered out)
                self._next_id += 1
                self.tracks.append(best)
            else:
                free.remove(best)
            pairs.append((best, o))
        seen = {tr.id for tr, _ in pairs}
        lost = [tr for tr in self.tracks if tr.id not in seen and t - tr.last_seen >= LOST_AFTER]
        self.tracks = [tr for tr in self.tracks if tr not in lost]
        self.departed = [d for d in self.departed if t - d[0] < 1.5]
        self.departed += [(tr.last_seen, tr.x, tr.y, tr.side_score) for tr in lost]
        return pairs, lost

    # ------------------------------------------------------------------ shapes
    @staticmethod
    def _speed(tr: Track, window=0.2) -> float:
        h = list(tr.hist)
        if len(h) < 2:
            return 0.0
        t1 = h[-1][0]
        path, start = 0.0, t1
        for a, b in zip(reversed(h[:-1]), reversed(h[1:])):
            if t1 - a[0] > window:
                break
            path += math.hypot(b[1] - a[1], b[2] - a[2])
            start = a[0]
        return path / (t1 - start) if t1 > start else 0.0

    def _shape(self, tr: Track, o: HandObs, t: float, step: float) -> bool:
        if o.shape != tr.cand:
            tr.cand, tr.cand_since, tr.cand_n, tr.cand_ns = o.shape, t, 0, 0
        tr.cand_n += 1
        tr.cand_ns += int(o.strict)
        if tr.cand == tr.stable and tr.segments:
            s = tr.segments[-1]
            s.end, s.x1, s.y1 = t, tr.x, tr.y
            s.path += step
            s.n += 1
            s.ns += int(o.strict)
            return False
        if tr.cand != tr.stable and t - tr.cand_since >= HOLD[tr.cand]:
            if tr.segments:
                tr.segments[-1].end = tr.cand_since
            held = t - tr.cand_since
            tr.segments.append(Segment(tr.cand, tr.cand_since, t, tr.x, tr.y,
                                       path=self._speed(tr, held) * held, n=tr.cand_n, ns=tr.cand_ns))
            tr.segments = tr.segments[-6:]
            tr.stable = tr.cand
            return True
        return False

    @staticmethod
    def _recent(tr: Track, shape: str, within: float, now_start: float, min_len: float):
        for s in reversed(tr.segments[:-1]):
            if now_start - s.end > within:
                return None
            if s.shape == shape and s.end - s.start >= min_len:
                return s
        return None

    # ------------------------------------------------------------------ update
    def update(self, t: float, obs: list[HandObs], awake: bool, scroll_enabled: bool):
        """Feed one frame. Returns (events, messages).

        events: "prewake" (a fist appeared while asleep: start powering the
        monitor), "wake", "sleep". messages: scroll dicts for the UI.
        """
        events, msgs = [], []
        if not awake and self.open_fist:
            self._fist_expire(t)  # an armed fist whose hand stays lost: note the miss now, not when it comes back
        pairs, lost = self._match(t, obs)
        for tr in lost:
            self._end_stroke(tr, msgs, flush=False)
        for tr, o in pairs:
            gap = t - tr.last_seen
            tr.last_seen = t
            step = math.hypot(o.x - tr.hist[-1][1], o.y - tr.hist[-1][2]) if tr.hist else 0.0
            tr.hist.append((t, o.x, o.y))
            if gap > MAX_GAP:  # reappeared after a gap: restart smoothing, never jump
                tr.fx.reset()
                tr.fy.reset()
                tr.px = None
                tr.pending = []  # the frame before vanishing may be a whip's start
                tr.palm_hold_since = None
            tr.x, tr.y = tr.fx(o.x, t), tr.fy(o.y, t)
            tr.size = o.size if tr.size <= 0 else tr.size + 0.25 * (o.size - tr.size)
            tr.side_score += 0.3 * (o.side_hint - tr.side_score)
            changed = self._shape(tr, o, t, step)
            cur = tr.segments[-1] if tr.segments else None
            self._palm_hold(tr, o, t)

            if not awake:
                if o is max(obs, key=lambda q: q.size):
                    self.seen.append(Seen(t, o.evidence, o.label, o.parts, o.yaw, o.pitch,
                                          o.openness <= WAKE_FIST or o.shape == FIST))
                    # Wake by waving: one sweep of the open hand across the view, palm to the camera.
                    # (No prewake: the sweep is over in well under a second, and the wake itself
                    # wakes the display.)
                    w = self.wave
                    if self.open_wave:
                        since = self._sweep(w, o, t, t - w.last_seen)
                        w.last_seen = t
                        if (since is not None and t - self.last_sleep > WAKE_AFTER_CLOSE and t - self.last_wake > 2
                                and self._sure("wave", "wake", since, t, SWEEP_MIN_FRAMES, SWEEP_FACING_SHARE)):
                            events.append("wake")
                            self.last_wake = t
                            w.wave_run.clear()
                            w.wave_dir = 0
                    # Wake: a fist held 0.1 s, then the hand opens to 95% within 1.5 s.
                    if self.open_fist:
                        self._fist_wake(o, t, events)
            elif self.close_fist and self._close_gesture(tr, o, t):
                events.append("sleep")
                self.last_sleep = t
                # the closing fist must not count as the fist of a wake gesture
                self.wf_block, self.wf_since, self.wf_ok, self.wf_seen = True, None, False, t

            if awake and scroll_enabled:
                self._scroll(tr, o, t, msgs)
            else:
                tr.axis, tr.px, tr.vx, tr.vy = None, None, 0.0, 0.0
        return events, msgs

    @staticmethod
    def _sweep(tr: Track, o: HandObs, t: float, gap: float) -> float | None:
        """Follow the hand's current one-way sideways sweep (raw positions). Returns when
        it began once it has gone SWEEP_DIST sideways within SWEEP_TIME (and no more up /
        down than SWEEP_SLOPE allows), else None. A fist, or the hand lost for over
        WAVE_GAP, starts again; moving back over SWEEP_BACK starts a sweep the other way
        from the turn; a sweep keeps only its last SWEEP_TIME, so slow drift never adds up."""
        run, p = tr.wave_run, (t, o.x, o.y)
        if o.shape == FIST or o.openness <= WAKE_FIST:
            run.clear()  # a fist is the other wake gesture, not a wave
            tr.wave_dir = 0
            return None
        if gap > WAVE_GAP:
            run.clear()  # lost too long: start again from here
            tr.wave_dir = 0
        if tr.wave_dir == 0:
            run.append(p)  # not moving yet: a sweep starts from the oldest point (at most SWEEP_TIME back)
            if abs(o.x - run[0][1]) > SWEEP_BACK:
                tr.wave_dir = 1 if o.x > run[0][1] else -1
                tr.wave_ext = p
        elif (o.x - tr.wave_ext[1]) * tr.wave_dir >= 0:
            tr.wave_ext = p
            run.append(p)
        elif abs(o.x - tr.wave_ext[1]) > SWEEP_BACK:  # turned back: a sweep the other way, from the turn
            run.clear()
            run.extend((tr.wave_ext, p))
            tr.wave_dir, tr.wave_ext = -tr.wave_dir, p
        else:
            run.append(p)  # a little back (jitter): still the same sweep
        while len(run) > 1 and t - run[0][0] > SWEEP_TIME:
            run.popleft()
        if not tr.wave_dir:
            return None
        t0, x0, y0 = run[0]
        dx, dy = abs(tr.wave_ext[1] - x0), abs(tr.wave_ext[2] - y0)
        if dx >= SWEEP_DIST and dy <= dx * ASPECT * SWEEP_SLOPE:
            return t0
        return None

    def _palm_hold(self, tr: Track, o: HandObs, t: float):
        """Track the unbroken stretch of a steady, fully open, camera-facing palm."""
        steady = o.shape == PALM and o.strict and self._speed(tr, 0.15) < PALM_STEADY
        if steady:
            if tr.palm_hold_since is None:
                tr.palm_hold_since = t
            tr.palm_hold_start, tr.palm_hold_end = tr.palm_hold_since, t
        else:
            tr.palm_hold_since = None

    def _wf_missed(self, why: str, t: float):
        """Log an armed fist (held long enough) that ended without a wake, and why."""
        if self.wf_ok:
            self.notes.append(f"wake by fist missed: {why}; after the fist the hand opened to at most "
                              f"{self.wf_peak:.0%} (needs {WAKE_OPEN:.0%})"
                              + ("" if self.wf_peak < WAKE_OPEN else " but the open hand was not accepted (see above)"))

    def _armed_real(self) -> bool:
        """An armed fist that was clearly a real hand (its prewake was accepted)."""
        return self.wf_ok and self.wf_prewoke and not self.wf_block

    def _dropout_ok(self, gap: float) -> bool:
        """Whether the armed fist survives the hand being out of detection for `gap` s."""
        return self._armed_real() and self.wf_lost_all + gap <= WAKE_DROPOUT

    def wake_pending(self, t: float) -> bool:
        """Whether a fist -> open wake is under way and could still complete at `t`: an armed
        fist that was clearly a real hand, held no longer than WAKE_PENDING_FIST, whose open
        hand may still come (within WAKE_WITHIN of the fist, the hand perhaps out of detection
        for up to WAKE_DROPOUT meanwhile). While it is, the engine keeps full-rate frames
        (camera-want), so the camera cannot drop to its low-power mode mid-gesture."""
        if not (self.open_fist and self._armed_real()) or self.wf_last - self.wf_start > WAKE_PENDING_FIST:
            return False
        window_open = self.wf_seen - self.wf_last - self.wf_lost <= WAKE_WITHIN  # as of the last frame of the hand
        if t - self.wf_last - self.wf_lost <= WAKE_WITHIN:
            return True  # (seen or not, the open hand may still come in time)
        return window_open and self._dropout_ok(t - self.wf_seen)

    def _open_frames_real(self, t: float) -> bool:
        """The open hand itself looks like a real hand: its last FIST_FACING_LAST frames
        average evidence >= GOOD_FRAME. The wake confidence is an average since the fist, so
        without this a real fist's frames could vouch for a phantom "open palm" (a face,
        ~0.1) seen after the hand was lost for a moment. An average, not each frame: a real
        hand dips just under GOOD_FRAME now and then (0.47 on calibration/waving.mov).
        A rejection is noted like the others (at most every NOTE_EVERY s)."""
        tail = [f.evidence for f in self._frames(self.wf_start, t) if not f.fist][-FIST_FACING_LAST:]
        if not tail or sum(tail) / len(tail) >= GOOD_FRAME:
            return True
        key = ("wake-open", "fist")
        if t - self._noted.get(key, (-1e9, 0))[0] >= NOTE_EVERY:
            self._noted[key] = (t, 0)
            self.notes.append("wake by fist rejected: the open hand does not look like a hand (evidence of its last "
                              f"frames {', '.join(f'{v:.2f}' for v in tail)}; the average needs {GOOD_FRAME:.2f})")
        return False

    def _fist_expire(self, t: float):
        """An armed fist whose hand has been out of detection too long can no longer wake:
        note the miss and forget it now (so the log tells when it happened)."""
        gap = t - self.wf_seen
        if self.wf_ok and gap > WAKE_GAP and not self._dropout_ok(gap):
            self._wf_missed(f"the hand left view for {gap:.1f}s"
                            + (f" ({self.wf_lost_all + gap:.1f}s in all, more than the {WAKE_DROPOUT:.1f}s an armed "
                               f"fist may be)" if self._armed_real() else ""), t)
            self.wf_since, self.wf_ok = None, False

    def _fist_wake(self, o: HandObs, t: float, events):
        gap = t - self.wf_seen
        if gap > WAKE_GAP and self.wf_ok and self._dropout_ok(gap):
            # an armed real fist lost for a moment (turning round as it opens, edge-on): it
            # still counts, and the time the hand was not seen does not use up WAKE_WITHIN
            self.wf_lost += gap
            self.wf_lost_all += gap
            self.wf_dropped = True
            self.notes.append(f"wake by fist: the hand was out of view for {gap:.1f}s after the fist "
                              f"({self.wf_lost_all:.1f}s of {WAKE_DROPOUT:.1f}s allowed); still armed")
        elif gap > WAKE_GAP:
            # the hand dropped out of view: the fist must be held, and opened, in one go
            # (and a fist seen after that is a new one, not the one that closed the HUD)
            self._wf_missed(f"the hand left view for {gap:.1f}s", t)
            self.wf_since, self.wf_ok, self.wf_block = None, False, False
        self.wf_seen = t
        # a fist by the 3D openness, or by the recognizer (more reliable when the
        # fist is moving into view and blurred)
        if o.openness <= WAKE_FIST or o.shape == FIST:
            if self.wf_block:
                return  # still the fist that closed the HUD
            if self.wf_since is None:
                self.wf_since = t
            if t - self.wf_since >= WAKE_FIST_HOLD and (
                    not self.wf_ok or (self.wf_dropped and self.wf_start != self.wf_since)):
                # a fist held WAKE_FIST_HOLD arms the wake. A hand that comes back as a fist after
                # being lost re-arms it from this fist: the same gesture, so no second prewake, and
                # WAKE_DROPOUT stays a total. A fist that only loosens for a frame while in view
                # does not re-arm (else a resting fist that reads loose now and then would never
                # reach WAKE_PENDING_FIST and would hold the camera at full rate indefinitely).
                again = self.wf_ok and self.wf_prewoke
                self.wf_ok, self.wf_start, self.wf_prewoke = True, self.wf_since, again
                self.wf_peak, self.wf_dropped = o.openness, False
                if not again:
                    self.wf_lost_all = 0.0
            if self.wf_ok and not self.wf_prewoke and self._sure("fist", "prewake", self.wf_start, t, PREWAKE_MIN_FRAMES):
                self.wf_prewoke = True
                events.append("prewake")  # start powering the display now; it takes ~2 s
            self.wf_last, self.wf_lost = t, 0.0
            return
        if o.openness >= WAKE_UNBLOCK:
            self.wf_block = False  # (one noisy frame just above WAKE_FIST does not release it)
        self.wf_since = None
        if self.wf_ok:
            self.wf_peak = max(self.wf_peak, o.openness)
        if self.wf_ok and t - self.wf_last - self.wf_lost > WAKE_WITHIN:
            self._wf_missed(f"not opened within {WAKE_WITHIN:.1f}s", t)
            self.wf_ok = False  # opened too late
        if (self.wf_ok and o.openness >= WAKE_OPEN and t - self.last_sleep > WAKE_AFTER_CLOSE
                and self._open_frames_real(t)
                and self._sure("fist", "wake", self.wf_start, t, FIST_MIN_FRAMES, 0.0, FIST_FACING_LAST,
                               away_max=FIST_AWAY_MAX)):
            self.wf_ok = False
            events.append("wake")
            self.last_wake = t

    # ------------------------------------------------------------------ wake confidence
    def wake_confidence(self, since: float, t: float):
        """Confidence (0..1) that the frames from since to t show a real hand making a
        gesture. Returns (confidence, good frames, frames, breakdown of the evidence)."""
        frames = self._frames(since, t)
        if not frames:
            return 0.0, 0, 0, "no frames"
        conf = sum(f.evidence for f in frames) / len(frames)
        good = sum(f.evidence >= GOOD_FRAME for f in frames)
        parts = [f.parts for f in frames if f.parts]
        detail = ", ".join(f"{k} {sum(p[k] for p in parts) / len(parts):.2f}" for k in parts[0]) if parts else ""
        labels = [f.label for f in frames if f.label]
        if labels:
            detail += (", " if detail else "") + f"same hand {max(labels.count(1), labels.count(-1)) / len(labels):.0%}"
        return conf, good, len(frames), detail

    def _frames(self, since: float, t: float) -> list:
        return [f for f in self.seen if since - 1e-6 <= f.t <= t + 1e-6]

    @staticmethod
    def palm_angles(frames) -> list:
        """(yaw, pitch) of each frame, (None, None) where unknown. Every frame is read
        with the gesture's majority handedness label: a frame whose label flipped (common
        for a blurred or edge-on hand) has its palm normal flipped too, which would turn
        the back of the hand into a facing palm and the reverse."""
        labels = [f.label for f in frames if f.label]
        major = (1 if labels.count(1) >= labels.count(-1) else -1) if labels else 0
        out = []
        for f in frames:
            yaw, pitch = f.yaw, f.pitch
            if yaw is None or pitch is None or not (math.isfinite(yaw) and math.isfinite(pitch)):
                yaw = pitch = None  # unknown (never facing)
            elif major and f.label and f.label != major:
                yaw, pitch = (yaw + 360.0) % 360.0 - 180.0, -pitch  # the opposite normal
            out.append((yaw, pitch))
        return out

    def palm_check(self, since: float, t: float, share: float, last: int, cycles=(), away_max=None):
        """Whether the palm faces the camera enough over the frames from since to t: on at
        least `share` of the frames that are not fists, on each of the last `last` frames that
        are not fists (the newest frame must be one of them: a fist shows no palm), at least
        once in each of `cycles` ((start, end) times: a wave's there-and-back swings) and, if
        `away_max` is given, with those frames turned away (|yaw| > FACING_YAW) for at most
        that many seconds in all (each frame counts until the next, at most MAX_GAP).
        Returns (ok, description for the log)."""
        frames = self._frames(since, t)
        if not frames:
            return False, "palm: no frames"
        angles = self.palm_angles(frames)
        open_ = [(a, f) for a, f in zip(angles, frames) if not f.fist]
        facing = sum(palm_facing(*a) for a, _ in open_)
        got = facing / len(open_) if open_ else 0.0
        # the newest frame must be an open hand, and it and the open frames before it (fist
        # frames skipped, none of them count) must face: `last` of them, so a single noisy
        # frame after a fist cannot pass for a facing open hand
        tail = open_[-last:] if last else []
        end_ok = not last or (not frames[-1].fist and len(tail) == last and all(palm_facing(*a) for a, _ in tail))
        shown = sum(any(palm_facing(*a) for a, f in open_ if c0 - 1e-6 <= f.t <= c1 + 1e-6) for c0, c1 in cycles)
        known = [a for a, _ in open_ if a[0] is not None]
        if known:
            ys = sorted(abs(a[0]) for a in known)
            ps = sorted(a[1] for a in known)
            spread = (f"|yaw| median {ys[len(ys) // 2]:.0f} (90% {ys[min(len(ys) - 1, int(0.9 * len(ys)))]:.0f}), "
                      f"pitch median {ps[len(ps) // 2]:+.0f} ({ps[0]:+.0f}..{ps[-1]:+.0f})")
        else:
            spread = "orientation unknown"
        away_ok = True
        if away_max is not None:
            away = sum(min(MAX_GAP, (frames[i + 1].t if i + 1 < len(frames) else f.t) - f.t)
                       for i, (a, f) in enumerate(zip(angles, frames))
                       if not f.fist and a[0] is not None and abs(a[0]) > FACING_YAW)
            away_ok = away <= away_max
            spread += f", turned away {away:.2f}s (needs <= {away_max:.2f}s)"
        ny, np_ = angles[-1]
        now = f"{ny:+.0f}/{np_:+.0f}" if ny is not None else "unknown"
        ok = (got >= share if open_ else share <= 0) and end_ok and shown == len(cycles) and away_ok
        if not (share or last or cycles):
            return ok, f"palm not required (a fist shows none), yaw/pitch now {now}"
        desc = (f"palm facing {facing} of {len(open_)} open frames ({got:.0%}, needs {share:.0%}), "
                + (f"shown in {shown} of {len(cycles)} wave cycles (needs all), " if cycles else "") +
                f"{spread} (facing: |yaw| <= {FACING_YAW:.0f}, |pitch| <= {FACING_PITCH:.0f}), "
                f"yaw/pitch now {now}" + (f", last {last} open frame{'s' if last > 1 else ''} "
                                          f"{'facing' if end_ok else 'NOT facing'}" if last else ""))
        return ok, desc

    def _sure(self, gesture: str, what: str, since: float, t: float, min_good: int,
              share: float = 0.0, last: int = 0, cycles=(), away_max=None) -> bool:
        """Whether a wake / prewake candidate is confident enough and shows the palm (see
        palm_check); notes the decision (accepted ones always, rejected ones at most every
        NOTE_EVERY seconds)."""
        conf, good, n, detail = self.wake_confidence(since, t)
        palm_ok, palm = self.palm_check(since, t, share, last, cycles, away_max)
        ok = conf >= WAKE_CONFIDENCE and good >= min_good and palm_ok
        key = (what, gesture)
        last_note, skipped = self._noted.get(key, (-1e9, 0))
        if not ok and t - last_note < NOTE_EVERY:
            self._noted[key] = (last_note, skipped + 1)
            return False
        more = f" (+{skipped} similar since the last note)" if skipped and not ok else ""
        self.notes.append(f"{what} by {gesture} {'accepted' if ok else 'rejected'}: confidence {conf:.2f} "
                          f"(needs {WAKE_CONFIDENCE:.2f}), {good} of {n} frames look like a hand "
                          f"(needs {min_good}) over {t - since:.2f}s; {palm}" + (f" [{detail}]" if detail else "") + more)
        if ok:
            self._noted.pop(key, None)  # the next rejection is news again
        else:
            self._noted[key] = (t, 0)
        return ok

    def _close_gesture(self, tr: Track, o: HandObs, t: float) -> bool:
        """Close: the hand goes from 95% open or more to 4% open or less (a full fist)
        within 1.5 seconds, whether or not it was scrolling, and reads as that fist on
        two frames in a row. If the fist loosens in between, nothing closes and it has
        to start again from a fully open hand."""
        if o.openness >= CLOSE_FROM:
            tr.open_high_at = t
        if o.openness <= CLOSE_TO:
            if tr.fist_since is None:
                if t - tr.open_high_at <= CLOSE_WITHIN:
                    tr.fist_since = t
            elif t - tr.fist_since >= CLOSE_HOLD and t - self.last_wake >= 1.5:
                tr.fist_since, tr.open_high_at = None, -1e9  # one close per open-then-close
                return True
        elif tr.fist_since is not None:
            tr.fist_since, tr.open_high_at = None, -1e9  # loosened during the hold: cancel
        return False

    # ------------------------------------------------------------------ scrolling
    def _end_stroke(self, tr: Track, msgs, flush: bool = True):
        if flush:
            msgs.extend(tr.pending)
        tr.pending = []
        if tr.axis is not None:
            msgs.append({"t": "scroll", "kind": "end", "target": tr.target})
        tr.axis, tr.ax, tr.ay, tr.perp, tr.along, tr.quiet_since = None, 0.0, 0.0, 0.0, 0.0, None
        tr.rx = tr.ry = 0.0

    def _scroll(self, tr: Track, o: HandObs, t: float, msgs):
        if tr.px is None:
            tr.px, tr.py, tr.pt, tr.vx, tr.vy = tr.x, tr.y, t, 0.0, 0.0
            return
        dt = t - tr.pt
        if dt <= 0:
            return
        dx, dy = tr.x - tr.px, tr.y - tr.py
        tr.px, tr.py, tr.pt = tr.x, tr.y, t
        k = 1 - math.exp(-dt / 0.035)
        tr.vx += k * (dx / dt - tr.vx)
        tr.vy += k * (dy / dt - tr.vy)
        speed = math.hypot(tr.vx, tr.vy)
        # (no upper speed limit: fast movements scroll too)
        # only an open hand scrolls (smoothed over ~70 ms so one blurry frame doesn't break a stroke)
        tr.open += (1 - math.exp(-dt / 0.07)) * (o.openness - tr.open)
        moving = (MOVE_MIN <= speed and tr.open >= SCROLL_OPEN
                  and tr.cand != FIST and tr.stable != FIST)
        if not moving:
            if tr.quiet_since is None:
                tr.quiet_since = t
            elif t - tr.quiet_since > STROKE_END:
                self._end_stroke(tr, msgs)
            return
        tr.quiet_since = None
        tr.last_move = t
        self._advance(tr, dx, dy, dt, msgs)  # sent at once: no held-back frame

    def _advance(self, tr: Track, dx, dy, dt, msgs):
        decay = math.exp(-dt / 0.2)
        tr.rx = tr.rx * decay + dx
        tr.ry = tr.ry * decay + dy
        if tr.axis is not None:
            # notice a clear turn onto the other axis
            a, p = (dx * ASPECT, dy) if tr.axis == "x" else (dy, dx * ASPECT)  # true distances
            tr.along = tr.along * decay + abs(a)
            tr.perp = tr.perp * decay + abs(p)
            # only a long, clearly perpendicular movement switches lists mid-stroke;
            # sideways wobble during a vertical stroke (or the reverse) never does
            if tr.perp > 0.1 and tr.perp > 3.0 * tr.along:
                rx, ry = tr.rx, tr.ry
                self._end_stroke(tr, msgs)
                # the turn itself counts toward the new stroke
                if tr.axis is None:
                    tr.ax, tr.ay = (rx, 0.0) if abs(rx) > abs(ry) else (0.0, ry)
                return self._lock(tr, msgs)
            d = dx if tr.axis == "x" else dy
            msgs.append({"t": "scroll", "kind": "move", "target": tr.target, "axis": tr.axis, "d": round(d, 5)})
            return
        # before a direction is chosen, small movements leak away so resting-hand
        # jitter never adds up to a stroke; real movement crosses AXIS_LOCK quickly
        leak = math.exp(-dt / 0.8)
        if tr.ax * dx * ASPECT * ASPECT + tr.ay * dy < 0:
            tr.ax = tr.ay = 0.0  # the hand turned around: judge the new stroke on its own
        tr.ax = tr.ax * leak + dx
        tr.ay = tr.ay * leak + dy
        self._lock(tr, msgs)

    def _lock(self, tr: Track, msgs):
        # compare true distances: x is a fraction of the (wider) image width
        tx = abs(tr.ax) * ASPECT
        if not tr.arrived:
            if tr.pt - tr.first_seen >= ARRIVAL:
                # arrival is over: whatever it gathered without choosing a direction
                # was the arm settling, not a stroke
                tr.arrived = True
                tr.ax = tr.ay = 0.0
                return
            if abs(tr.ay) >= tx:
                tr.ax = tr.ay = 0.0  # the arm is still arriving: drop its travel entirely
                return
        if math.hypot(tr.ax, tr.ay) < AXIS_LOCK:
            return
        if tx > AXIS_RATIO_X * abs(tr.ay):
            tr.axis, tr.target, d = "x", "weather", tr.ax
        elif abs(tr.ay) > AXIS_RATIO * tx:
            tr.axis, d = "y", tr.ay
            tr.target = "schedule" if tr.side == "L" else "deadlines"
        else:
            return
        tr.ax = tr.ay = tr.perp = tr.along = 0.0
        # the movement that chose the axis counts too
        msgs.append({"t": "scroll", "kind": "move", "target": tr.target, "axis": tr.axis, "d": round(d, 5)})
