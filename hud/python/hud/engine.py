"""hud-engine (macOS): hand gestures, presence and head tracking for the HUD.

This is the macOS counterpart of the Linux hud-vision service (hud/vision.py on
the Linux machine). The gesture logic (gestures.py), the hand measurements
(handfeatures.py) and the models are identical. What differs:

  * Frames: the macOS app owns the camera and writes frames into a shared-memory
    ring (framering.py). The app decides the cheap stage-1 gating (darkness,
    motion, Apple Vision hand detection at low frame rate); this engine only sees
    frames while something might be happening, and runs on every frame it gets.
  * Display: instead of turning a monitor on/off, the engine asks the app to show
    or hide the overlay window and waits for the app's "overlay-ready" reply
    before the wake animation starts (the Linux version waited for the monitor).
  * Camera hints: the engine tells the app when it needs full-rate frames
    ({"t": "camera-want", "active": bool}) so the app can drop to its low-power
    mode otherwise.
  * Settings: which gestures open and close the HUD, and whether it closes by itself
    when you leave or the room goes dark (config.json gesture_* / auto_close_*), apply
    live, also while the HUD is closed: config.json is checked every CONFIG_CHECK s.
    With both open gestures off, nothing runs on frames while the HUD is closed (only
    the keyboard shortcut or the menu opens it).

Messages (all JSON over the hud-core WebSocket at /vision):
  engine -> core -> page+app:
    {"t":"wake","reason":...}          page plays the wake animation
    {"t":"sleep","reason":...}         page plays the close animation, replies "slept"
    {"t":"state","awake":bool}         state sync (on hello and after closing)
    {"t":"scroll","kind":"move","target":"schedule|deadlines|weather","axis":"x|y","d":float}
    {"t":"scroll","kind":"end","target":...}
    {"t":"head","x","y","yaw","pitch"}  parallax (only while awake, and only with the parallax setting on)
    {"t":"vstat",...}                  status every 2 s
    {"t":"overlay","show":true}        app: show the overlay window, then reply overlay-ready
    {"t":"overlay","show":false}       app: hide the overlay window, then reply overlay-hidden
    {"t":"overlay","prepare":true}     app: a wake gesture has started; wake the display if asleep
    {"t":"camera-want","active":bool}  app: whether full-rate frames are needed
  app/page -> core -> engine:
    {"t":"slept"}  {"t":"hello"}  {"t":"force","awake":bool}
    {"t":"overlay-ready"}  {"t":"overlay-hidden"}  {"t":"camera","mode":"idle|active|paused"}
"""
from __future__ import annotations

import asyncio
import json
import os
import threading
import time

os.environ.setdefault("GLOG_minloglevel", "2")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import aiohttp  # noqa: E402
import mediapipe as mp  # noqa: E402

from .common import (CONFIG_FILE, GESTURE_FLAGS, STATE, ConfigError, file_stamp, load_config,  # noqa: E402
                     setup_logging, watch_parent)
from .framering import FrameReader  # noqa: E402
from .gestures import GestureEngine, HandObs  # noqa: E402
from .handfeatures import FACE_MEMORY, Models, face_boxes, observe  # noqa: E402

log = setup_logging("engine")
cv2.setNumThreads(1)

# Camera-want while the HUD is closed (battery): full-rate frames only while a hand
# is doing something. A hand that sits still (a chin resting on it, a hand-like shape
# in the background) is not a gesture; after ACTIVE_HOLD without movement the app's
# camera drops back to its low-power mode, and its stage-1 gate looks again on motion.
# A fist -> open wake under way keeps full-rate frames by itself, also while the hand
# is still or out of detection (GestureEngine.wake_pending: up to WAKE_WITHIN after the
# fist plus WAKE_DROPOUT lost from view), and so does a prewake (PREWAKE_HOLD).
ACTIVE_HOLD = 1.5       # s without a moving hand before full-rate frames stop
PREWAKE_HOLD = 4.0      # s of full-rate frames after a prewake (and no second display wake-up meanwhile)
ACTIVE_EVIDENCE = 0.3   # hands that count (phantoms on a face score ~0.1, real hands 0.85-0.95)
ACTIVE_MOVE = 0.03      # moved this far (frame units) since it was last seen moving...
ACTIVE_OPEN = 0.2       # ...or opened / closed this much
CONFIG_CHECK = 2.0      # s between checks for a changed config.json (one stat; at once after a wake)
SLEPT_GRACE = 2.0       # s the page may take beyond its close animation to answer "slept"


