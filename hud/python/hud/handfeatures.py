"""MediaPipe models and hand measurements, shared by every platform.

The shape and openness measurements come from the Linux hud-vision service
(hud/vision.py), the reference implementation. hand_evidence() and observe() are
additions: they score how much a detection looks like a real hand, so a phantom
"hand" on a face leaning toward the camera cannot open the HUD. palm_orientation()
is one too: which way the palm faces, so only a palm toward the camera wakes the HUD. Do not change
thresholds here without re-validating them with tests/test_gestures.py and
tools/replay_video.py.
"""
from __future__ import annotations

import math
import os

os.environ.setdefault("GLOG_minloglevel", "2")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np  # noqa: E402
from mediapipe.tasks.python import BaseOptions, vision as mpv  # noqa: E402

from .common import MODELS  # noqa: E402
from .gestures import FIST, OTHER, PALM, HandObs  # noqa: E402


# --------------------------------------------------------------------------- models
def _opts(cls, path, **kw):
    return cls(base_options=BaseOptions(model_asset_path=str(MODELS / path)),
               running_mode=mpv.RunningMode.VIDEO, **kw)


class Models:
    def __init__(self):
        self.gesture = mpv.GestureRecognizer.create_from_options(_opts(
            mpv.GestureRecognizerOptions, "gesture_recognizer.task", num_hands=1,  # one hand: ~2x faster, every gesture is one-handed
            min_hand_detection_confidence=0.6, min_hand_presence_confidence=0.6,
            min_tracking_confidence=0.5))
        self.face = mpv.FaceDetector.create_from_options(_opts(
            mpv.FaceDetectorOptions, "blaze_face_short_range.tflite", min_detection_confidence=0.55))
        self.pose = mpv.PoseLandmarker.create_from_options(_opts(
            mpv.PoseLandmarkerOptions, "pose_landmarker_lite.task", num_poses=1,
            min_pose_detection_confidence=0.55, min_pose_presence_confidence=0.55))
        self._ts = {"g": 0, "f": 0, "p": 0}

    def ts(self, key, t):
        v = max(int(t * 1000), self._ts[key] + 1)
        self._ts[key] = v
        return v


TIPS = ((8, 6), (12, 10), (16, 14), (20, 18))


def _fingers(pts: np.ndarray):
    wrist = pts[0]
    ext = curl = 0
    for tip, pip in TIPS:
        r = np.linalg.norm(pts[tip] - wrist) / max(np.linalg.norm(pts[pip] - wrist), 1e-6)
        ext += r > 1.15
        curl += r < 0.98
    return ext, curl


_CHAINS = ((1, 2, 3, 4), (5, 6, 7, 8), (9, 10, 11, 12), (13, 14, 15, 16), (17, 18, 19, 20))


def hand_openness(world: np.ndarray) -> float:
    """0 = a tight fist, 1 = all four fingers straight.

    Uses MediaPipe's 3D hand landmarks, so it does not depend on the viewing
    angle: in the flat image a fist seen knuckles-first looks two-thirds open.
    Each finger's straightness is its base-to-tip distance over its bone length,
    averaged over the four fingers (the thumb barely curls in a fist). Calibrated
    on the user's hand through this webcam: open hand ~0.96 or more, fist ~0.43
    (the webcam sees a fist a little looser than the reference photo did)."""
    s = 0.0
    for a, b, c, d in _CHAINS[1:]:
        bones = np.linalg.norm(world[b] - world[a]) + np.linalg.norm(world[c] - world[b]) + np.linalg.norm(world[d] - world[c])
        s += np.linalg.norm(world[d] - world[a]) / max(bones, 1e-9)
    return float(min(1.0, max(0.0, (s / 4 - 0.43) / 0.50)))


# --------------------------------------------------------------------------- orientation
# Which way the palm faces. The wake gestures only count with the palm toward the camera,
# so a hand scratching the head (seen edge-on) or showing its back cannot open the HUD.
CAMERA_DFOV = 70.0  # degrees: the camera's diagonal field of view (Mac webcams at 640x480: ~60-75)


