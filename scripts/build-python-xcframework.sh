#!/usr/bin/env bash
# Builds Frameworks/Python.xcframework (iOS device + simulator + macOS) from BeeWare's
# Python-Apple-support releases, and dist/Python.xcframework.zip for the GitHub release
# that Package.swift points at.
#
#   scripts/build-python-xcframework.sh            # downloads the pinned release
#   scripts/build-python-xcframework.sh <dir>      # uses tarballs already in <dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="3.14-b14"
IOS_TGZ="Python-3.14-iOS-support.b14.tar.gz"
MAC_TGZ="Python-3.14-macOS-support.b14.tar.gz"
IOS_SHA="703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee"
MAC_SHA="4475ee12ea9e4bcba8bc2a74c9ab9c179bb240bb84d46eb4523dbc05c7d00d72"

SRC="${1:-$ROOT/.build/python-download}"
mkdir -p "$SRC"
for f in "$IOS_TGZ" "$MAC_TGZ"; do
  [ -f "$SRC/$f" ] || curl -fL -o "$SRC/$f" "https://github.com/beeware/Python-Apple-support/releases/download/$TAG/$f"
done
echo "$IOS_SHA  $SRC/$IOS_TGZ" | shasum -a 256 -c -
echo "$MAC_SHA  $SRC/$MAC_TGZ" | shasum -a 256 -c -

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/ios" "$WORK/mac"
tar -xzf "$SRC/$IOS_TGZ" -C "$WORK/ios"
tar -xzf "$SRC/$MAC_TGZ" -C "$WORK/mac"

OUT="$ROOT/Frameworks/Python.xcframework"
rm -rf "$OUT"
# Start from the iOS xcframework: besides the frameworks it carries the standard library
# (lib/, lib-arm64/…) and build/utils.sh, which the app's build phase uses to install it.
cp -R "$WORK/ios/Python.xcframework" "$OUT"
cp -R "$WORK/mac/Python.xcframework/macos-arm64_x86_64" "$OUT/"

# Add the macOS slice to the xcframework's Info.plist.
/usr/bin/python3 - "$OUT/Info.plist" "$WORK/mac/Python.xcframework/Info.plist" <<'PY'
import plistlib, sys
out, mac = sys.argv[1], sys.argv[2]
with open(out, "rb") as f: p = plistlib.load(f)
with open(mac, "rb") as f: m = plistlib.load(f)
p["AvailableLibraries"] += [l for l in m["AvailableLibraries"] if l["SupportedPlatform"] == "macos"]
with open(out, "wb") as f: plistlib.dump(p, f)
PY

mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/Python.xcframework.zip"
(cd "$ROOT/Frameworks" && ditto -c -k --sequesterRsrc --keepParent Python.xcframework "$ROOT/dist/Python.xcframework.zip")
echo "checksum: $(swift package --package-path "$ROOT" compute-checksum "$ROOT/dist/Python.xcframework.zip" 2>/dev/null || shasum -a 256 "$ROOT/dist/Python.xcframework.zip" | cut -d' ' -f1)"
