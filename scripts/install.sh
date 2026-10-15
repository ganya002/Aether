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

# Aether needs the macOS 26 SDK. A Swiftly toolchain earlier on PATH, such as
# Swift 6.1, is too old even when the Command Line Tools are new enough.
swift_version() {
  "$1" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1
}

version_at_least() {
  local IFS=.
  local i av bv
  local -a got=($1) need=($2)
  for ((i = 0; i < 3; i++)); do
    av=${got[i]:-0}
    bv=${need[i]:-0}
    if ((10#$av > 10#$bv)); then return 0; fi
    if ((10#$av < 10#$bv)); then return 1; fi
  done
  return 0
}

pick_swift() {
  local candidate version
  local -a candidates=()
  if command -v xcrun >/dev/null 2>&1; then
    candidate="$(xcrun --find swift 2>/dev/null || true)"
    [[ -n "$candidate" ]] && candidates+=("$candidate")
  fi
  candidates+=(/usr/bin/swift)
  if command -v swift >/dev/null 2>&1; then
    candidates+=("$(command -v swift)")
  fi
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    version="$(swift_version "$candidate")"
    if [[ -n "$version" ]] && version_at_least "$version" 6.2; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

SWIFT="$(pick_swift || true)"
if [[ -z "$SWIFT" ]]; then
  echo "Aether needs Swift 6.2 or newer, with the macOS 26 SDK."
  echo "The swift on your PATH is $(swift_version "$(command -v swift)") ($(command -v swift))."
  echo "Install the Xcode Command Line Tools, or run: swiftly install 6.2"
  exit 1
fi
export PATH="$(dirname "$SWIFT"):$PATH"

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
