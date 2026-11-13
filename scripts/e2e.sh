#!/bin/bash
# Runs the --e2e driver against the built app on a GitHub macOS runner. Writes reviews/e2e-out/.
set -u
APP="$PWD/build/Build/Products/Debug/ShareX.app"; BIN="$APP/Contents/MacOS/ShareX"; OUT="$PWD/e2e-out"
mkdir -p "$OUT"
codesign --force --deep -s - "$APP" || true
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  bash scripts/ci-capture-permissions.sh "$APP" --accessibility
fi
RRC=0
for scenario in ranges encoding collision; do
  RECOVERY_OUT="$OUT/shortcut-recovery-$scenario"
  mkdir -p "$RECOVERY_OUT"
  if ! python3 scripts/run-bounded.py --timeout 30 --log "$RECOVERY_OUT/seed.log" -- "$BIN" --e2e-seed-shortcuts "$scenario" --out "$RECOVERY_OUT"; then
    RRC=1
    continue
  fi
  if ! python3 scripts/run-bounded.py --timeout 60 --log "$RECOVERY_OUT/verify.log" -- "$BIN" --e2e "$RECOVERY_OUT" --shortcut-recovery "$scenario"; then
    RRC=1
  fi
  if [ "$scenario" = collision ]; then
    mkdir -p "$RECOVERY_OUT/relaunch"
    if ! python3 scripts/run-bounded.py --timeout 60 --log "$RECOVERY_OUT/relaunch/verify.log" -- "$BIN" --e2e "$RECOVERY_OUT/relaunch" --shortcut-recovery "$scenario" --shortcut-recovery-previous "$RECOVERY_OUT"; then
      RRC=1
    fi
  fi
done
echo "shortcut recovery exit $RRC"
defaults delete com.sharexmac.ShareX 2>/dev/null || true
"$BIN" --e2e-pattern > "$OUT/pattern.log" 2>&1 &
PAT=$!
sleep 4
python3 scripts/run-bounded.py --timeout 330 --log "$OUT/e2e.log" -- "$BIN" --e2e "$OUT" --pattern-pid "$PAT"
RC=$?
echo "e2e exit $RC"
python3 scripts/run-bounded.py --timeout 30 --log "$OUT/verify.log" -- "$BIN" --e2e-verify "$OUT"
VRC=$?
echo "verify exit $VRC"
kill $PAT 2>/dev/null
screencapture -x "$OUT/runner-desktop.png" 2>/dev/null || true
grep -h "E2E " "$OUT/e2e.log" | sed 's/.*E2E /E2E /' | cut -c1-200
[ $RC -eq 0 ] && [ $VRC -eq 0 ] && [ $RRC -eq 0 ]
