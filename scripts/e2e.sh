#!/bin/bash
# Runs the --e2e driver against the built app on a GitHub macOS runner. Writes reviews/e2e-out/.
set -u
APP="$PWD/build/Build/Products/Debug/ShareX.app"; BIN="$APP/Contents/MacOS/ShareX"; OUT="$PWD/e2e-out"
mkdir -p "$OUT"
codesign --force --deep -s - "$APP" || true
# Grant Screen Recording (runner SIP is off). Insert by path and by bundle id into system + user TCC.db.
grant() {
  local db="$1" client="$2" type="$3"
  cols=$(sudo sqlite3 "$db" "PRAGMA table_info(access);" | cut -d'|' -f2 | tr '\n' ' ')
  echo "TCC $db columns: $cols"
  sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified) VALUES ('kTCCServiceScreenCapture','$client',$type,2,4,1,'UNUSED',0,strftime('%s','now'));" && echo "granted $client in $db"
  sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified) VALUES ('kTCCServiceAccessibility','$client',$type,2,4,1,'UNUSED',0,strftime('%s','now'));" || true
}
for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  [ -f "$db" ] || continue
  grant "$db" "$BIN" 1; grant "$db" "com.sharexmac.ShareX" 0
done
RRC=0
for scenario in ranges encoding; do
  RECOVERY_OUT="$OUT/shortcut-recovery-$scenario"
  mkdir -p "$RECOVERY_OUT"
  if ! python3 scripts/run-bounded.py --timeout 30 --log "$RECOVERY_OUT/seed.log" -- "$BIN" --e2e-seed-shortcuts "$scenario" --out "$RECOVERY_OUT"; then
    RRC=1
    continue
  fi
  if ! python3 scripts/run-bounded.py --timeout 60 --log "$RECOVERY_OUT/verify.log" -- "$BIN" --e2e "$RECOVERY_OUT" --shortcut-recovery "$scenario"; then
    RRC=1
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
