#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT="${SWIFT:-swift}"
"$SWIFT" build -c release

APP="dist/Aether.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aether "$APP/Contents/MacOS/Aether"
cp Info.plist "$APP/Contents/Info.plist"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo dev)"
/usr/libexec/PlistBuddy -c "Delete :AetherCommit" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :AetherCommit string $COMMIT" "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$SWIFT" scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "Built $APP"
