"""Tests for the helpers stopping when the macOS app is gone (hud/common.py watch_parent).

The app passes its PID as HUD_PARENT_PID. A crash or Force Quit skips the app's own
cleanup, so hud-core and hud-engine must notice and stop by themselves (the engine
deleting the frame ring first). Here a stand-in "app" process starts a stand-in helper
and is then killed with SIGKILL. No network, no real helpers, no port.

Run:  python3 tests/test_parent_watch.py      (from hud/, with the venv active)
  or  python3 -m pytest tests/test_parent_watch.py
"""
import atexit
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PY_DIR = Path(__file__).resolve().parents[1] / "python"
_TMP = Path(tempfile.mkdtemp(prefix="waverly-parent-"))
atexit.register(shutil.rmtree, _TMP, ignore_errors=True)
os.environ["HUD_STATE"] = str(_TMP)  # the helpers inherit it: nothing may touch the real state folder
os.environ["HUD_CONFIG"] = str(_TMP / "config.json")

# The helper: watch the parent, then idle. `no_kqueue` takes the polling fallback.
HELPER = """
import logging, select, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
if sys.argv[3] == "no_kqueue":
    del select.kqueue
from hud.common import watch_parent
logging.basicConfig(level=logging.INFO, format="%(message)s")
out = Path(sys.argv[2])
watch_parent(logging.getLogger("t"), lambda: (out / "cleaned").write_text("yes"))
(out / "ready").write_text("yes")
time.sleep(60)
"""

# The app: start the helper (with or without HUD_PARENT_PID), say its pid, then idle.
APP = """
import os, subprocess, sys, time
env = dict(os.environ)
env.pop("HUD_PARENT_PID", None)
if sys.argv[4] == "pid":
    env["HUD_PARENT_PID"] = str(os.getpid())
log = open(os.path.join(sys.argv[2], "helper.log"), "w")
p = subprocess.Popen([sys.executable, "-c", sys.argv[5], sys.argv[1], sys.argv[2], sys.argv[3]],
                     env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
print(p.pid, flush=True)
time.sleep(60)
"""


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run_case(name: str, mode: str, pid_env: str):
    """Start the app and helper, wait for the helper to be watching, SIGKILL the app.
    Returns (helper pid, out folder, seconds until the helper stopped or None)."""
    out = _TMP / name
    out.mkdir()
    app = subprocess.Popen([sys.executable, "-c", APP, str(PY_DIR), str(out), mode, pid_env, HELPER],
                           stdout=subprocess.PIPE, text=True)
    helper = int(app.stdout.readline())
    deadline = time.monotonic() + 15
    while not (out / "ready").exists():
        assert time.monotonic() < deadline, "helper never started"
        time.sleep(0.05)
    os.kill(app.pid, signal.SIGKILL)                     # a Force Quit: no cleanup
    app.wait()
    t0 = time.monotonic()
    while alive(helper) and time.monotonic() - t0 < 4:
        time.sleep(0.05)
    return helper, out, (None if alive(helper) else time.monotonic() - t0)


def test_helper_stops_when_app_killed():
    helper, out, took = run_case("kq", "kqueue", "pid")
    assert took is not None and took < 1.0, took         # macOS: told at once (kqueue)
    assert (out / "cleaned").read_text() == "yes"        # cleanup ran first
    assert "Waverly is gone: stopping" in (out / "helper.log").read_text()


def test_helper_stops_by_polling():
    helper, out, took = run_case("poll", "no_kqueue", "pid")
    assert took is not None and took < 3.0, took         # checked every 2 s
    assert (out / "cleaned").read_text() == "yes"


def test_run_by_hand_keeps_running():
    helper, out, took = run_case("hand", "kqueue", "none")
    try:
        assert took is None                              # no HUD_PARENT_PID: nothing watches
        assert not (out / "cleaned").exists()
    finally:
        os.kill(helper, signal.SIGKILL)


def test_helpers_use_it():
    core = (PY_DIR / "hud" / "core.py").read_text()
    engine = (PY_DIR / "hud" / "engine.py").read_text()
    assert "    watch_parent(log)\n" in core.split("def main():", 1)[1]
    assert "watch_parent(log, service.frames.discard)" in engine.split("def main():", 1)[1]


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", name)
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
