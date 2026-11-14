#!/usr/bin/env bash
# Vendors the pure-Python packages the library runs into Sources/YTDLP/Resources/python-packages:
# yt-dlp, yt-dlp-ejs (YouTube challenge solver scripts) and certifi (CA certificates: the
# embedded Python can't read the Apple keychain). Pinned and checksum-verified.
#
#   scripts/vendor-python-packages.sh [download-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YTDLP_VERSION="2026.10.26"
YTDLP_SHA="21f942d258d25cc4e60b4982a25c423460f0bebb835f38e6dfd1fcb140087f95"
EJS_VERSION="0.8.0"
EJS_SHA="79300e5fca7f937a1eeede11f0456862c1b41107ce1d726871e0207424f4bdb4"
CERTIFI_URL="https://files.pythonhosted.org/packages/32/d1/a3652fe2c19134d0d15922177821d863cbd7e842d53a21bbe7e8e3a1b5ac/certifi-2026.10.23-py3-none-any.whl"
CERTIFI_SHA="e9b54de76e530bb6cf0ccd036787103acb58fd42ba930ea8bf948ddbaa2f61d1"

SRC="${1:-$ROOT/.build/python-download}"
mkdir -p "$SRC"
fetch() { [ -f "$SRC/$2" ] || curl -fL -o "$SRC/$2" "$1"; echo "$3  $SRC/$2" | shasum -a 256 -c -; }
fetch "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp.tar.gz" yt-dlp.tar.gz "$YTDLP_SHA"
fetch "https://github.com/yt-dlp/ejs/releases/download/$EJS_VERSION/yt_dlp_ejs-$EJS_VERSION-py3-none-any.whl" "yt_dlp_ejs-$EJS_VERSION-py3-none-any.whl" "$EJS_SHA"
fetch "$CERTIFI_URL" "$(basename "$CERTIFI_URL")" "$CERTIFI_SHA"

DEST="$ROOT/Sources/YTDLP/Resources/python-packages"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$SRC/yt-dlp.tar.gz" -C "$WORK"
(cd "$WORK" && unzip -q "$SRC/yt_dlp_ejs-$EJS_VERSION-py3-none-any.whl" && unzip -q -o "$SRC/$(basename "$CERTIFI_URL")")
rm -rf "$DEST/yt_dlp" "$DEST/yt_dlp_ejs" "$DEST/certifi"
mkdir -p "$DEST"
cp -R "$WORK/yt-dlp/yt_dlp" "$WORK/yt_dlp_ejs" "$WORK/certifi" "$DEST/"
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} +
# yt-dlp's Shahid extractor carries that site's public AWS app keys; GitHub push protection
# rejects them as secrets. Blank them (only Shahid stops working).
perl -pi -e "s/(_AWS_API_KEY = )'[^']*'/\$1''/; s/('(?:secret|access)_key': )'[^']*'/\$1''/" "$DEST/yt_dlp/extractor/shahid.py"
# Their licenses travel with them.
mkdir -p "$ROOT/LICENSES"
cp "$WORK/yt-dlp/LICENSE" "$ROOT/LICENSES/yt-dlp.txt"
cp "$WORK"/yt_dlp_ejs-*.dist-info/licenses/LICENSE "$ROOT/LICENSES/yt-dlp-ejs.txt"
find "$WORK" -path '*certifi-*.dist-info*' -name 'LICENSE*' -exec cp {} "$ROOT/LICENSES/certifi.txt" \;
printf 'yt-dlp %s\nyt-dlp-ejs %s\ncertifi %s\n' "$YTDLP_VERSION" "$EJS_VERSION" "2026.10.23" > "$DEST/VERSIONS"
echo "vendored into $DEST"; cat "$DEST/VERSIONS"
