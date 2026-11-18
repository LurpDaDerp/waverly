#!/bin/bash
# Renders Waverly's icons from their SVG sources in design/icon/:
#
#   AppIcon.svg      -> AppIcon-1024.png and AppIcon.icns (16…1024 px)
#   MenuBarIcon.svg  -> MenuBarIcon.png (18 px) and MenuBarIcon@2x.png (36 px), black on clear:
#                       the menu bar item draws it as a template image
#
# and installs them in macos/Config/ (AppIcon.icns, AppIcon.png, MenuBarIcon.png,
# MenuBarIcon@2x.png), where the Xcode project picks them up.
#
#   scripts/make_icons.sh              # renders into design/icon/ and installs
#   scripts/make_icons.sh <out-dir>    # renders into <out-dir> only (to compare; nothing installed)
#
# Development requirement: Google Chrome (headless, renders the SVGs exactly as a
# browser does: gradients, blur filters, drop shadows). Set CHROME=/path/to/chrome for
# another copy. sips and iconutil come with macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=design/icon
OUT="${1:-$SRC}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Google Chrome is needed to render the SVGs (not found at $CHROME; set CHROME=…)" >&2; exit 1; }
for f in AppIcon.svg MenuBarIcon.svg; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render <svg> <size> <out.png>: the SVG at its own size (its width/height), on a clear background
render() {
  local svg size out
  svg="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  size="$2"
  out="$3"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --force-device-scale-factor=1 --window-size="$size,$size" --user-data-dir="$WORK/chrome" \
    --screenshot="$out" "file://$svg" >/dev/null 2>&1
  local got
  got=$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null | awk '/pixel/ {print $2}' | tr '\n' 'x')
  [ "$got" = "${size}x${size}x" ] || { echo "Chrome rendered $1 at ${got%x}, not ${size}x${size}" >&2; exit 1; }
}

# the app icon: 1024 px, then every size of the .icns scaled down from it
render "$SRC/AppIcon.svg" 1024 "$WORK/AppIcon-1024.png"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
            512:512x512 1024:512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$WORK/AppIcon-1024.png" --out "$SET/icon_${spec#*:}.png" >/dev/null
done
iconutil -c icns "$SET" -o "$WORK/AppIcon.icns"

# the menu bar icon: drawn at 360 px (its SVG size), scaled to 18 and 36 px
render "$SRC/MenuBarIcon.svg" 360 "$WORK/MenuBarIcon-360.png"
sips -z 18 18 "$WORK/MenuBarIcon-360.png" --out "$WORK/MenuBarIcon.png" >/dev/null
sips -z 36 36 "$WORK/MenuBarIcon-360.png" --out "$WORK/MenuBarIcon@2x.png" >/dev/null

for f in AppIcon-1024.png AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do cp "$WORK/$f" "$OUT/$f"; done
echo "rendered $OUT/{AppIcon-1024.png,AppIcon.icns,MenuBarIcon.png,MenuBarIcon@2x.png}"
if [ $# -eq 0 ]; then
  cp "$OUT/AppIcon.icns" macos/Config/AppIcon.icns
  cp "$OUT/AppIcon-1024.png" macos/Config/AppIcon.png
  cp "$OUT/MenuBarIcon.png" "$OUT/MenuBarIcon@2x.png" macos/Config/
  echo "installed in macos/Config/ (rebuild the app to use them)"
fi
