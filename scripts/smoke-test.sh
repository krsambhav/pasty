#!/usr/bin/env bash
# Launches the built app (through LaunchServices, like a user would) in smoke-test mode against a
# throwaway data directory, and prints the results.
# Usage: scripts/smoke-test.sh path/to/Pasty.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(cd "$(dirname "${1:-build/Release/Pasty.app}")" && pwd)/$(basename "${1:-build/Release/Pasty.app}")"
OUT="$(pwd)/build/smoke"
rm -rf "$OUT"; mkdir -p "$OUT"
DATA="$(mktemp -d)"

open -n -W \
  --env "PASTY_DATA_DIR=$DATA" \
  --stdout "$OUT/stdout.log" --stderr "$OUT/stderr.log" \
  "$APP" --args --smoke-test "$OUT" &
PID=$!
for _ in $(seq 1 300); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "Smoke test timed out" >&2
  pkill -f "Pasty.app/Contents/MacOS/Pasty" || true
  kill "$PID" || true
fi
set +e
wait "$PID"; STATUS=$?
set -e

if [[ -f "$OUT/results.json" ]]; then
  cat "$OUT/results.json"
  grep -q '"passed" : true' "$OUT/results.json" && exit 0
  exit 1
fi
echo "No results written (status $STATUS)" >&2
tail -50 "$OUT/stderr.log" >&2 || true
exit 1
