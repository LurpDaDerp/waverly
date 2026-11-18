#!/bin/bash
# Builds Waverly.app (Release, Apple Silicon) into build/Waverly.app.
#
#   scripts/build.sh                      # ad-hoc signature ("Sign to Run Locally")
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build.sh
#                                         # sign for distribution (then scripts/notarize.sh)
#   SKIP_UV=1 scripts/build.sh            # don't fetch uv (the app then bundles uv only if
#                                         # build/vendor already holds it)
#
# The Google sign-in client comes from macos/Config/Secrets.xcconfig when it exists
# (see Secrets.example.xcconfig); without it the app asks for the user's own client.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:--}"
UV_DIR="build/vendor/uv-aarch64-apple-darwin"
if [ ! -x "$UV_DIR/uv" ] && [ "${SKIP_UV:-0}" != "1" ]; then
  scripts/fetch_uv.sh
fi
# the project lists every Swift file in macos/Sources: regenerate it so new files are built
python3 scripts/gen_xcodeproj.py >/dev/null
ARGS=(-project Waverly.xcodeproj -scheme Waverly -configuration Release -derivedDataPath build/DerivedData
      CODE_SIGN_IDENTITY="$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  ARGS+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
  # the team of a "Developer ID Application: Name (TEAMID)" identity (or $DEVELOPMENT_TEAM)
  TEAM="${DEVELOPMENT_TEAM:-$(printf '%s' "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')}"
  if [ -n "$TEAM" ]; then ARGS+=(DEVELOPMENT_TEAM="$TEAM"); fi
fi
LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild "${ARGS[@]}" build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "build failed (full log: $LOG)"
  exit 1
fi
grep -E "warning:" "$LOG" | grep -v appintents | sort -u || true
APP=build/Waverly.app
rm -rf "$APP"
ditto build/DerivedData/Build/Products/Release/Waverly.app "$APP"
codesign --verify --deep --strict "$APP"
# the bundled runtime must be byte-identical to hud/
R="$APP/Contents/Resources/hud"
diff -r -x __pycache__ -x .DS_Store hud/python/hud "$R/python/hud"
diff -r -x .DS_Store hud/ui "$R/ui"
diff -r -x .DS_Store hud/models "$R/models"
cmp hud/tools/setup_macos.sh "$R/tools/setup_macos.sh"
# the licence texts of everything the app ships (uv's only with uv)
L="$APP/Contents/Resources/Licenses"
cmp LICENSE "$L/LICENSE"
cmp hud/ui/fonts/OFL-Bricolage.txt "$L/OFL-Bricolage.txt"
cmp hud/ui/fonts/OFL-Newsreader.txt "$L/OFL-Newsreader.txt"
for f in macos/Config/Licenses/*; do
  case "$(basename "$f")" in LICENSE-uv-*) [ -x "$APP/Contents/Helpers/uv" ] || continue ;; esac
  cmp "$f" "$L/$(basename "$f")"
done
if [ -x "$APP/Contents/Helpers/uv" ]; then
  codesign --verify --strict "$APP/Contents/Helpers/uv"
  UV_NOTE="bundled uv $(cat "$UV_DIR/.version" 2>/dev/null || echo '?')"
else
  UV_NOTE="no bundled uv"
fi
if [ -n "$(/usr/libexec/PlistBuddy -c 'Print :HUGoogleClientID' "$APP/Contents/Info.plist" 2>/dev/null)" ]; then
  G_NOTE="built-in Google client"
else
  G_NOTE="no built-in Google client"
fi
echo "built $APP ($(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString), signed: $IDENTITY, $UV_NOTE, $G_NOTE)"
