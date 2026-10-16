#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT="${SWIFT:-swift}"

# A log path means the installer is driving the build and drawing its own progress.
# script keeps Swift's output in that file, including live [3/20] lines, and off the terminal.
run_swift() {
  if [[ -n "${AETHER_BUILD_LOG:-}" ]]; then
    if [[ -s "$AETHER_BUILD_LOG" ]]; then
      script -a -q "$AETHER_BUILD_LOG" "$SWIFT" "$@" >/dev/null
    else
      script -q "$AETHER_BUILD_LOG" "$SWIFT" "$@" >/dev/null
    fi
  else
    "$SWIFT" "$@"
  fi
}

run_swift build -c release

APP="dist/Aether.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aether "$APP/Contents/MacOS/Aether"
cp Info.plist "$APP/Contents/Info.plist"
cp cloud.json "$APP/Contents/Resources/cloud.json"
# The GitHub tarball has no .git directory. The installer passes the commit it downloaded.
if [[ -n "${AETHER_COMMIT:-}" ]]; then
  COMMIT="$AETHER_COMMIT"
else
  COMMIT="$(git rev-parse HEAD 2>/dev/null || echo dev)"
fi
/usr/libexec/PlistBuddy -c "Delete :AetherCommit" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :AetherCommit string $COMMIT" "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
run_swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ -z "${AETHER_BUILD_LOG:-}" ]]; then
  echo "Built $APP"
fi
