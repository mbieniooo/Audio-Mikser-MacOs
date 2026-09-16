#!/bin/bash
# Builds Mikser with SwiftPM, assembles build/Mikser.app and signs it with "Mikser Dev".
# Usage: scripts/build.sh [--debug]     env MIKSER_VERSION=x.y.z overrides the version string.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Mikser Dev"
BUNDLE_ID="$(sed -n 's/.*static let bundle = "\([^"]*\)".*/\1/p' Sources/MikserCore/Types.swift)"
[[ -n "$BUNDLE_ID" ]] || { echo "MikserID.bundle not found in Sources/MikserCore/Types.swift"; exit 1; }
CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then CONFIG="debug"; fi

IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -q "\"$IDENTITY\"" <<<"$IDS"; then
  echo "run scripts/make-cert.sh first"
  exit 1
fi

if [[ "$CONFIG" == "release" ]]; then swift build -c release; else swift build; fi
".build/$CONFIG/mikser-selftest" > /dev/null || { echo "self-test failed in $CONFIG"; ".build/$CONFIG/mikser-selftest" | grep FAIL; exit 1; }

APP="build/Mikser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Mikser" "$APP/Contents/MacOS/Mikser"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp "Resources/Mikser.icns" "$APP/Contents/Resources/Mikser.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -n "${MIKSER_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MIKSER_VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature|TeamIdentifier)" || true
echo "built $APP ($CONFIG)"
