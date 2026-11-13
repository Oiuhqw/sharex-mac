#!/bin/bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_OS:-}" != macOS ]]; then
  echo 'This permission setup is restricted to disposable GitHub macOS runners.' >&2
  exit 3
fi
if ! /usr/bin/csrutil status | /usr/bin/grep -q 'disabled'; then
  echo 'Runner Screen Recording permission must be granted by an operator. SIP is enabled.' >&2
  exit 3
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'Usage: ci-capture-permissions.sh APP [--accessibility] | --helper PATH' >&2
  exit 2
fi

services=(kTCCServiceScreenCapture)
if [[ "$1" == --helper ]]; then
  test $# = 2
  test -n "${RUNNER_TEMP:-}"
  test "$2" = "$RUNNER_TEMP/sharex-agent-setup-helper"
  binary="$2"
  bundle_id=''
  services+=(kTCCServiceAccessibility)
else
  if [[ $# == 2 && "$2" != --accessibility ]]; then exit 2; fi
  binary="$1/Contents/MacOS/ShareX"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")"
  test "$bundle_id" = com.sharexmac.ShareX
  if [[ "${2:-}" == --accessibility ]]; then services+=(kTCCServiceAccessibility); fi
fi
test -x "$binary"
for database in '/Library/Application Support/com.apple.TCC/TCC.db' "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  if [[ -f "$database" ]]; then
    sudo python3 - "$database" "$binary" "$bundle_id" "${services[@]}" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    identities = [(sys.argv[2], 1)]
    if sys.argv[3]:
        identities.append((sys.argv[3], 0))
    for service in sys.argv[4:]:
        for client, client_type in identities:
            connection.execute(
                'INSERT OR REPLACE INTO access '
                '(service,client,client_type,auth_value,auth_reason,auth_version,'
                'indirect_object_identifier,flags,last_modified) '
                "VALUES (?,?,?,2,4,1,'UNUSED',0,strftime('%s','now'))",
                (service, client, client_type),
            )
PY
  fi
done
