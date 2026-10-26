#!/bin/bash
# Builds "Aether Dev", a side-by-side copy that never touches dist/Aether.app or the installed Aether.
# It has its own bundle id, settings folder (~/Library/Application Support/Aether Dev),
# control port, and process name, so it can be opened, quit, and rebuilt while Aether keeps running.
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode's Swift is new enough for swift-tools-version 6.2. A swiftly toolchain earlier on PATH may not be.
SWIFT="${SWIFT:-/usr/bin/swift}"

"$SWIFT" build -c release

APP="dist-dev/Aether Dev.app"
case "$APP" in dist-dev/*) ;; *) echo "refusing to write outside dist-dev" >&2; exit 1 ;; esac

# Quit only a running dev copy, matched by its own executable path.
pkill -f "dist-dev/Aether Dev.app/Contents/MacOS/AetherDev" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aether "$APP/Contents/MacOS/AetherDev"
cp Info.plist "$APP/Contents/Info.plist"
cp cloud.json "$APP/Contents/Resources/cloud.json" 2>/dev/null || true
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleIdentifier com.ganya.Aether.dev" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleExecutable AetherDev" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleName Aether Dev" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleDisplayName Aether Dev" "$APP/Contents/Info.plist"
$PB -c "Delete :AetherCommit" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
$PB -c "Add :AetherCommit string dev" "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$SWIFT" scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Open it with: open \"$APP\""
