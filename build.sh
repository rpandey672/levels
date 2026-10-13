#!/bin/bash
# Builds Levels.app. Run:  ./build.sh            (builds into ./build)
#                         ./build.sh --install  (also copies to /Applications and opens it)
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Run:  xcode-select --install   then try again." >&2
  exit 1
fi

APP="build/Levels.app"
ARCH="$(uname -m)"   # arm64 or x86_64

echo "-> Compiling for ${ARCH}..."
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -wmo -swift-version 5 -parse-as-library \
  -target "${ARCH}-apple-macos14.2" \
  -framework CoreAudio -framework AppKit -framework ServiceManagement \
  -Xlinker -dead_strip \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Levels"
strip -x "$APP/Contents/MacOS/Levels"

cp Info.plist "$APP/Contents/Info.plist"

# a real signing identity keeps the audio recording permission across rebuilds.
# ad-hoc signatures change every build and macOS forgets the grant.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NF>1 {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  echo "-> Signing as $IDENTITY..."
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "-> Signing (ad-hoc, macOS will ask for audio permission again)..."
  codesign --force --sign - "$APP"
fi

echo "OK: Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Levels 2>/dev/null || true
  rm -rf /Applications/Levels.app
  cp -R "$APP" /Applications/
  open /Applications/Levels.app
  echo "OK: Installed to /Applications and launched - look for the slider icon in the menu bar."
fi