class EngineService:
    def __init__(self):
        self.cfg_stamp = file_stamp(CONFIG_FILE)  # before reading, so a write meanwhile is noticed
        self.cfg = load_config()
        self.cfg_checked = -1e9
        self.port = self.cfg["http_port"]         # like hud-core: a new port applies on restart
        self.frames = FrameReader(os.environ.get("HUD_FRAMES", STATE / "frames.shm"),
                                  os.environ.get("HUD_FRAMES_SOCK", STATE / "frames.sock"))
        self.engine = GestureEngine()
        self.engine.configure(self.cfg)
        self.loop: asyncio.AbstractEventLoop | None = None
        self.out: asyncio.Queue | None = None
        self.state = "asleep"  # asleep | waking | awake | sleeping
        self.awake_since = 0.0
        self.worker_beat = time.monotonic()
        self.stats = {"fps": 0.0, "dark": False, "person": False, "hands": 0, "luma": 0.0}
        self._busy = False
        self.prewake_until = 0.0
        self.last_activity = -1e9   # last hand / gesture activity (drives camera-want)
        self.still_refs = []        # (x, y, openness) of hands last seen moving (see _hand_active)
        self.want_active = None
        self.camera_mode = "idle"
        self.dark_since = None      # when the frames turned dark (None: lit, or not known yet)
        self.lit_since = -1e9       # when they last turned lit again (nobody can be seen in the dark)

    # ---- thread -> asyncio
    def emit(self, msg):
        if self.loop:
            self.loop.call_soon_threadsafe(self._put, msg)

    def _put(self, msg):
        if self.out.qsize() > 50:  # never let a stalled socket build a backlog
            try:
                self.out.get_nowait()
            except asyncio.QueueEmpty:
                pass
        self.out.put_nowait(msg)

    def request(self, what, reason=""):
        if self.loop:
            self.loop.call_soon_threadsafe(lambda: asyncio.ensure_future(self._transition(what, reason)))

    # ---- overlay (replaces the Linux monitor power control)
    async def _overlay(self, show: bool, timeout: float) -> float:
        t0 = time.monotonic()
        ev = self.overlay_ready if show else self.overlay_hidden
        ev.clear()
        self.emit({"t": "overlay", "show": show})
        try:
            await asyncio.wait_for(ev.wait(), timeout)
        except asyncio.TimeoutError:
            log.warning("app did not confirm overlay %s within %.0fs", "shown" if show else "hidden", timeout)
        return time.monotonic() - t0

    # ---- state machine (same as Linux hud-vision)
    async def _transition(self, what, reason=""):
        if what == "wake" and self.state == "sleeping":
            # woken while the HUD is still fading out: turn around instead of dropping it
            self.rewake.set()
            return
        if self._busy:
            return
        if what == "prewake":
            # A wake gesture has started: let the app wake the display early (if it slept).
            if self.state == "asleep" and time.monotonic() > self.prewake_until:
                self.prewake_until = time.monotonic() + PREWAKE_HOLD
                self.emit({"t": "overlay", "prepare": True})
            return
        if what == "wake" and self.state == "asleep":
            self._busy = True
            try:
                self.state = "waking"
                self.prewake_until = 0.0
                log.info("showing HUD (%s)", reason)
                waited = await self._overlay(True, 8.0)
                log.info("overlay ready after %.2fs", waited)
                self.state, self.awake_since = "awake", time.monotonic()
                self.cfg_checked = -1e9  # look at config.json at once on the worker's next pass
                self.emit({"t": "wake", "reason": reason})
            finally:
                self._busy = False
        elif what == "sleep" and self.state == "awake":
            self._busy = True
            try:
                self.state = "sleeping"
                log.info("closing HUD (%s)", reason)
                self.slept.clear()
                self.rewake.clear()
                self.emit({"t": "sleep", "reason": reason})
                waits = [asyncio.ensure_future(self.slept.wait()), asyncio.ensure_future(self.rewake.wait())]
                # the page answers once its close animation (Settings: up to 1.5 s) has played
                limit = max(3.0, self.cfg["close_animation_s"] + SLEPT_GRACE)
                await asyncio.wait(waits, timeout=limit, return_when=asyncio.FIRST_COMPLETED)
                for w in waits:
                    w.cancel()
                if self.rewake.is_set():
                    log.info("woken again while closing (gesture)")
                    self.state, self.awake_since = "awake", time.monotonic()
                    self.emit({"t": "wake", "reason": "gesture"})
                    return
                await self._overlay(False, 3.0)
                self.state = "asleep"
                self.emit({"t": "state", "awake": False})
                if self.rewake.is_set():  # a wake arrived in the last moments of closing
                    self.rewake.clear()
                    self.loop.call_soon(lambda: asyncio.ensure_future(self._transition("wake", "gesture")))
            finally:
                self._busy = False

    def _reload_config(self, now):
        """Pick up config.json changes (gestures, auto-close, parallax, vision tuning): one
        stat every CONFIG_CHECK s, whether the HUD is open or closed, and at once on the
        first pass after a wake. hud-core applies everything else; a broken file keeps the
        current settings."""
        if now - self.cfg_checked < CONFIG_CHECK:
            return
        self.cfg_checked = now
        st = file_stamp(CONFIG_FILE)
        if st == self.cfg_stamp:
            return
        self.cfg_stamp = st
        try:
            cfg = load_config(strict=True)
        except ConfigError as e:
            log.warning("config.json unreadable, keeping the current settings: %s", e)
            return
        if cfg["parallax"] != self.cfg["parallax"]:
            log.info("parallax %s", "on" if cfg["parallax"] else "off")
        for key in GESTURE_FLAGS:
            if cfg[key] != self.cfg[key]:
                log.info("%s %s", key, "on" if cfg[key] else "off")
        self.cfg = cfg
        self.engine.configure(cfg)

    # ---- worker (thread): one pass per frame the app sends
    def worker(self):
        m = Models()
        log.info("models loaded")
        last_person = -1e9
        last_face_run = last_pose_run = -1e9
        last_face_seen, face_x = -1e9, 0.5
        recent_faces, recent_faces_t = [], -1e9
        frames, fps_t = 0, time.monotonic()
        lut_gain = None
        while True:
            self.worker_beat = time.monotonic()
            # nothing to time while closed and idle: wake up less often
            got = self.frames.wait(0.25 if self.state != "asleep" or self.want_active else 1.0)
            now = time.monotonic()
            self._reload_config(now)
            cfg = self.cfg
            awake = self.state == "awake"
            parallax = awake and cfg["parallax"]
            if got is None:
                # no frames (app idle or camera paused): nobody counts as present
                self._presence_tick(now, last_person, awake)
                self._camera_want(now)
                continue
            _seq, frame = got
            frames += 1
            presence_period = 1 / 15 if parallax else 1 / 10  # faces drive the parallax (when it is on)

            thumb = cv2.cvtColor(cv2.resize(frame, (64, 48), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
            mean = float(thumb.mean())
            dark = mean < cfg["dark_mean"] and float(np.percentile(thumb, 99)) < cfg["dark_p99"]
            self.stats.update(dark=dark, luma=round(mean, 1))
            self._darkness(now, dark)
            hands: list[HandObs] = []
            # closed, and no gesture can open it: nothing to look for (the shortcut still opens it)
            idle = self.state == "asleep" and not self.engine.can_wake
            if not dark and not idle:
                if mean < 70:  # lift dim frames so the models see detail
                    gain = min(4.0, 95.0 / max(mean, 1.0))
                    if lut_gain is None or abs(lut_gain[0] - gain) > 0.05:
                        lut_gain = (gain, np.clip(np.arange(256) * gain, 0, 255).astype(np.uint8))
                    frame = cv2.LUT(frame, lut_gain[1])
                rgb = cv2.cvtColor(cv2.flip(frame, 1), cv2.COLOR_BGR2RGB)
                aspect = rgb.shape[1] / rgb.shape[0]
                img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

                res = m.gesture.recognize_for_video(img, m.ts("g", now))
                # Faces: a few times a second for presence and parallax, and on every frame
                # with a hand while the HUD is closed, so a phantom hand on a face leaning
                # toward the camera can be told apart (BlazeFace takes under a millisecond).
                faces = []
                if (res.hand_landmarks and not awake) or now - last_face_run >= presence_period - 0.005:
                    last_face_run = now
                    fr = m.face.detect_for_video(img, m.ts("f", now))
                    faces = face_boxes(fr, rgb.shape[1], rgb.shape[0])
                    if faces:
                        recent_faces, recent_faces_t = faces, now
                    if fr.detections:
                        det = max(fr.detections, key=lambda d: d.bounding_box.width)
                        bb = det.bounding_box
                        face_x = (bb.origin_x + bb.width / 2) / rgb.shape[1]
                        face_y = (bb.origin_y + bb.height / 2) / rgb.shape[0]
                        last_face_seen = last_person = now
                        if parallax:
                            self.emit(self._head(det, face_x, face_y, aspect))
                    elif not res.hand_landmarks and now - last_person > 0.8 and now - last_pose_run >= 0.4:
                        last_pose_run = now
                        pr = m.pose.detect_for_video(img, m.ts("p", now))
                        if pr.pose_landmarks:
                            last_person = now

                if not faces and now - recent_faces_t <= FACE_MEMORY:
                    faces = recent_faces
                face_ok = now - last_face_seen < 1.5
                for i in range(len(res.hand_landmarks)):
                    obs = observe(res, i, aspect, faces)
                    if cfg["swap_handedness"]:
                        obs.side_hint = -obs.side_hint
                    if face_ok and abs(obs.x - face_x) > 0.07:
                        obs.side_hint = 0.35 * obs.side_hint + 0.65 * (1.0 if obs.x > face_x else -1.0)
                    if all(np.hypot(o.x - obs.x, o.y - obs.y) > 0.6 * max(o.size, obs.size) for o in hands):
                        hands.append(obs)
                if hands:
                    last_person = now
                    if awake or self._hand_active(hands):
                        self.last_activity = now

            events, msgs = self.engine.update(now, hands, awake, awake and now - self.awake_since > 0.6)
            for note in self.engine.notes:  # every wake decision, so false triggers can be diagnosed
                log.info("%s", note)
            self.engine.notes.clear()
            self._trace_fist(now, hands, awake, "sleep" in events)
            if events:
                self.last_activity = now
            for ev in events:
                self.request(ev, "gesture")
            for msg in msgs:
                self.emit(msg)

            self.stats.update(person=now - last_person < 1.0, hands=len(hands),
                              shape=hands[0].shape if hands else None,
                              open=round(hands[0].openness, 2) if hands else None)
            self._presence_tick(now, last_person, awake)
            self._camera_want(now)
            if now - fps_t >= 2.0:
                self.stats["fps"] = round(frames / (now - fps_t), 1)
                frames, fps_t = 0, now

    def _trace_fist(self, now, hands, awake, closed):
        """Diagnostics: one log line per close-the-hand attempt (open hand -> fist
        -> open again), with the readings that decide whether the HUD closes."""
        tr = getattr(self, "_ft", None)
        if tr is None:
            tr = self._ft = {"peak": 0.0, "peak_t": 0.0, "low": None, "low_t": 0.0}
        if not awake or not hands or not self.engine.close_fist:
            return
        o = hands[0].openness
        if tr["low"] is None:
            if o >= tr["peak"] or now - tr["peak_t"] > 1.5:
                tr["peak"], tr["peak_t"] = o, now
            if o < 0.5:
                tr["low"], tr["low_t"] = o, now
        else:
            if o < tr["low"]:
                tr["low"], tr["low_t"] = o, now
            if closed or o > 0.6:
                log.info("fist attempt: open %.0f%% -> tightest %.0f%% after %.2fs -> %s",
                         100 * tr["peak"], 100 * tr["low"], tr["low_t"] - tr["peak_t"],
                         "closed the HUD" if closed else "no close")
                tr.update(peak=o, peak_t=now, low=None)

    def _hand_active(self, hands) -> bool:
        """While the HUD is closed: does any real hand move or open / close? Each hand
        is compared with where it was last seen doing so (kept across idle spells, so a
        hand resting in view does not count again each time the camera comes back)."""
        active = False
        for o in hands:
            if o.evidence < ACTIVE_EVIDENCE:
                continue
            near = min(self.still_refs, key=lambda r: (r[0] - o.x) ** 2 + (r[1] - o.y) ** 2, default=None)
            if (near is not None and np.hypot(near[0] - o.x, near[1] - o.y) <= ACTIVE_MOVE
                    and abs(near[2] - o.openness) <= ACTIVE_OPEN):
                continue
            active = True
            if near is not None and np.hypot(near[0] - o.x, near[1] - o.y) <= 4 * ACTIVE_MOVE:
                self.still_refs.remove(near)  # the same hand, moved on
            self.still_refs = (self.still_refs + [(o.x, o.y, o.openness)])[-3:]
        return active

    def _camera_want(self, now):
        """Full-rate frames are needed while the HUD is (becoming) visible, a hand was
        active recently, or a wake gesture is under way (after a prewake; a fist -> open
        that could still complete, even with the hand held still or lost from view for a
        moment); otherwise the app may drop to its low-power mode."""
        want = (self.state != "asleep" or now - self.last_activity < ACTIVE_HOLD or now < self.prewake_until
                or self.engine.wake_pending(now))
        if want != self.want_active:
            self.want_active = want
            self.emit({"t": "camera-want", "active": want})

    @staticmethod
    def _head(det, fx, fy, aspect):
        """Head position (mirrored frame) and rough yaw/pitch from BlazeFace keypoints."""
        yaw = pitch = 0.0
        kp = det.keypoints
        if kp and len(kp) >= 3:
            ex, ey = (kp[0].x + kp[1].x) / 2, (kp[0].y + kp[1].y) / 2
            eye = max(abs(kp[0].x - kp[1].x) * aspect, 1e-3)
            yaw = (kp[2].x - ex) * aspect / eye
            pitch = (kp[2].y - ey) / eye
        return {"t": "head", "x": round(fx, 4), "y": round(fy, 4), "yaw": round(yaw, 3), "pitch": round(pitch, 3)}

    def _darkness(self, now, dark):
        """Follow whether the frames are dark (the room's light is off)."""
        if dark:
            if self.dark_since is None:
                self.dark_since = now
        elif self.dark_since is not None:
            self.dark_since, self.lit_since = None, now

    def _presence_tick(self, now, last_person, awake):
        """Close the HUD by itself (each rule can be turned off): when the room has been dark
        for away_seconds ("dark"), or when it is lit and nobody has been seen for that long
        ("away"). Without frames (camera paused) nobody counts as present.
        Both on (the default): nobody seen for away_seconds, as before the switches existed
        (nobody can be seen in the dark), so frames that flicker around the darkness
        threshold cannot keep it open. Only the dark rule: dark for away_seconds in a row.
        Only the away rule: it stays open in the dark, and counts only from when the light
        came back."""
        if not awake:
            return
        cfg, wait = self.cfg, self.cfg["away_seconds"]
        dark = self.dark_since is not None
        if cfg["auto_close_away"] and cfg["auto_close_dark"]:
            if now - max(last_person, self.awake_since) > wait:
                self.request("sleep", "dark" if dark else "away")
        elif cfg["auto_close_dark"]:
            if dark and now - max(self.dark_since, self.awake_since) > wait:
                self.request("sleep", "dark")
        elif cfg["auto_close_away"]:
            if not dark and now - max(last_person, self.awake_since, self.lit_since) > wait:
                self.request("sleep", "away")

    # ---- asyncio side
    async def link(self):
        """Connect to hud-core and exchange messages; reconnects forever."""
        while True:
            try:
                async with aiohttp.ClientSession() as s:
                    async with s.ws_connect(f"http://127.0.0.1:{self.port}/vision",
                                            heartbeat=10) as ws:
                        log.info("connected to hud-core")
                        await ws.send_json({"t": "state", "awake": self.state == "awake"})
                        await ws.send_json({"t": "camera-want", "active": bool(self.want_active)})
                        sender = asyncio.ensure_future(self._sender(ws))
                        try:
                            async for msg in ws:
                                if msg.type != aiohttp.WSMsgType.TEXT:
                                    continue
                                self._on_message(json.loads(msg.data))
                        finally:
                            sender.cancel()
            except Exception as e:
                log.debug("core link: %s", e)
            await asyncio.sleep(1.5)

    async def _sender(self, ws):
        while True:
            msg = await self.out.get()
            await ws.send_json(msg)

    def _on_message(self, d):
        t = d.get("t")
        if t == "slept":
            self.slept.set()
        elif t == "hello":
            self.emit({"t": "state", "awake": self.state == "awake"})
            self.emit({"t": "camera-want", "active": bool(self.want_active)})
        elif t == "force":  # keyboard (fn+shift+H / Esc), menu, or debug tools
            asyncio.ensure_future(self._transition("wake" if d.get("awake") else "sleep", "manual"))
        elif t == "overlay-ready":
            self.overlay_ready.set()
        elif t == "overlay-hidden":
            self.overlay_hidden.set()
        elif t == "camera":
            self.camera_mode = str(d.get("mode"))

    async def housekeeping(self):
        while True:
            await asyncio.sleep(2)
            self.emit({"t": "vstat", "state": self.state, "camera": self.camera_mode,
                       "want_active": bool(self.want_active),
                       "alive": time.monotonic() - self.worker_beat < 15, **self.stats})

    async def main(self):
        self.loop = asyncio.get_running_loop()
        self.out = asyncio.Queue()
        self.slept = asyncio.Event()
        self.rewake = asyncio.Event()
        self.overlay_ready = asyncio.Event()
        self.overlay_hidden = asyncio.Event()
        threading.Thread(target=self._worker_guard, daemon=True, name="worker").start()
        await asyncio.gather(self.link(), self.housekeeping())

    def _worker_guard(self):
        try:
            self.worker()
        except Exception:
            log.exception("engine worker crashed")
            os._exit(1)  # the app restarts us


def main():
    service = EngineService()
    watch_parent(log, service.frames.discard)  # the app crashed: no frames stay behind
    asyncio.run(service.main())


if __name__ == "__main__":
    main()