def palm_orientation(world: np.ndarray, pts: np.ndarray, aspect: float, model_label: str):
    """(yaw, pitch) of the palm in degrees; (0, 0) = palm squarely facing the camera.

    world: MediaPipe's 3D hand world landmarks (metres; x right, y down, z away from
    the camera, as in the image); pts: the image landmarks (fractions of the image).

    The palm's normal is the sum of the normals of the triangles wrist-index MCP-middle
    MCP, wrist-middle-ring MCP and wrist-ring-pinky MCP (an area-weighted plane through
    the wrist and all four knuckles). Which side of that plane is the palm depends on
    the hand's chirality, i.e. on the model's handedness label: measured on the
    calibration clips (real palms toward the camera), the normal points out of the palm
    for the label "Right" and out of the back of the hand for "Left" (the frame is
    mirrored before MediaPipe sees it; mirroring swaps the label and the hand's
    chirality together, so this holds either way). The world landmarks are aligned with
    the camera's axes, so the normal is then compared with the direction from the hand
    to the camera (from the hand's position in the image and CAMERA_DFOV), not with the
    optical axis: a palm toward the lens counts as facing anywhere in the frame (at the
    edge of the frame the two differ by ~30 degrees).

    yaw: rotation about the vertical axis (> 0: the palm turned toward the image's
    right); pitch: rotation about the horizontal axis (> 0: the palm turned up toward
    the ceiling). Edge-on hands read |yaw| or |pitch| near 90, the back of the hand
    |yaw| near 180. Returns (None, None) when the knuckles are degenerate."""
    p0 = world[0]
    n = (np.cross(world[5] - p0, world[9] - p0) + np.cross(world[9] - p0, world[13] - p0)
         + np.cross(world[13] - p0, world[17] - p0))
    size = float(np.linalg.norm(n))
    if not math.isfinite(size) or size < 1e-12:
        return None, None
    n = n / size * (1.0 if model_label == "Right" else -1.0)
    # direction from the palm's centre to the camera (pinhole model, image centre on axis)
    cx, cy = pts[[0, 5, 9, 13, 17]].mean(axis=0)
    f = 0.5 * math.hypot(aspect, 1.0) / math.tan(math.radians(CAMERA_DFOV) / 2)
    v = -np.array([(cx - 0.5) * aspect, cy - 0.5, f])
    v /= np.linalg.norm(v)
    # rotate the frame so that v becomes (0, 0, -1): about the vertical axis, then the horizontal
    a = math.atan2(v[0], -v[2])
    c, s = math.cos(a), math.sin(a)
    ry = np.array([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]])
    v, n = ry @ v, ry @ n
    b = math.atan2(-v[1], -v[2])
    c, s = math.cos(b), math.sin(b)
    n = np.array([[1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]]) @ n
    yaw = math.degrees(math.atan2(n[0], -n[2]))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, -n[1]))))
    if not (math.isfinite(yaw) and math.isfinite(pitch)):
        return None, None  # (a non-finite landmark)
    return yaw, pitch


def hand_shape(pts: np.ndarray, cat: str, score: float) -> str:
    """pts: landmarks in pixel-proportional units (x scaled by the frame's aspect)."""
    ext, curl = _fingers(pts)
    # The recognizer decides; finger geometry only fills in when it is unsure,
    # so a thumbs-up or peace sign can never pass for an open palm.
    if (cat == "Closed_Fist" and score >= 0.5) or (curl >= 4 and cat in ("None", "Closed_Fist", "Thumb_Up", "Thumb_Down")):
        return FIST
    if (cat == "Open_Palm" and score >= 0.5) or (ext >= 4 and cat in ("None", "Open_Palm")):
        return PALM
    return OTHER


def hand_strict(pts: np.ndarray, cat: str, score: float, shape: str, model_label: str) -> bool:
    """The strict version of the shape, used to close the HUD.

    PALM: all five fingers spread, the palm square to the camera (not edge-on)
    and its inside facing the camera (not the back of the hand).
    FIST: a clear fist, not a thumbs-up.
    """
    ext, curl = _fingers(pts)
    if shape == FIST:
        return (cat == "Closed_Fist" and score >= 0.55) or (curl >= 4 and cat in ("None", "Closed_Fist"))
    if shape != PALM or cat != "Open_Palm" or score < 0.55 or ext < 4:
        return False
    thumb_out = np.linalg.norm(pts[4] - pts[17]) > np.linalg.norm(pts[3] - pts[17]) * 1.05
    width = np.linalg.norm(pts[5] - pts[17]) / max(np.linalg.norm(pts[9] - pts[0]), 1e-6)
    a, b = pts[5] - pts[0], pts[17] - pts[0]
    cross = a[0] * b[1] - a[1] * b[0]
    # Calibrated on the back of a hand: there the cross product is negative for
    # the model's "Left" label and positive for "Right". The palm side is the reverse.
    facing = cross * (1.0 if model_label == "Left" else -1.0) > 0
    return bool(thumb_out and width >= 0.5 and facing)


# --------------------------------------------------------------------------- evidence
# Leaning toward the camera makes MediaPipe's palm detector fire on the lower face
# (mouth, chin) for a few frames at a time. Those phantom hands look curled one frame
# and open the next, which used to pass for the fist-then-open wake gesture. The
# hand landmark model always draws a hand-shaped skeleton, so their geometry looks
# like a hand; what gives them away is where they sit. Measured on the calibration
# clips zoomed in on the face (tools/replay_video.py --lean): a phantom lies wholly
# inside the face's box and is small next to it (its box is 5-20% of the face's),
# while a real hand inside a face's box is almost always 35% of it or more: it is in
# front of the face, so it looks about as big as the face or bigger (and the face
# detector sometimes boxes the hand itself).
EV_HANDEDNESS = (0.5, 0.8)  # handedness confidence: 0.5 (a coin toss) halves the evidence, 0.8+ costs nothing
EV_INSIDE = (0.8, 0.95)     # share of the hand's box inside a face's box: penalised from 0.8, fully at 0.95...
EV_SMALL = (0.4, 0.25)      # ...when the hand's box is this small next to the face's (area ratio, fully at 0.25)
EV_INSIDE_FLOOR = 0.1       # evidence left for a hand wholly inside a face, small next to it
EV_FINGER = (2.0, 3.0)      # image length of the middle finger over the hand size (99% of real frames <= 1.8)
EV_FINGER_FLOOR = 0.5
EV_NO_GESTURE = 0.9         # the recognizer names no gesture (common for real hands in motion too)
FACE_MEMORY = 0.5           # s a face's box still counts after the face detector misses it


