"""Shared configuration and small helpers for the Waverly services (hud-core, hud-engine)."""
import copy
import errno
import json
import logging
import math
import os
import select
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path
from zoneinfo import ZoneInfo

# Paths. The macOS app sets HUD_ROOT (the bundled resources), HUD_STATE
# (~/Library/Application Support/Waverly) and HUD_CONFIG (config.json in HUD_STATE).
_DEFAULT_ROOT = "/opt/hud" if sys.platform.startswith("linux") else str(Path(__file__).resolve().parents[1])
_DEFAULT_STATE = ("/var/lib/hud" if sys.platform.startswith("linux")
                  else str(Path.home() / "Library" / "Application Support" / "Waverly"))
ROOT = Path(os.environ.get("HUD_ROOT", _DEFAULT_ROOT))
STATE = Path(os.environ.get("HUD_STATE", _DEFAULT_STATE))
UI_DIR = Path(os.environ.get("HUD_UI", str(ROOT / "ui")))
MODELS = Path(os.environ.get("HUD_MODELS", str(ROOT / "models")))
CONFIG_FILE = Path(os.environ.get("HUD_CONFIG", str(STATE / "config.json")))

# config.json is written only by the macOS app; these neutral defaults fill in
# anything missing so partial or older files always work.
LIST_TITLES = {"left": "Calendar", "right": "Tasks"}
LOOKAHEAD_DAYS = 30
DEFAULTS = {
    "version": 2,
    "onboarded": False,
    "name": "",
    "location_auto": True,
    "place": "",
    "lat": None,                       # None = no location yet (no weather)
    "lon": None,
    "temperature_unit": "fahrenheit",  # fahrenheit | celsius
    "wind_unit": "mph",                # mph | kmh
    "clock": "12h",                    # 12h | 24h
    # Appearance (the page applies these live)
    "theme": "adaptive",               # adaptive (tone follows the sky) | light | dark
    "parallax": True,                  # head-tracking lean of the cards and shift of the sky
    "weather_animation": True,         # False: the ambient sky layer is drawn once, not animated
    "weather_detail": "high",          # high | medium | low (low = sky gradient only)
    "open_animation_s": 1.0,           # how long the HUD takes to appear (0 = instantly)
    "close_animation_s": 0.75,         # ...and to disappear (0 = instantly)
    "open_animation": "fade",          # fade | zoom | shatter | slide | swirl (hud/ui/anim.js)
    "close_animation": "fade",
    # Hand-gesture scrolling only (the trackpad always follows the system setting)
    "scroll_reverse_vertical": False,
    "scroll_reverse_horizontal": False,
    "scroll_speed_vertical": 1.0,      # hand-scrolling speed, x the standard (SCROLL_SPEED_RANGE)
    "scroll_speed_horizontal": 1.0,
    # Which gestures open and close the HUD (Settings › Controls). With both open gestures
    # off, only the keyboard shortcut and the menu open it. hud-engine applies these live.
    "gesture_open_wave": True,         # open by waving: one sweep across the camera, palm to it
    "gesture_open_fist": True,         # open by making a fist, then opening the hand
    "gesture_close_fist": True,        # close by making a fist (from an open palm)
    "auto_close_away": True,           # close when nobody has been seen for away_seconds
    "auto_close_dark": True,           # close when the room has been dark for away_seconds
    "lists": {
        # sources None = never customised: left = the calendars shown in Google
        # Calendar, right = every task list. Otherwise ["cal:<id>", "tasks:<id>", ...].
        "left": {"title": LIST_TITLES["left"], "sources": None, "event_keywords": "", "task_keywords": ""},
        "right": {"title": LIST_TITLES["right"], "sources": None, "event_keywords": "", "task_keywords": "",
                  "countdowns": True, "lookahead_days": LOOKAHEAD_DAYS},
    },
    "source_style": {},                # "<sourceKey>": {"color": paletteId|None, "category": categoryId|None}
    "categories": [],                  # [{"id": ..., "name": ..., "color": paletteId}]
    "http_port": 47780,
    # Vision tuning (not in the UI)
    "dark_mean": 6.0,          # 0-255 mean luma below which the frame counts as dark...
    "dark_p99": 22.0,          # ...and the brightest 1% of pixels are also below this
    "away_seconds": 5.0,       # close the HUD when nobody has been seen (or the room has been dark) this long
    "swap_handedness": False,  # set true if left/right hands come out reversed
}
ANIMATION_TYPES = ("fade", "zoom", "shatter", "slide", "swirl")
_CHOICES = {"temperature_unit": ("fahrenheit", "celsius"), "wind_unit": ("mph", "kmh"), "clock": ("12h", "24h"),
            "theme": ("adaptive", "light", "dark"), "weather_detail": ("high", "medium", "low"),
            "open_animation": ANIMATION_TYPES, "close_animation": ANIMATION_TYPES}
