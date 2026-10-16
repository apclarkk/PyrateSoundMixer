#!/bin/zsh
# Builds Pyrate Sounds and assembles an ad-hoc signed app bundle in build/.
#
# Usage: scripts/build-app.sh [debug|release] [--open] [--install]
#   --open      quit any running copy and launch the freshly built app
#   --install   copy the app to /Applications and launch it from there
# Default configuration: release.
set -euo pipefail

CONFIG=release
OPEN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --open) OPEN=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

ROOT="${0:A:h:h}"
APP="$ROOT/build/Pyrate Sounds.app"
INSTALLED="/Applications/Pyrate Sounds.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PyrateSounds"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PyrateSounds"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature for local use. Distribution needs a Developer ID and notarization.
codesign --force --sign - --options runtime "$APP"
echo "Built: $APP"

quit_running() {
  # Quit any running copy (from build/ or /Applications) and wait for it to exit;
  # opening while it is still terminating fails with LaunchServices error -600.
  osascript -e 'tell application id "org.pyratesounds.PyrateSounds" to quit' 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -f "MacOS/PyrateSounds" >/dev/null || break
    sleep 0.1
  done
  pkill -f "MacOS/PyrateSounds" 2>/dev/null || true
}

if (( INSTALL )); then
  quit_running
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  # Register the installed copy and forget the build/ one, so Finder, Spotlight,
  # and pyratesounds:// links all resolve to /Applications.
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  "$LSREGISTER" -f "$INSTALLED"
  echo "Installed: $INSTALLED"
  open "$INSTALLED"
elif (( OPEN )); then
  quit_running
  open "$APP"
fi
