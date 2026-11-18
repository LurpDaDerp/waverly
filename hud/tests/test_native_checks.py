"""Tests for the first-run setup's pins and the macOS app's helper checks:

  * tools/setup_macos.sh pins every package to an exact version (MediaPipe 1.2.3), and
    its --check mode accepts an environment with exactly those versions and refuses one
    that differs (the app runs it after an update to decide whether to rebuild);
  * the script replaces an existing (possibly broken) environment instead of stopping;
  * macos/Sources/HelperChecks.swift, compiled on its own with swiftc: the pins the app
    reads from the script, their fingerprint (the venv's ready marker), the crash-loop
    counter and the port check.

Run:  python3 tests/test_native_checks.py      (from hud/)
The --check tests need the app's environment (~/Library/Application Support/Waverly/venv);
the Swift tests need swiftc (Xcode). Either part is skipped when missing.
"""
import atexit
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

HUD = Path(__file__).resolve().parents[1]
ROOT = HUD.parent
SCRIPT = HUD / "tools/setup_macos.sh"
CHECKS = ROOT / "macos/Sources/HelperChecks.swift"
VENV = Path.home() / "Library/Application Support/Waverly/venv"

_TMP = Path(tempfile.mkdtemp(prefix="wv-native-"))
atexit.register(shutil.rmtree, _TMP, ignore_errors=True)


class Skip(Exception):
    pass


def pins(text):
    """The pins between the markers, as the app reads them."""
    block = text.split("# requirements:begin", 1)[1].split("# requirements:end", 1)[0]
    return re.findall(r'"([A-Za-z0-9][A-Za-z0-9._-]*==[A-Za-z0-9.+!_-]+)"', block)


def run_check(script, state):
    env = dict(os.environ, HUD_STATE=str(state), GLOG_minloglevel="2")
    return subprocess.run(["/bin/bash", str(script), "--check"], env=env, capture_output=True, text=True, timeout=120)


# ---- the setup script

def test_every_package_is_pinned_exactly():
    text = SCRIPT.read_text()
    p = pins(text)
    assert len(p) >= 20, p                                    # MediaPipe's dependencies too, not only the direct ones
    assert "mediapipe==1.2.3" in p
    names = [x.split("==")[0].lower() for x in p]
    assert len(set(names)) == len(names), "a package is pinned twice"
    for need in ("aiohttp", "numpy", "opencv-contrib-python", "matplotlib"):
        assert need in names, need
    # nothing in PACKAGES outside the pins (no ranges such as >=)
    block = text.split("# requirements:begin", 1)[1].split("# requirements:end", 1)[0]
    quoted = re.findall(r'"([^"]+)"', block)
    assert quoted == p, set(quoted) - set(p)


def test_existing_environment_is_replaced():
    text = SCRIPT.read_text()
    assert re.search(r'UV_VENV_CLEAR=1 uv venv ', text), "uv must replace an existing venv"
    assert '-m venv --clear "$VENV"' in text, "venv must replace an existing venv"


def _venv_state():
    if not (VENV / "bin/python").exists():
        raise Skip("no Waverly Python environment on this Mac")
    return VENV.parent


def test_check_accepts_the_installed_environment():
    r = run_check(SCRIPT, _venv_state())
    assert r.returncode == 0, r.stdout + r.stderr
    assert "ok: mediapipe 1.2.3" in r.stdout, r.stdout


def test_installed_environment_matches_the_pins_exactly():
    _venv_state()
    py = VENV / "bin/python"
    out = subprocess.run([str(py), "-c", "import importlib.metadata as m, json; "
                          "print(json.dumps({d.metadata['Name'].lower().replace('_', '-'): d.version for d in m.distributions()}))"],
                         capture_output=True, text=True, timeout=60).stdout
    import json
    have = json.loads(out)
    want = {x.split("==")[0].lower(): x.split("==")[1] for x in pins(SCRIPT.read_text())}
    extra = {k: v for k, v in have.items() if k not in want and k not in ("pip", "setuptools", "wheel")}
    assert not extra, f"installed but not pinned: {extra}"
    assert {k: have.get(k) for k in want} == want


def test_check_refuses_other_versions():
    state = _venv_state()
    text = SCRIPT.read_text()
    changed = _TMP / "setup_changed.sh"
    changed.write_text(text.replace('"aiohttp==', '"aiohttp==0.0.1+', 1))
    r = run_check(changed, state)
    assert r.returncode != 0, r.stdout
    assert "aiohttp" in r.stderr and "wants 0.0.1+" in r.stderr, r.stderr
    missing = _TMP / "setup_missing.sh"
    assert "\n)\n# requirements:end" in text
    missing.write_text(text.replace("\n)\n# requirements:end", '\n  "not-a-real-package-wv==1.0"\n)\n# requirements:end', 1))
    r = run_check(missing, state)
    assert r.returncode != 0 and "not-a-real-package-wv missing" in r.stderr, r.stdout + r.stderr


