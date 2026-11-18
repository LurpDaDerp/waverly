"""Run a recorded video through the exact gesture pipeline, offline (no app, no core).

Prints every stroke (target, axis, net movement), every wake/close event and every
wake decision with its confidence and palm orientation, plus the openness range and
the palm's yaw / pitch per hand shape (with the share facing the camera). Use it to
confirm a port behaves like the reference, or to calibrate on a new camera: record a
clip of an open hand, a fist, scroll strokes and the wake/close gestures, then replay it.

    python3 tools/replay_video.py calibration/scroll-strokes.mov [--asleep] [--lean 5] [--fps 12]
    python3 tools/replay_video.py calibration/open-hand-100.jpg   (a photo: replayed as 1 s of video)
    (feed the camera's raw, unmirrored view; phone selfie videos are usually unmirrored)

--lean Z simulates leaning toward the camera: the view zooms in on the face, up to Z
times and back every 4 s. A face alone must never wake the HUD.

The gesture settings (which gestures open and close the HUD) come from config.json, like
the engine's: point HUD_CONFIG at a scratch file to replay with other settings.
"""
import argparse
import math
import sys
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from hud.common import CONFIG_FILE, load_config  # noqa: E402
from hud.gestures import FACING_PITCH, FACING_YAW, GESTURE_SETTINGS, GestureEngine  # noqa: E402
from hud.handfeatures import FACE_MEMORY, Models, face_boxes, observe  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("video")
ap.add_argument("--asleep", action="store_true", help="replay with the HUD closed (wake gestures)")
ap.add_argument("--lean", type=float, default=0.0, metavar="Z", help="zoom in on the face up to Z times, every 4 s")
ap.add_argument("--fps", type=float, default=0.0, metavar="N",
                help="feed the engine only N frames a second, like the app (10-16 fps with a hand in view)")
a = ap.parse_args()

m = Models()
eng = GestureEngine()
eng.configure(load_config())
print(f"gestures ({CONFIG_FILE}): " + ", ".join(f"{a} {'on' if getattr(eng, a) else 'off'}" for a in GESTURE_SETTINGS))
photo = Path(a.video).suffix.lower() in (".jpg", ".jpeg", ".png", ".heic")
cap = None if photo else cv2.VideoCapture(a.video)
still = cv2.imread(a.video) if photo else None
if photo and still is None:
    sys.exit(f"cannot read {a.video}")
fps = 30 if photo else (cap.get(cv2.CAP_PROP_FPS) or 30)
i, strokes, events, opens, poses = 0, [], [], {}, {}
cur = None
face_c = None  # --lean: the face's centre in the unzoomed, unmirrored frame (pixels)
recent_faces, recent_faces_t = [], -1e9  # as in the engine: a face missed for a moment still counts


def faces_in(frame, t):
    rgb = cv2.cvtColor(cv2.flip(frame, 1), cv2.COLOR_BGR2RGB)
    img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
    return rgb, img, face_boxes(m.face.detect_for_video(img, m.ts("f", t)), rgb.shape[1], rgb.shape[0])


while True:
    if photo:
        ok, f = i < 30, still.copy()
    else:
        ok, f = cap.read()
    if not ok:
        break
    if f.shape[1] > 720:
        f = cv2.resize(f, (720, int(720 * f.shape[0] / f.shape[1])))
    t = 100 + i / fps
    i += 1
    if a.fps and int((i - 1) * a.fps / fps) == int((i - 2) * a.fps / fps) and i > 1:
        continue  # --fps: skip frames the app would not have processed
    if a.lean > 1:
        _, _, seen = faces_in(f, t)
        if seen:
            fx, fy, fw, fh = max(seen, key=lambda b: b[2])
            face_c = ((1 - fx - fw / 2) * f.shape[1], (fy + fh / 2) * f.shape[0])  # unmirror
        if face_c is not None:
            z = 1 + (a.lean - 1) * (0.5 - 0.5 * math.cos(2 * math.pi * (t - 100) / 4.0))
            warp = cv2.getRotationMatrix2D(face_c, 0, z)
            warp[:, 2] += (f.shape[1] / 2 - face_c[0], f.shape[0] / 2 - face_c[1])
            f = cv2.warpAffine(f, warp, (f.shape[1], f.shape[0]), borderMode=cv2.BORDER_REFLECT)
    rgb, img, faces = faces_in(f, t)
    if faces:
        recent_faces, recent_faces_t = faces, t
    elif t - recent_faces_t <= FACE_MEMORY:
        faces = recent_faces
    asp = rgb.shape[1] / rgb.shape[0]
    r = m.gesture.recognize_for_video(img, m.ts("g", t))
    hands = []
    for k in range(len(r.hand_landmarks)):
        o = observe(r, k, asp, faces)
        opens.setdefault(o.shape, []).append(o.openness)
        if o.yaw is not None:
            poses.setdefault(o.shape, []).append((o.yaw, o.pitch, o.facing))
        if all(np.hypot(p.x - o.x, p.y - o.y) > 0.6 * max(p.size, o.size) for p in hands):
            hands.append(o)
    ev, msgs = eng.update(t, hands, not a.asleep, not a.asleep)
    events += [(round(t - 100, 2), e) for e in ev]
    for note in eng.notes:
        print(f"  {t - 100:6.2f}  {note}")
    eng.notes.clear()
    for mm in msgs:
        if mm["kind"] == "move":
            if cur is None or cur[1] != mm["target"]:
                cur = [round(t - 100, 2), mm["target"], mm["axis"], 0.0]
                strokes.append(cur)
            cur[3] += mm["d"]
        elif mm["kind"] == "end":
            cur = None

print("strokes (start s, target, axis, net movement in frame units):")
for s in strokes:
    print(f"  {s[0]:6.2f}  {s[1]:9}  {s[2]}  {s[3]:+.3f}")
print("events:", events or "none")
for sh, v in opens.items():
    v = np.array(v)
    print(f"openness for '{sh}' frames: n={len(v)}  p10 {np.percentile(v, 10):.2f}  median {np.median(v):.2f}  p90 {np.percentile(v, 90):.2f}")
for sh, v in poses.items():
    v = np.array(v, dtype=float)
    pct = lambda c: "  ".join(f"p{q} {np.percentile(v[:, c], q):+5.0f}" for q in (10, 25, 50, 75, 90))  # noqa: E731
    print(f"palm orientation for '{sh}' frames (each frame's own label; facing = |yaw| <= {FACING_YAW:.0f}, "
          f"|pitch| <= {FACING_PITCH:.0f}): n={len(v)}  facing {v[:, 2].mean():.0%}")
    print(f"    yaw   {pct(0)}")
    print(f"    pitch {pct(1)}")
