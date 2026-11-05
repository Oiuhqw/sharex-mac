#!/bin/bash
# Runs the Release performance driver on a GitHub macOS runner. Writes perf-out/.
set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP="$PWD/build/Build/Products/Release/ShareX.app"; BIN="$APP/Contents/MacOS/ShareX"; OUT="$PWD/perf-out"
mkdir -p "$OUT" || exit 1
# A prior run must never make a crashed or incomplete driver look successful.
rm -f "$OUT/perf.json" "$OUT/resources.json" "$OUT/results.json" || exit 1
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
runner_context() {
  local version arch cores load boot processes
  version=$(sw_vers) || return 1
  arch=$(uname -m) || return 1
  cores=$(sysctl -n hw.logicalcpu) || return 1
  load=$(sysctl -n vm.loadavg) || return 1
  boot=$(uptime) || return 1
  processes=$(ps -axo pid,pcpu,rss,comm) || return 1
  [ -n "$version" ] && [ -n "$arch" ] && [ -n "$cores" ] && [ -n "$load" ] && [ -n "$boot" ] && [ -n "$processes" ] || return 1
  printf '%s\nArchitecture: %s\nLogical CPUs: %s\nLoad average: %s\nUptime: %s\n' "$version" "$arch" "$cores" "$load" "$boot"
  printf '\nTop processes by CPU (PID, CPU percent, RSS KiB, command):\n'
  printf '%s\n' "$processes" | tail -n +2 | sort -k2,2nr | head -10
  printf '\nTop processes by RSS (PID, CPU percent, RSS KiB, command):\n'
  printf '%s\n' "$processes" | tail -n +2 | sort -k3,3nr | head -10
}
runner_context > "$OUT/runner-before.log" 2>&1 || exit 1
"$BIN" --e2e "$OUT" --perf > "$OUT/perf.log" 2>&1
RC=$?
CONTEXT_RC=0
runner_context > "$OUT/runner-after.log" 2>&1 || CONTEXT_RC=$?
echo "perf exit $RC"
cat "$OUT/perf.json" || grep "E2E" "$OUT/perf.log" | tail -20
if [ "$RC" -ne 0 ]; then
  exit "$RC"
fi
[ "$CONTEXT_RC" -eq 0 ] || exit 1
test -s "$OUT/perf.json" || exit 1
python3 "$SCRIPT_DIR/validate-perf.py" "$OUT/perf.json"

