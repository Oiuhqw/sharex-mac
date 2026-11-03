#!/bin/bash
# Runs the --e2e driver against the built app on a GitHub macOS runner. Writes reviews/e2e-out/.
set -u
APP="$PWD/build/Build/Products/Release/ShareX.app"; BIN="$APP/Contents/MacOS/ShareX"; OUT="$PWD/perf-out"
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
defaults delete com.sharexmac.ShareX 2>/dev/null || true
"$BIN" --e2e "$OUT" --perf > "$OUT/perf.log" 2>&1
RC=$?
echo "perf exit $RC"
cat "$OUT/perf.json" || grep "E2E" "$OUT/perf.log" | tail -20
test -f "$OUT/perf.json"
