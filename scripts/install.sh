#!/bin/bash
# Installs build/Mikser.app into /Applications (or ~/Applications) and launches it.
# Usage: scripts/install.sh [--no-build] [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
DEBUG_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --debug) DEBUG_FLAG="--debug" ;;
  esac
done
if [[ "$BUILD" == 1 ]]; then scripts/build.sh $DEBUG_FLAG; fi

SRC="build/Mikser.app"
[[ -d "$SRC" ]] || { echo "missing $SRC (run scripts/build.sh)"; exit 1; }

DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
DEST="$DEST_DIR/Mikser.app"

if [[ -e "$DEST" ]]; then
  # capture first: `grep -q` under pipefail would close the pipe early and fail the check
  SIGINFO="$(codesign -dv "$DEST" 2>&1 || true)"
  if ! grep -q "^Identifier=com.mieszko.mikser$" <<<"$SIGINFO"; then
    echo "refusing to replace $DEST: it is not a Mikser bundle"
    exit 1
  fi
fi

if pgrep -x Mikser >/dev/null; then
  osascript -e 'tell application id "com.mieszko.mikser" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Mikser >/dev/null || break; sleep 0.5; done
  pgrep -x Mikser >/dev/null && pkill -x Mikser || true
  sleep 0.5
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
open -a "$DEST"
echo "installed and launched $DEST"
