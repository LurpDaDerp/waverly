#!/bin/bash
# Automated checks for a built Waverly.app (the parts that need no person in front of the camera):
#   1. the bundled runtime is byte-identical to hud/ and the signature is valid
#   2. the gesture-engine, hud-core list, task check-off (with the page in headless Chrome, when
#      installed) and frame-ring tests pass against the code inside the bundle
#   3. the calibration clips replay through the real MediaPipe pipeline (when present)
# Usage: scripts/verify.sh [path/to/Waverly.app]     (default build/Waverly.app)
#        PY=/path/to/venv/bin/python scripts/verify.sh   (another Python environment)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Waverly.app}"
PY="${PY:-$HOME/Library/Application Support/Waverly/venv/bin/python}"
[ -x "$PY" ] || { echo "no Python environment yet: open Waverly once (or run hud/tools/setup_macos.sh)"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PYTHONPYCACHEPREFIX="$TMP/pycache"

echo "== bundle"
codesign --verify --deep --strict "$APP" && echo "signature valid"
R="$APP/Contents/Resources/hud"
if diff -r -x __pycache__ -x .DS_Store hud/python/hud "$R/python/hud" && diff -r -x .DS_Store hud/ui "$R/ui" \
  && diff -r -x .DS_Store hud/models "$R/models" && cmp hud/tools/setup_macos.sh "$R/tools/setup_macos.sh"; then
  echo "bundled runtime identical to hud/"
else
  echo "FAIL: the bundled runtime differs from hud/ (rebuild with scripts/build.sh)"; exit 1
fi
[ -e "$R/config.json" ] && { echo "unexpected: a config.json is bundled"; exit 1; }
L="$APP/Contents/Resources/Licenses"
want=(LICENSE OFL-Bricolage.txt OFL-Newsreader.txt LICENSE-Phosphor.txt NOTICE-MediaPipe-models.txt)
[ -x "$APP/Contents/Helpers/uv" ] && want+=(LICENSE-uv-APACHE.txt LICENSE-uv-MIT.txt)
for f in "${want[@]}"; do [ -s "$L/$f" ] || { echo "FAIL: missing licence text Licenses/$f"; exit 1; }; done
cmp -s LICENSE "$L/LICENSE" || { echo "FAIL: Licenses/LICENSE differs from LICENSE"; exit 1; }
echo "licence texts present (${#want[@]} in Contents/Resources/Licenses)"
if [ -x "$APP/Contents/Helpers/uv" ]; then
  codesign --verify --strict "$APP/Contents/Helpers/uv" && echo "bundled uv signed"
else
  echo "note: no bundled uv (scripts/fetch_uv.sh)"
fi

echo "== tests (bundled code)"
mkdir -p "$TMP/t/tests"
ln -s "$PWD/$R/python" "$TMP/t/python"
for t in test_gestures.py test_core_lists.py test_tasks_complete.py test_page_tasks.py test_page_perf.py test_framering.py test_engine_settings.py test_parent_watch.py; do
  [ -f "hud/tests/$t" ] || continue
  cp "hud/tests/$t" "$TMP/t/tests/"
  if out=$(cd "$TMP/t" && "$PY" "tests/$t" 2>&1); then
    echo "$t: $(printf '%s\n' "$out" | tail -1)"
  else
    printf '%s\n' "$out" | tail -40
    echo "FAIL: $t"; exit 1
  fi
done

echo "== replay (MediaPipe on the calibration clips)"
if [ -f hud/calibration/scroll-strokes.mov ]; then
  (cd hud && HUD_MODELS="$PWD/models" "$PY" tools/replay_video.py calibration/scroll-strokes.mov 2>/dev/null | grep -v '^openness')
  (cd hud && HUD_MODELS="$PWD/models" "$PY" tools/replay_video.py calibration/waving.mov --asleep 2>/dev/null | grep '^events')
else
  echo "(calibration clips not present; skipped)"
fi
