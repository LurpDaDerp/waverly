"""Stand-in for the macOS app's camera: streams a video file into the frame ring.

Lets the Python engine be tested on any machine without the Swift app.
    python3 tools/fake_camera.py calibration/waving.mov --fps 30 [--loop]
Environment: HUD_STATE (where frames.shm / frames.sock live), like the engine.
"""
import argparse
import os
import sys
import time
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from hud.common import STATE  # noqa: E402
from hud.framering import FrameWriter  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("video")
ap.add_argument("--fps", type=float, default=30)
ap.add_argument("--loop", action="store_true")
ap.add_argument("--start-delay", type=float, default=0.0)
a = ap.parse_args()

w = FrameWriter(os.environ.get("HUD_FRAMES", STATE / "frames.shm"), os.environ.get("HUD_FRAMES_SOCK", STATE / "frames.sock"))
time.sleep(a.start_delay)
period = 1 / a.fps
while True:
    cap = cv2.VideoCapture(a.video)
    n, t0 = 0, time.monotonic()
    while True:
        ok, f = cap.read()
        if not ok:
            break
        # letterbox/scale into 640x480 like a webcam frame
        h, wd = f.shape[:2]
        s = min(640 / wd, 480 / h)
        f = cv2.resize(f, (int(wd * s), int(h * s)), interpolation=cv2.INTER_AREA)
        canvas = cv2.copyMakeBorder(f, (480 - f.shape[0]) // 2, 480 - f.shape[0] - (480 - f.shape[0]) // 2,
                                    (640 - f.shape[1]) // 2, 640 - f.shape[1] - (640 - f.shape[1]) // 2,
                                    cv2.BORDER_CONSTANT, value=(40, 40, 40))
        w.write(canvas, time.monotonic_ns())
        n += 1
        time.sleep(max(0.0, t0 + n * period - time.monotonic()))
    if not a.loop:
        break
print(f"streamed {w.seq} frames")
