#!/bin/bash
# Packs build/Waverly.app into dist/Waverly-<version>.dmg: a drag-and-drop install window
# (Waverly on the left, an Applications shortcut on the right, the sunset background
# from make_dmg_background.swift), no other files. Builds the app first if needed.
#
#   scripts/make_dmg.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/make_dmg.sh   # also signs the image
#
# The window is laid out by dmgbuild (pip, in a throwaway venv under build/), without
# scripting Finder. Layout values match make_dmg_background.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Waverly.app
[ -d "$APP" ] || scripts/build.sh
VER=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)

VENV=build/dmgbuild-venv
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "setting up dmgbuild in $VENV"
  rm -rf "$VENV"
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check "dmgbuild==1.6.5"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift scripts/make_dmg_background.swift "$WORK" >/dev/null
# one TIFF with both resolutions: Finder picks the sharp one on Retina screens
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

cat > "$WORK/settings.py" <<'EOF'
import os.path
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volicon"]
background = defines["background"]
format = "ULFO"                      # lzfse; macOS 10.11 or newer
filesystem = "HFS+"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
default_view = "icon-view"
window_rect = ((200, 160), (640, 400))
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {os.path.basename(app): (170, 175), "Applications": (470, 175)}
EOF

mkdir -p dist
DMG="dist/Waverly-$VER.dmg"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$WORK/settings.py" \
  -D app="$PWD/$APP" -D volicon="$PWD/$APP/Contents/Resources/AppIcon.icns" -D background="$WORK/background.tiff" \
  "Waverly" "$DMG" >/dev/null
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify "$DMG" >/dev/null 2>&1
echo "wrote $DMG ($(du -h "$DMG" | cut -f1))"
