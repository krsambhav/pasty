#!/usr/bin/env bash
# Launches the built app in smoke-test mode against a throwaway data directory and prints the
# results (capture latency, panel open timing, copy-back correctness, idle CPU and memory).
# Usage: scripts/smoke-test.sh path/to/Pasty.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Release/Pasty.app}"
OUT="$(pwd)/build/smoke"
rm -rf "$OUT"; mkdir -p "$OUT"
export PASTY_DATA_DIR="$(mktemp -d)"

"$APP/Contents/MacOS/Pasty" --smoke-test "$OUT" > "$OUT/stdout.log" 2> "$OUT/stderr.log" &
PID=$!
for _ in $(seq 1 300); do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "Smoke test timed out" >&2
  kill "$PID" || true
  tail -50 "$OUT/stderr.log" >&2 || true
  exit 1
fi
set +e
wait "$PID"; STATUS=$?
set -e

if [[ -f "$OUT/results.json" ]]; then
  cat "$OUT/results.json"
else
  echo "No results written" >&2
  tail -50 "$OUT/stderr.log" >&2 || true
fi
exit "$STATUS"
