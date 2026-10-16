#!/bin/zsh
# Builds Pyrate Sounds and assembles an ad-hoc signed app bundle in build/.
# Usage: scripts/build-app.sh [debug|release] [--open]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
[[ "$CONFIG" == "--open" ]] && CONFIG=release
ROOT="${0:A:h:h}"
APP="$ROOT/build/Pyrate Sounds.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PyrateSounds"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PyrateSounds"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature for local use. Distribution needs a Developer ID and notarization.
codesign --force --sign - --options runtime "$APP"

echo "Built: $APP"

if [[ "${2:-}" == "--open" || "${1:-}" == "--open" ]]; then
  # Quit any running copy and wait for it to exit; opening while it is still
  # terminating fails with LaunchServices error -600.
  osascript -e 'tell application id "org.pyratesounds.PyrateSounds" to quit' 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -f "MacOS/PyrateSounds" >/dev/null || break
    sleep 0.1
  done
  pkill -f "MacOS/PyrateSounds" 2>/dev/null || true
  open "$APP"
fi