GESTURE_FLAGS = ("gesture_open_wave", "gesture_open_fist", "gesture_close_fist", "auto_close_away", "auto_close_dark")
_FLAGS = ("parallax", "weather_animation", "scroll_reverse_vertical", "scroll_reverse_horizontal") + GESTURE_FLAGS
# Open / close animation lengths in seconds: 0 means instant (no animation), otherwise
# within these bounds (Settings › Appearance offers "Instant", then the range in 0.1 s steps).
ANIMATION_RANGES = {"open_animation_s": (0.3, 2.0), "close_animation_s": (0.2, 1.5)}
# Hand-scrolling speed, a multiple of the standard speed (Settings › Controls, 0.25 steps).
SCROLL_SPEED_RANGE = (0.5, 2.0)
SCROLL_SPEEDS = ("scroll_speed_vertical", "scroll_speed_horizontal")

# Source colours, identical in Python, the page and the Swift app. `dark` is for the
# dark sky tone, `light` for the light tone, `swatch` for the Settings window.
PALETTE = [
    {"id": "blue", "dark": "#8DB4FF", "light": "#1F5BD0", "swatch": "#5B8DEF"},
    {"id": "amber", "dark": "#FFB877", "light": "#C25E12", "swatch": "#F0954A"},
    {"id": "teal", "dark": "#6FE0CF", "light": "#0E7C70", "swatch": "#2BB3A3"},
    {"id": "rose", "dark": "#FF9DC4", "light": "#B8336A", "swatch": "#E5679A"},
    {"id": "violet", "dark": "#C6A8FF", "light": "#6A3FD0", "swatch": "#9670EE"},
    {"id": "green", "dark": "#A2E38C", "light": "#2F7D1F", "swatch": "#63B84A"},
    {"id": "gold", "dark": "#FFDD7A", "light": "#8A6A00", "swatch": "#E3B93A"},
    {"id": "coral", "dark": "#FF9A8A", "light": "#C0392B", "swatch": "#EE6B5A"},
    {"id": "cyan", "dark": "#86D8FF", "light": "#0B6E9E", "swatch": "#3BAEE3"},
    {"id": "slate", "dark": "#CBD2DE", "light": "#4A5568", "swatch": "#8A94A6"},
]
PALETTE_IDS = [p["id"] for p in PALETTE]


class ConfigError(Exception):
    pass


def _number(v, default):
    try:
        ok = isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
    except OverflowError:  # an int too big for a float (hundreds of digits)
        ok = False
    return v if ok else default


def animation_seconds(v, key: str) -> float:
    """A valid open / close animation length: not a number -> the default, below the
    range's minimum -> 0.0 (instant), above its maximum -> the maximum."""
    lo, hi = ANIMATION_RANGES[key]
    n = _number(v, None)
    if n is None:
        return DEFAULTS[key]
    return 0.0 if n < lo else float(min(n, hi))


def merge_config(user: dict) -> dict:
    """DEFAULTS with `user` on top: lists.left / lists.right are merged key by key,
    and every value the services rely on is type-checked (bad value -> default)."""
    cfg = copy.deepcopy(DEFAULTS)
    for k, v in user.items():
        if k != "lists":
            cfg[k] = v
    cfg.pop("timezone", None)  # old configs: the Mac's own time zone is always used
    lists = user.get("lists") if isinstance(user.get("lists"), dict) else {}
    for side, base in DEFAULTS["lists"].items():
        part = lists.get(side)
        merged = cfg["lists"][side]
        if isinstance(part, dict):
            merged.update(part)
        for key in ("title", "event_keywords", "task_keywords"):
            if not isinstance(merged.get(key), str):
                merged[key] = base[key]
        src = merged.get("sources")
        merged["sources"] = [s for s in src if isinstance(s, str)] if isinstance(src, list) else None
        if side == "right":
            if not isinstance(merged.get("countdowns"), bool):
                merged["countdowns"] = True
            n = _number(merged.get("lookahead_days"), None)
            merged["lookahead_days"] = LOOKAHEAD_DAYS if n is None else min(max(int(n), 1), 365)

    for key in ("name", "place"):
        if not isinstance(cfg.get(key), str):
            cfg[key] = ""
    for key, choices in _CHOICES.items():
        if cfg.get(key) not in choices:
            cfg[key] = DEFAULTS[key]
    for key in _FLAGS:  # only a real boolean counts; anything else is the default
        if not isinstance(cfg.get(key), bool):
            cfg[key] = DEFAULTS[key]
    for key in ANIMATION_RANGES:
        cfg[key] = animation_seconds(cfg.get(key), key)
    for key in SCROLL_SPEEDS:  # not a number -> the default; otherwise clamped to the range
        n = _number(cfg.get(key), None)
        cfg[key] = DEFAULTS[key] if n is None else round(float(min(max(n, SCROLL_SPEED_RANGE[0]), SCROLL_SPEED_RANGE[1])), 2)
    lat, lon = _number(cfg.get("lat"), None), _number(cfg.get("lon"), None)
    if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        lat = lon = None
    cfg["lat"], cfg["lon"] = lat, lon
    if not isinstance(cfg.get("source_style"), dict):
        cfg["source_style"] = {}
    if not isinstance(cfg.get("categories"), list):
        cfg["categories"] = []
    port = cfg.get("http_port")
    if not (isinstance(port, int) and not isinstance(port, bool) and 0 < port < 65536):
        cfg["http_port"] = DEFAULTS["http_port"]
    for key in ("dark_mean", "dark_p99", "away_seconds"):
        cfg[key] = _number(cfg.get(key), DEFAULTS[key])
    cfg["swap_handedness"] = bool(cfg.get("swap_handedness"))
    return cfg


