#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "${GITHUB_ACTIONS:-}" != true ]]; then
  echo "Multi-display E2E requires a GitHub macOS runner." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/Build/Products/Debug/ShareX.app/Contents/MacOS/ShareX"
OUT="$ROOT/e2e-out/multidisplay"
HELPER="$OUT/virtual-displays"
HELPER_PID=""
mkdir -p "$OUT"
if [[ ! -x "$BIN" ]]; then
  echo "The Debug ShareX app is missing. Build the app and run scripts/e2e.sh first for its existing TCC grants." >&2
  exit 1
fi

stop_helper() {
  [[ -n "$HELPER_PID" ]] || return 0
  local pid="$HELPER_PID"
  HELPER_PID=""
  kill -TERM "$pid" 2>/dev/null || true
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Virtual display helper did not stop within 5 seconds." >&2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid"
}

cleanup() {
  local status=$?
  trap - EXIT
  if ! stop_helper; then status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! python3 "$ROOT/scripts/run-bounded.py" --timeout 60 --log "$OUT/build-helper.log" -- \
  xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -framework Foundation -framework CoreGraphics -framework AppKit \
  "$ROOT/scripts/virtual-displays.m" -o "$HELPER"; then
  cat "$OUT/build-helper.log" >&2
  exit 1
fi

STATUS=0
for layout in horizontal vertical-negative; do
  LAYOUT_OUT="$OUT/$layout"
  mkdir -p "$LAYOUT_OUT"
  rm -f "$LAYOUT_OUT/ready.json"
  "$HELPER" "$LAYOUT_OUT/ready.json" "$layout" > "$LAYOUT_OUT/helper.log" 2>&1 &
  HELPER_PID=$!
  for ((attempt = 0; attempt < 350; attempt++)); do
    [[ -s "$LAYOUT_OUT/ready.json" ]] && break
    if ! kill -0 "$HELPER_PID" 2>/dev/null; then
      echo "Virtual displays are unavailable for $layout." >&2
      cat "$LAYOUT_OUT/helper.log" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ ! -s "$LAYOUT_OUT/ready.json" ]]; then
    echo "Virtual displays were not ready within 35 seconds for $layout." >&2
    cat "$LAYOUT_OUT/helper.log" >&2
    exit 1
  fi

  if ! python3 "$ROOT/scripts/run-bounded.py" --timeout 300 --log "$LAYOUT_OUT/e2e.log" -- \
    "$BIN" --e2e-multidisplay "$LAYOUT_OUT" --multidisplay-layout "$layout"; then
    STATUS=1
    cat "$LAYOUT_OUT/e2e.log" >&2
  fi
  if ! kill -0 "$HELPER_PID" 2>/dev/null; then
    echo "Virtual display helper exited during $layout E2E." >&2
    STATUS=1
  fi
  if ! stop_helper; then STATUS=1; fi
done
exit "$STATUS"
