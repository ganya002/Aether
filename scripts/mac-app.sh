#!/usr/bin/env bash
# Open Aether in a chromeless window on macOS. Uses the browser you already
# have, so it does not install a second Chromium.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-41773}"
URL="http://127.0.0.1:${PORT}/"

if ! command -v npm >/dev/null 2>&1; then
  echo "Install Node.js 20 or newer, then run this again."
  exit 1
fi

if [[ ! -d node_modules ]]; then
  npm install
fi

if ! curl -sf -o /dev/null "${URL}api/health"; then
  npm start &
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "${URL}api/health"; then
      break
    fi
    sleep 0.25
  done
fi

if open -na "Google Chrome" --args --app="$URL" >/dev/null 2>&1; then
  exit 0
fi
if open -na "Microsoft Edge" --args --app="$URL" >/dev/null 2>&1; then
  exit 0
fi
if open -na "Brave Browser" --args --app="$URL" >/dev/null 2>&1; then
  exit 0
fi
open "$URL"
