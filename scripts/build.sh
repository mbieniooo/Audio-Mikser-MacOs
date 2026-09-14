#!/bin/bash
# Builds Mikser with SwiftPM, assembles build/Mikser.app and signs it with "Mikser Dev".
# Usage: scripts/build.sh [--debug]     env MIKSER_VERSION=x.y.z overrides the version string.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Mikser Dev"
CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then CONFIG="debug"; fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "run scripts/make-cert.sh first"
  exit 1
fi

if [[ "$CONFIG" == "release" ]]; then swift build -c release; else swift build; fi

APP="build/Mikser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Mikser" "$APP/Contents/MacOS/Mikser"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -n "${MIKSER_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MIKSER_VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --sign "$IDENTITY" --identifier com.mieszko.mikser --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature|TeamIdentifier)" || true
echo "built $APP ($CONFIG)"
