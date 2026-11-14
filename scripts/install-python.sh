#!/bin/bash
# Xcode "Run Script" build phase for iOS/iPadOS apps that use the YTDLP library.
#
# iOS apps can't contain a loose Python standard library with .so files, so this copies it into
# <App>.app/python and turns every binary module into a signed framework (BeeWare's
# Python.xcframework/build/utils.sh does the work). macOS needs nothing: the framework carries it.
#
# Add it after "Copy Bundle Resources", e.g. with XcodeGen:
#   postBuildScripts:
#     - name: Install Python for yt-dlp
#       script: '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/ytdlp-apple/scripts/install-python.sh"'
#       basedOnDependencyAnalysis: false
#
# Set YTDLP_PYTHON_XCFRAMEWORK to the xcframework's path if it isn't found automatically.
set -euo pipefail
case "${PLATFORM_NAME:-}" in
  iphoneos|iphonesimulator) ;;
  *) echo "install-python: nothing to do for ${PLATFORM_NAME:-unknown}"; exit 0 ;;
esac

XCF="${YTDLP_PYTHON_XCFRAMEWORK:-}"
if [ -z "$XCF" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  PACKAGES="${BUILD_DIR%/Build/*}/SourcePackages"
  for candidate in \
      "$PACKAGES/artifacts/ytdlp-apple/Python/Python.xcframework" \
      "$PACKAGES/artifacts/ytdlp-apple/Python.xcframework" \
      "$HERE/Frameworks/Python.xcframework"; do
    if [ -f "$candidate/build/utils.sh" ]; then XCF="$candidate"; break; fi
  done
fi
if [ -z "$XCF" ] || [ ! -f "$XCF/build/utils.sh" ]; then
  echo "error: Python.xcframework for yt-dlp not found (resolve packages first, or set YTDLP_PYTHON_XCFRAMEWORK)" >&2
  exit 1
fi
echo "install-python: using $XCF"
# BeeWare's helpers resolve the xcframework relative to PROJECT_DIR.
(
  PROJECT_DIR="$(dirname "$XCF")"
  # shellcheck disable=SC1091
  source "$XCF/build/utils.sh"
  install_python "$(basename "$XCF")"
)
