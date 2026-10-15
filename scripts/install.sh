#!/bin/bash
# Install and launch Aether.
#   curl -fsSL https://raw.githubusercontent.com/ganya002/Aether/main/scripts/install.sh | bash
set -euo pipefail

RETRY='curl -fsSL https://raw.githubusercontent.com/ganya002/Aether/main/scripts/install.sh | bash'
ARCHIVE_URL='https://github.com/ganya002/Aether/archive/refs/heads/main.tar.gz'
LOG="${TMPDIR:-/tmp}/aether-install.log"
: >"$LOG"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_DIM=$'\033[2m'
  C_OFF=$'\033[0m'
  C_OK=$'\033[32m'
  C_BAD=$'\033[31m'
  C_BOLD=$'\033[1m'
else
  C_DIM=''
  C_OFF=''
  C_OK=''
  C_BAD=''
  C_BOLD=''
fi

bar_open=0
spin_i=0
last_line_pct='-'
spin_frames='|/-'

finish_bar() {
  if [[ "$bar_open" -eq 1 ]]; then
    printf '\r\033[K'
    bar_open=0
  fi
}

draw_bar() {
  local label="$1"
  local pct="$2"
  local width=22
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  local i mark=''
  bar_open=1
  for ((i = 0; i < filled; i++)); do mark+='█'; done
  local rest=''
  for ((i = 0; i < empty; i++)); do rest+='░'; done
  if [[ -t 1 ]]; then
    printf '\r  %-12s %b%s%b%s%b  %3d%%' "$label" "$C_BOLD" "$mark" "$C_DIM" "$rest" "$C_OFF" "$pct"
  elif [[ "$label$pct" != "$last_line_pct" ]]; then
    last_line_pct="$label$pct"
    printf '  %s %d%%\n' "$label" "$pct"
  fi
}

