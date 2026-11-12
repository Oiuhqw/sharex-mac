#!/bin/bash
# Run only on a disposable macOS test account. Registration uses the real login-item service.
set -euo pipefail
SOURCE="$PWD/build/Build/Products/Debug/ShareX.app"
APP=/Applications/ShareX-Login-E2E.app
OUT="$PWD/e2e-out/login"
test ! -e "$APP"
mkdir -p "$OUT"
sudo ditto "$SOURCE" "$APP"
BIN="$APP/Contents/MacOS/ShareX"
run_step() {
  local step="$1" log="$OUT/$2.log" result=0
  python3 scripts/run-bounded.py --timeout 30 --log "$log" -- "$BIN" --e2e-login-item "$step" || result=$?
  cat "$log"
  return "$result"
}
cleanup() {
  local result=0
  run_step cleanup cleanup || result=$?
  if [ "$result" -eq 0 ]; then sudo rm -rf -- /Applications/ShareX-Login-E2E.app; fi
  return "$result"
}
trap cleanup EXIT
sudo codesign --force --deep -s - "$APP"
index=0
for step in default relaunch-enabled disable relaunch-disabled enable system-disable relaunch-disabled; do
  index=$((index + 1))
  run_step "$step" "$index-$step"
done
cleanup
trap - EXIT
