#!/bin/bash
# Install and launch Aether.
#   curl -fsSL https://raw.githubusercontent.com/ganya002/Aether/main/scripts/install.sh | bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Aether is a macOS app."
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "Aether needs the Xcode Command Line Tools. An installer window should open."
  xcode-select --install || true
  echo "When that finishes, run the same curl command again."
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "Downloading Aether…"
curl -fsSL "https://github.com/ganya002/Aether/archive/refs/heads/main.tar.gz" | tar -xz -C "$WORKDIR"
SRC="$WORKDIR/Aether-main"
if [[ ! -d "$SRC" ]]; then
  echo "The download did not include the Aether source."
  exit 1
fi

echo "Building Aether… this can take a minute the first time."
"$SRC/scripts/build-app.sh"

DEST="$HOME/Downloads/Aether.app"
rm -rf "$DEST"
cp -R "$SRC/dist/Aether.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --sign - "$DEST/Contents/MacOS/Aether"
codesign --force --sign - "$DEST"

echo "Opening Aether from Downloads. Drag it into Applications when asked."
open "$DEST"
open -R "$DEST"
