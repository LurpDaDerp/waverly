#!/bin/bash
# Downloads the pinned uv release that Waverly bundles (Contents/Helpers/uv), so the
# first-run setup works on a Mac without Python: uv installs its own Python 3.12.
#
#   scripts/fetch_uv.sh        -> build/vendor/uv-aarch64-apple-darwin/uv
#
# The archive's SHA-256 is pinned below (from the release's published .sha256);
# a mismatch stops the script and nothing is extracted. To update uv, change
# UV_VERSION and UV_SHA256 together, and refresh uv's licence texts that ship with
# the app (macos/Config/Licenses/LICENSE-uv-*.txt, from the same release tag).
set -euo pipefail
cd "$(dirname "$0")/.."
UV_VERSION="0.13.8"
UV_SHA256="6b71028a6b904f2ae3340ef52e595512de807d06c0a20eaef2f692581b246558"
NAME="uv-aarch64-apple-darwin"
URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${NAME}.tar.gz"
VENDOR="build/vendor"
ARCHIVE="${VENDOR}/${NAME}-${UV_VERSION}.tar.gz"
OUT="${VENDOR}/${NAME}"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$VENDOR"
if [ -x "$OUT/uv" ] && [ -f "$OUT/.version" ] && [ "$(cat "$OUT/.version")" = "$UV_VERSION" ]; then
  echo "uv $UV_VERSION already in $OUT"
  exit 0
fi
# an archive downloaded by hand as build/vendor/uv.tar.gz is used when its checksum matches
if [ ! -f "$ARCHIVE" ] && [ -f "$VENDOR/uv.tar.gz" ] && [ "$(sha "$VENDOR/uv.tar.gz")" = "$UV_SHA256" ]; then
  cp "$VENDOR/uv.tar.gz" "$ARCHIVE"
fi
if [ ! -f "$ARCHIVE" ] || [ "$(sha "$ARCHIVE")" != "$UV_SHA256" ]; then
  echo "downloading uv $UV_VERSION"
  rm -f "$ARCHIVE.part"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error -o "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
GOT=$(sha "$ARCHIVE")
if [ "$GOT" != "$UV_SHA256" ]; then
  echo "SHA-256 mismatch for $ARCHIVE" >&2
  echo "  expected $UV_SHA256" >&2
  echo "  got      $GOT" >&2
  rm -f "$ARCHIVE"
  exit 1
fi
rm -rf "$OUT" "$OUT.tmp"
mkdir -p "$OUT.tmp"
tar -xzf "$ARCHIVE" -C "$OUT.tmp"
# the archive holds uv-aarch64-apple-darwin/{uv,uvx}
[ -x "$OUT.tmp/$NAME/uv" ] || { echo "unexpected archive layout: no $NAME/uv" >&2; rm -rf "$OUT.tmp"; exit 1; }
mv "$OUT.tmp/$NAME" "$OUT"
rm -rf "$OUT.tmp"
echo "$UV_VERSION" > "$OUT/.version"
echo "uv $UV_VERSION ready: $OUT/uv"