def load_config(strict: bool = False) -> dict:
    """config.json merged over DEFAULTS. A missing file gives the defaults. An unreadable
    one gives the defaults too (a broken config must never stop Waverly), or raises
    ConfigError when strict (live reload keeps the last good config instead)."""
    try:
        user = json.loads(CONFIG_FILE.read_text())
        if not isinstance(user, dict):
            raise ValueError("not a JSON object")
        return merge_config(user)  # inside the try: any value it can't cope with counts as unreadable
    except FileNotFoundError:
        return merge_config({})
    except Exception as e:
        if strict:
            raise ConfigError(str(e)) from e
        logging.getLogger("hud").error("config.json unreadable, using defaults: %s", e)
        return merge_config({})


def file_stamp(path):
    """Cheap change detector for a file (None while it doesn't exist)."""
    try:
        st = Path(path).stat()
        return st.st_mtime_ns, st.st_size, st.st_ino
    except OSError:
        return None


def system_tz_name(link: str = "/etc/localtime") -> str:
    """IANA name of the Mac's current time zone, read fresh on every call so travel
    works: /etc/localtime -> /var/db/timezone/zoneinfo/America/Los_Angeles. Else UTC."""
    targets = []
    for resolve in (os.readlink, os.path.realpath):  # the link itself first, then fully resolved
        try:
            targets.append(resolve(link))
        except (OSError, ValueError):
            pass
    for target in targets:
        i = target.rfind("/zoneinfo/")
        if i < 0:
            continue
        name = target[i + len("/zoneinfo/"):]
        for prefix in ("posix/", "right/"):
            name = name.removeprefix(prefix)
        try:
            ZoneInfo(name)
            return name
        except Exception:
            continue
    return "UTC"


def system_tz() -> ZoneInfo:
    return ZoneInfo(system_tz_name())


def setup_logging(name: str) -> logging.Logger:
    """Plain lines to stderr, plus (HUD_LOG_DIR set, as on macOS) a size-capped
    rotating file, so logs never fill the disk."""
    logging.basicConfig(level=logging.INFO, format=f"{name}: %(levelname)s %(message)s")
    log_dir = os.environ.get("HUD_LOG_DIR")
    if log_dir:
        from logging.handlers import RotatingFileHandler
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        h = RotatingFileHandler(Path(log_dir) / f"{name}.log", maxBytes=2_000_000, backupCount=2)
        h.setFormatter(logging.Formatter("%(asctime)s " + name + ": %(levelname)s %(message)s"))
        logging.getLogger().addHandler(h)
    return logging.getLogger(name)


def watch_parent(log: logging.Logger, cleanup=None) -> None:
    """Stop this helper when the macOS app that started it is gone. The app passes its
    PID as HUD_PARENT_PID; a crash or Force Quit skips the app's own cleanup, and the
    helper would otherwise keep running (and keep the port) until the app's next launch.
    `cleanup` runs first. Without HUD_PARENT_PID (run by hand) this does nothing."""
    try:
        pid = int(os.environ.get("HUD_PARENT_PID") or 0)
    except ValueError:
        pid = 0
    if pid <= 1:
        return

    def wait_gone():
        if os.getppid() != pid:
            return  # gone already (we were handed to launchd)
        if hasattr(select, "kqueue"):  # macOS: told the moment it exits
            kq = select.kqueue()
            try:
                ev = select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                   select.KQ_NOTE_EXIT)
                got = kq.control([ev], 1, None)
                # an exit, or ESRCH (it exited before we asked); any other error: poll below
                if got and (not got[0].flags & select.KQ_EV_ERROR or got[0].data == errno.ESRCH):
                    return
            except OSError:
                pass
            finally:
                kq.close()
        while os.getppid() == pid:
            time.sleep(2)

    def run():
        wait_gone()
        log.warning("Waverly is gone: stopping")
        try:
            if cleanup:
                cleanup()
        except Exception:
            log.exception("cleanup before stopping failed")
        finally:
            for h in logging.getLogger().handlers:
                h.flush()
            os._exit(0)

    threading.Thread(target=run, daemon=True, name="parent").start()


def write_json_atomic(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def sd_notify(msg: str) -> None:
    """Minimal sd_notify so systemd's WatchdogSec can restart a hung service."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
            s.connect(addr)
            s.sendall(msg.encode())
    except OSError:
        pass