def _ramp(v: float, lo: float, hi: float) -> float:
    """0 at lo, 1 at hi (either direction), clamped."""
    return min(1.0, max(0.0, (v - lo) / (hi - lo)))


def face_boxes(det_result, width: int, height: int) -> list[tuple[float, float, float, float]]:
    """Face detector boxes as (x, y, w, h) fractions of the image."""
    return [(d.bounding_box.origin_x / width, d.bounding_box.origin_y / height,
             d.bounding_box.width / width, d.bounding_box.height / height) for d in det_result.detections]


def hand_evidence(pts: np.ndarray, geo: np.ndarray, hd_score: float, cat: str, cat_score: float,
                  faces=()) -> tuple[float, dict]:
    """How much one detection looks like a real hand: (0..1, the factors behind it).

    pts: image landmarks (fractions of the image); geo: the same in pixel-proportional
    units; faces: face boxes (x, y, w, h) found in the same frame."""
    hand = 0.5 + 0.5 * _ramp(hd_score, *EV_HANDEDNESS)
    x0, y0 = pts.min(axis=0)
    x1, y1 = pts.max(axis=0)
    area = max(float((x1 - x0) * (y1 - y0)), 1e-6)
    face = 1.0
    for fx, fy, fw, fh in faces:
        ix = max(0.0, min(x1, fx + fw) - max(x0, fx))
        iy = max(0.0, min(y1, fy + fh) - max(y0, fy))
        inside = ix * iy / area
        small = area / max(fw * fh, 1e-6)
        face = min(face, 1.0 - (1.0 - EV_INSIDE_FLOOR) * _ramp(inside, *EV_INSIDE) * _ramp(small, *EV_SMALL))
    size = max(np.linalg.norm(geo[0] - geo[9]), 1.25 * np.linalg.norm(geo[5] - geo[17]), 1e-6)
    finger = sum(np.linalg.norm(geo[k + 1] - geo[k]) for k in (9, 10, 11)) / size
    shape = 1.0 - (1.0 - EV_FINGER_FLOOR) * _ramp(finger, *EV_FINGER)
    gesture = 1.0 if cat not in ("None", "") and cat_score >= 0.5 else EV_NO_GESTURE
    parts = {"handedness": hand, "face": float(face), "shape": float(shape), "gesture": gesture}
    return float(hand * face * shape * gesture), parts


def observe(res, i: int, aspect: float, faces=()) -> HandObs:
    """One GestureRecognizer hand as a HandObs. side_hint is the model's own
    handedness (the caller may correct it); the image is mirrored, so the model's
    "Left" is the user's right hand. yaw / pitch: the palm's orientation
    (palm_orientation), read with the model's own label for this frame."""
    pts = np.array([[p.x, p.y] for p in res.hand_landmarks[i]], dtype=np.float32)
    geo = pts * np.array([aspect, 1.0], dtype=np.float32)  # true proportions
    palm = pts[[0, 5, 9, 13, 17]].mean(axis=0)
    size = max(np.linalg.norm(pts[0] - pts[9]), 1.25 * np.linalg.norm(pts[5] - pts[17]))
    g = res.gestures[i][0] if i < len(res.gestures) and res.gestures[i] else None
    cat, score = (g.category_name, g.score) if g else ("None", 0.0)
    hd = res.handedness[i][0]
    label = 1 if hd.category_name == "Left" else -1
    shape = hand_shape(geo, cat, score)
    strict = hand_strict(geo, cat, score, shape, hd.category_name)
    evidence, parts = hand_evidence(pts, geo, hd.score, cat, score, faces)
    wl = res.hand_world_landmarks[i] if i < len(res.hand_world_landmarks or ()) else None
    if wl:
        world = np.array([[q.x, q.y, q.z] for q in wl], dtype=np.float32)
        yaw, pitch = palm_orientation(world, pts, aspect, hd.category_name)
    else:  # no 3D landmarks: openness from the image landmarks' relative depth, orientation unknown (never wakes)
        world = np.array([[p.x * aspect, p.y, p.z * aspect] for p in res.hand_landmarks[i]], dtype=np.float32)
        yaw = pitch = None
    return HandObs(float(palm[0]), float(palm[1]), float(size), shape, label * hd.score, strict,
                   hand_openness(world), evidence, label, parts, yaw, pitch)
