#!/bin/bash
# Creates the Python environment Waverly runs its helpers from (MediaPipe, OpenCV,
# aiohttp, NumPy). Apple Silicon only: MediaPipe ships macOS wheels for arm64 only.
#
#   ./setup_macos.sh     -> ~/Library/Application Support/Waverly/venv   ($HUD_STATE/venv when set)
#
# Uses `uv` when it is on PATH (the app puts its bundled copy there; uv then
# downloads its own Python 3.12 into $UV_PYTHON_INSTALL_DIR), else python3.12 /
# python3 (3.10 or newer) with venv + pip.
# The app follows the "==> " lines to show progress; keep their wording stable.
#
#   ./setup_macos.sh --check   -> exit 0 if the environment imports and has exactly the
#                                 versions below (the app runs this on an environment it
#                                 did not just build, e.g. after an update)
set -euo pipefail
APP_SUPPORT="${HUD_STATE:-$HOME/Library/Application Support/Waverly}"
VENV="$APP_SUPPORT/venv"
# Every package at the exact version Waverly is tested with (MediaPipe's own dependencies
# too: it asks for any NumPy, OpenCV and Matplotlib), so a new release on PyPI can't break
# a new install. The app reads the lines between the markers: when they change, an
# existing environment is checked again and rebuilt if it doesn't match.
# requirements:begin
PACKAGES=(
  "absl-py==2.5.1"
  "aiohappyeyeballs==2.7.1"
  "aiohttp==3.14.5"
  "aiosignal==1.4.0"
  "attrs==26.1.0"
  "certifi==2026.10.23"
  "cffi==2.1.1"
  "contourpy==1.4.0"
  "cycler==0.12.1"
  "flatbuffers==25.12.19"
  "fonttools==4.68.0"
  "frozenlist==1.8.0"
  "idna==3.20"
  "kiwisolver==1.5.1"
  "matplotlib==3.11.2"
  "mediapipe==1.2.3"
  "multidict==7.2.1"
  "numpy==2.5.5"
  "opencv-contrib-python==5.1.0.95"
  "packaging==26.3"
  "pillow==13.0.0"
  "propcache==0.5.4"
  "pycparser==3.12"
  "pyparsing==3.3.3"
  "python-dateutil==4.0.0"
  "sounddevice==0.5.6"
  "typing-extensions==4.16.0"
  "tzdata==2026.6"
  "yarl==1.25.1"
)
# requirements:end

# Does the environment import, with exactly these versions?
check() {
  "$VENV/bin/python" - "${PACKAGES[@]}" <<'PY'
import sys
from importlib import metadata
import mediapipe, cv2, aiohttp, numpy
wrong = []
for pin in sys.argv[1:]:
    name, want = pin.split("==")
    try:
        have = metadata.version(name)
    except metadata.PackageNotFoundError:
        have = "missing"
    if have != want:
        wrong.append(f"{name} {have} (wants {want})")
if wrong:
    sys.exit("not the expected versions: " + ", ".join(wrong))
print("ok: mediapipe", mediapipe.__version__, "opencv", cv2.__version__, "aiohttp", aiohttp.__version__)
PY
}
if [ "${1:-}" = "--check" ]; then
  [ -x "$VENV/bin/python" ] || { echo "no Python environment at $VENV"; exit 1; }
  check
  exit
fi

[ "$(uname -m)" = "arm64" ] || { echo "Apple Silicon (arm64) required: MediaPipe has no Intel macOS wheels."; exit 1; }
mkdir -p "$APP_SUPPORT"

echo "==> Creating the Python environment"
if command -v uv >/dev/null 2>&1; then
  echo "uv $(uv --version 2>/dev/null | awk '{print $2}')"
  # replace what is there (a half-made or broken environment); older uv did so without asking
  UV_VENV_CLEAR=1 uv venv --python 3.12 "$VENV"
  PIP=(uv pip install --python "$VENV/bin/python")
else
  PY=$(command -v python3.12 || command -v python3)
  "$PY" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10 or newer is required"'
  echo "Python $("$PY" -c 'import sys; print(sys.version.split()[0])') at $PY"
  "$PY" -m venv --clear "$VENV"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  PIP=("$VENV/bin/python" -m pip install)
fi

echo "==> Downloading the hand-tracking engine"
"${PIP[@]}" "${PACKAGES[@]}"

echo "==> Checking the installation"
check
echo "==> Done"
echo "Python environment ready at: $VENV"
