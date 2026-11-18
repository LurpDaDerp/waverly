#!/bin/bash
# Builds, signs, notarizes and staples a Waverly release for distribution outside
# the Mac App Store (needs a paid Apple Developer account).
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com).
#   2. Store notarytool credentials in the keychain under a profile name:
#        xcrun notarytool store-credentials Waverly \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#
# Then:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/notarize.sh
#   NOTARY_PROFILE=Waverly (default) names the stored credentials.
#
# Steps: build.sh (Developer ID + hardened runtime + secure timestamp, bundled uv
# signed the same way) -> notarize the app -> staple it -> make_dmg.sh (signed) ->
# notarize the disk image -> staple it -> Gatekeeper check.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
[ "$SIGN_IDENTITY" != "-" ] || { echo "notarization needs a Developer ID identity, not ad-hoc (-)"; exit 1; }
PROFILE="${NOTARY_PROFILE:-Waverly}"
APP=build/Waverly.app

export SIGN_IDENTITY
scripts/build.sh
[ -x "$APP/Contents/Helpers/uv" ] || { echo "a release must bundle uv: run scripts/fetch_uv.sh, then try again"; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== notarizing the app"
ZIP=$(mktemp -d)/Waverly.zip
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"

echo "== disk image"
scripts/make_dmg.sh
VER=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
DMG="dist/Waverly-$VER.dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "== Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "ready to ship: $DMG"
