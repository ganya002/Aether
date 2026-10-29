#!/bin/sh
# Standard agent loop against a live Aether: spawn → watch → read → interrupt → rerun.
# Run this from a shell that can reach Aether's control port (Aether must be open).
set -eu

if ! command -v aether >/dev/null 2>&1; then
  bin="$HOME/Library/Application Support/Aether/bin/aether"
  if [ -x "$bin" ]; then
    PATH="$(dirname "$bin"):$PATH"
  elif [ -x "$(dirname "$0")/aether" ]; then
    PATH="$(cd "$(dirname "$0")" && pwd):$PATH"
  else
    echo "aether is not on PATH. Open Aether once, then retry." >&2
    exit 1
  fi
fi

echo "== spawn a visible shell pane =="
id=$(aether tab --title agent-loop)
echo "pane $id"

echo "== start a job, watch ticks, then interrupt =="
aether send "$id" 'echo START; i=1; while [ $i -le 80 ]; do echo tick $i; sleep 0.3; i=$((i+1)); done; echo NEVER' --enter
sleep 0.8
aether send "$id" --keys ctrl+c
aether wait "$id" --until-idle --timeout 8

echo "== read what it printed =="
aether read "$id" --lines 40

echo "== rerun to completion in the same pane =="
aether run --pane "$id" --title agent-loop -- /bin/sh -c 'echo RERUN; echo OK'
echo "run exit $?"

echo "== json view of that pane =="
aether view --json | python3 -c "import json,sys; panes=json.load(sys.stdin).get('panes',[]);
print(next((p for p in panes if p.get('id','').startswith('$id'[0:8])), {}))"

echo "== close =="
aether close "$id"
echo "ok"