def test_check_without_environment_fails():
    r = run_check(SCRIPT, _TMP / "nothing-here")
    assert r.returncode != 0
    assert "no Python environment" in r.stdout


# ---- HelperChecks.swift

_SWIFT_MAIN = r'''
import Foundation
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }
let args = CommandLine.arguments
let script = try! String(contentsOfFile: args[1], encoding: .utf8)
let busyPort = Int(args[2])!, freePort = Int(args[3])!

// pins, as the app reads them from the bundled script
let pins = PythonRequirements.pins(inScript: script)
print("PINS", pins.joined(separator: " "))
let fp = PythonRequirements.fingerprint(pins)!
check(fp.count == 64, "fingerprint is a sha256")
check(PythonRequirements.fingerprint(pins.reversed()) == fp, "order does not matter")
check(PythonRequirements.fingerprint(pins.map { $0.uppercased() }) == fp, "case does not matter")
let reflowed = script.replacingOccurrences(of: "\n  \"", with: " \"")
check(PythonRequirements.fingerprint(PythonRequirements.pins(inScript: reflowed)) == fp, "layout does not matter")
let commented = script.replacingOccurrences(of: "# requirements:begin", with: "# requirements:begin\n# a comment")
check(PythonRequirements.fingerprint(PythonRequirements.pins(inScript: commented)) == fp, "comments do not matter")
let bumped = script.replacingOccurrences(of: "\"mediapipe==1.2.3\"", with: "\"mediapipe==1.2.4\"")
check(PythonRequirements.fingerprint(PythonRequirements.pins(inScript: bumped)) != fp, "a changed pin changes it")
check(PythonRequirements.fingerprint(Array(pins.dropLast())) != fp, "a removed pin changes it")
check(PythonRequirements.fingerprint(pins + ["extra==1"]) != fp, "an added pin changes it")
check(PythonRequirements.pins(inScript: "PACKAGES=(\"a==1\")").isEmpty, "no markers: no pins")
check(PythonRequirements.fingerprint([]) == nil, "no pins: no fingerprint")
check(PythonRequirements.pins(inScript: "# requirements:begin\n\"a>=1\" \"b==2\"\n# requirements:end") == ["b==2"], "ranges are not pins")

// crash loops: three exits within 10 s of launch, reported once per run of them
var c = CrashLoopCounter()
check(!c.exited(after: 1) && !c.exited(after: 2), "two quick exits are not a loop")
check(c.exited(after: 0.5), "the third quick exit is")
check(c.isLooping, "looping")
check(!c.exited(after: 1) && !c.exited(after: 1), "reported once")
check(!c.exited(after: 600) && !c.isLooping, "an exit after a long run starts over")
check(!c.exited(after: 1) && !c.exited(after: 1) && c.exited(after: 1), "a new run of quick exits is reported")
c.reset()
check(!c.isLooping && c.quickExits == 0, "reset")
var d = CrashLoopCounter()
check(!d.exited(after: 1) && !d.exited(after: 30) && !d.exited(after: 1) && !d.exited(after: 1), "quick exits must be in a row")

// the port check
check(!LocalPort.isFree(busyPort), "a port another socket listens on is taken")
check(LocalPort.isFree(freePort), "a free port is free")
check(!LocalPort.isFree(0) && !LocalPort.isFree(70000), "out of range")
print(failures == 0 ? "SWIFT OK" : "SWIFT FAILED \(failures)")
exit(failures == 0 ? 0 : 1)
'''


def test_helper_checks_swift():
    swiftc = shutil.which("swiftc") or "/usr/bin/swiftc"
    if not Path(swiftc).exists():
        raise Skip("no swiftc")
    main = _TMP / "main.swift"
    main.write_text(_SWIFT_MAIN)
    exe = _TMP / "checks"
    r = subprocess.run([swiftc, "-O", str(CHECKS), str(main), "-o", str(exe)], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stderr
    busy = socket.socket()
    busy.bind(("127.0.0.1", 0))
    busy.listen(1)
    free = socket.socket()
    free.bind(("127.0.0.1", 0))
    free_port = free.getsockname()[1]
    free.close()
    try:
        r = subprocess.run([str(exe), str(SCRIPT), str(busy.getsockname()[1]), str(free_port)],
                           capture_output=True, text=True, timeout=60)
    finally:
        busy.close()
    assert r.returncode == 0 and "SWIFT OK" in r.stdout, r.stdout + r.stderr
    swift_pins = next(line for line in r.stdout.splitlines() if line.startswith("PINS ")).split()[1:]
    assert swift_pins == pins(SCRIPT.read_text()), "Swift and the script disagree about the pins"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = skipped = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Skip as e:
            skipped += 1
            print("SKIP", name, f"({e})")
        except Exception:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", name)
            traceback.print_exc()
    print(f"\n{len(tests) - failed - skipped}/{len(tests)} passed" + (f", {skipped} skipped" if skipped else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