draw_spin() {
  local label="$1"
  local frame="${spin_frames:spin_i:1}"
  spin_i=$(((spin_i + 1) % ${#spin_frames}))
  bar_open=1
  if [[ -t 1 ]]; then
    printf '\r  %-12s %b%s%b working' "$label" "$C_BOLD" "$frame" "$C_OFF"
  fi
}

step_done() {
  local label="$1"
  finish_bar
  printf '  %b✓%b  %s\n' "$C_OK" "$C_OFF" "$label"
}

die() {
  local title="$1"
  local detail="$2"
  local command="${3:-}"
  finish_bar
  printf '\n  %b✗%b  %s\n\n' "$C_BAD" "$C_OFF" "$title"
  printf '  %s\n' "$detail"
  if [[ -n "$command" ]]; then
    printf '\n  Run:\n\n    %b%s%b\n' "$C_BOLD" "$command" "$C_OFF"
  fi
  printf '\n'
  exit 1
}

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

major_of() {
  printf '%s\n' "${1%%.*}"
}

explain_build() {
  local excerpt=''
  if [[ -f "$LOG" ]]; then
    excerpt=$(grep -E 'error:' "$LOG" | grep -v 'warning:' | sed -E 's/^.*error: /error: /' | awk '!seen[$0]++' | head -3 || true)
  fi
  if grep -q 'No space left on device' "$LOG" 2>/dev/null; then
    die "The disk filled up while building." \
      "Free about 2 GB, then install again." \
      "$RETRY"
  fi
  if grep -q 'unable to load standard library' "$LOG" 2>/dev/null; then
    die "Swift can't see the macOS SDK." \
      "The Command Line Tools look incomplete. Remove them, install them again, then run the installer again." \
      "sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
  fi
  if grep -qE 'no developer tools were found|xcode-select: error|unable to find utility' "$LOG" 2>/dev/null; then
    die "The Xcode Command Line Tools are missing." \
      "Install them, wait for that to finish, then run the installer again." \
      "xcode-select --install"
  fi
  if grep -q 'clang: error: linker command failed' "$LOG" 2>/dev/null; then
    die "The linker failed." \
      "Reinstall the Command Line Tools, then run the installer again." \
      "xcode-select --install"
  fi
  if [[ -z "$excerpt" ]]; then
    excerpt="The compiler stopped without a clear error. The log is at $LOG."
  else
    excerpt="$excerpt

The log is at $LOG."
  fi
  die "The build failed." \
    "$excerpt" \
    "xcode-select --install"
}

printf '\n  %bAether%b\n\n' "$C_BOLD" "$C_OFF"

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "Aether is a macOS app." "Run the installer on a Mac."
fi

draw_bar "Checking" 20

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "The Xcode Command Line Tools are not installed." \
    "An installer window should have opened. When it finishes, run the installer again." \
    "$RETRY"
fi

draw_bar "Checking" 45
os_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
os_major="$(major_of "$os_version")"
if [[ "${os_major:-0}" -lt 26 ]]; then
  die "Aether needs macOS 26 or newer." \
    "This Mac is on macOS $os_version. Update it in System Settings → General → Software Update, then run the installer again." \
    "$RETRY"
fi

draw_bar "Checking" 70
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
sdk_major="$(major_of "$sdk_version")"
if [[ "${sdk_major:-0}" -lt 26 ]]; then
  die "The macOS 26 SDK is not installed." \
    "The Command Line Tools on this Mac are for an older system. Remove them, install the current ones, then run the installer again." \
    "sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
fi

draw_bar "Checking" 90
SWIFT="$(pick_swift || true)"
if [[ -z "$SWIFT" ]]; then
  have="$(swift_version "$(command -v swift 2>/dev/null || echo /usr/bin/swift)" 2>/dev/null || true)"
  if [[ -n "$have" ]]; then
    detail="This Mac has Swift $have. Aether needs Swift 6.2 or newer."
  else
    detail="Aether needs Swift 6.2 or newer, and none was found."
  fi
  die "Swift is too old." \
    "$detail Reinstall the Command Line Tools, then run the installer again." \
    "xcode-select --install"
fi

free_kb="$(df -k "$HOME" 2>/dev/null | awk 'NR==2 { print $4 }')"
if [[ -n "${free_kb:-}" && "$free_kb" -lt 2000000 ]]; then
  die "There isn't enough free disk space." \
    "Building Aether needs about 2 GB free. Free some space, then run the installer again." \
    "$RETRY"
fi

step_done "This Mac can build Aether"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

archive="$WORKDIR/aether.tar.gz"
set +e
curl -fsSL --retry 3 --retry-delay 1 -o "$archive" "$ARCHIVE_URL" &
curl_pid=$!
set -e
while kill -0 "$curl_pid" 2>/dev/null; do
  size=0
  if [[ -f "$archive" ]]; then
    size="$(stat -f %z "$archive" 2>/dev/null || echo 0)"
  fi
  pct=$((size * 100 / 700000))
  [[ "$pct" -gt 99 ]] && pct=99
  draw_bar "Downloading" "$pct"
  sleep 0.1
done
set +e
wait "$curl_pid"
curl_status=$?
set -e
if [[ "$curl_status" -ne 0 || ! -s "$archive" ]]; then
  die "The download failed." \
    "GitHub could not be reached. Check the connection, then run the installer again." \
    "$RETRY"
fi
draw_bar "Downloading" 100
step_done "Downloaded"

tar -xzf "$archive" -C "$WORKDIR"
SRC="$WORKDIR/Aether-main"
if [[ ! -d "$SRC" ]]; then
  die "The download was incomplete." \
    "The archive did not contain Aether. Run the installer again." \
    "$RETRY"
fi

export SWIFT
export PATH="$(dirname "$SWIFT"):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export AETHER_BUILD_LOG="$LOG"
hash -r

# Without this, a curl install is stamped "dev" and the app thinks every GitHub release is newer.
commit="$(curl -fsSL --retry 2 --retry-delay 1 -H "Accept: application/vnd.github+json" -H "User-Agent: Aether" \
  "https://api.github.com/repos/ganya002/Aether/commits/main" \
  | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1 || true)"
if [[ -n "$commit" ]]; then
  export AETHER_COMMIT="$commit"
fi

set +e
AETHER_BUILD_LOG="$LOG" "$SRC/scripts/build-app.sh" &
build_pid=$!
set -e
while kill -0 "$build_pid" 2>/dev/null; do
  fraction="$(grep -oE '\[[0-9]+/[0-9]+\]' "$LOG" 2>/dev/null | tail -1 || true)"
  if [[ "$fraction" =~ \[([0-9]+)/([0-9]+)\] && "${BASH_REMATCH[2]}" -gt 0 ]]; then
    pct=$((BASH_REMATCH[1] * 100 / BASH_REMATCH[2]))
    [[ "$pct" -gt 99 ]] && pct=99
    draw_bar "Building" "$pct"
  else
    draw_spin "Building"
  fi
  sleep 0.2
done
set +e
wait "$build_pid"
build_status=$?
set -e
if [[ "$build_status" -ne 0 || ! -d "$SRC/dist/Aether.app" ]]; then
  explain_build
fi
draw_bar "Building" 100
step_done "Built"

draw_bar "Installing" 40
DEST="$HOME/Downloads/Aether.app"
rm -rf "$DEST"
cp -R "$SRC/dist/Aether.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
if ! codesign --force --sign - "$DEST/Contents/MacOS/Aether" >>"$LOG" 2>&1 || ! codesign --force --sign - "$DEST" >>"$LOG" 2>&1; then
  die "macOS wouldn't sign Aether." \
    "The app is still in Downloads. Reinstall the Command Line Tools, then run the installer again. The log is at $LOG." \
    "xcode-select --install"
fi
draw_bar "Installing" 100
step_done "Installed in Downloads"

printf '\n  Drag Aether into Applications when it opens.\n\n'
open "$DEST"
open -R "$DEST"
