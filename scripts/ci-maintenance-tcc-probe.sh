#!/bin/bash
# Diagnostic only: the disposable runner removes these probe identities at teardown.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_OS:-}" != macOS ]]; then
  echo 'This permission probe is restricted to disposable GitHub macOS runners.' >&2
  exit 3
fi
if ! /usr/bin/csrutil status | /usr/bin/grep -q 'disabled'; then
  echo 'This permission probe requires a disposable runner with SIP disabled.' >&2
  exit 3
fi
test -n "${RUNNER_TEMP:-}"

python3 - <<'PY'
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

started = time.monotonic()
deadline = started + 230
uid = os.getuid()
home = Path(pwd.getpwuid(uid).pw_dir).resolve()
assert uid != 0, "Run this probe as the ordinary runner user."
assert Path.home().resolve() == home, "The probe must use the actual runner HOME."
runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
assert runner_temp.is_dir() and runner_temp != Path("/"), "Invalid RUNNER_TEMP."
root = Path(tempfile.mkdtemp(prefix="sharex-tcc-probe-", dir=runner_temp)).resolve()
assert root.parent == runner_temp
databases = {
    "system": "/Library/Application Support/com.apple.TCC/TCC.db",
    "user": str(home / "Library/Application Support/com.apple.TCC/TCC.db"),
}
lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def emit(event, **details):
    print("TCC_PROBE " + json.dumps({"event": event, "elapsedSeconds": round(time.monotonic() - started, 3), **details}, sort_keys=True), flush=True)


def run(label, command, timeout=15, check=True):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("The probe exceeded its 230-second budget.")
    result = subprocess.run(command, text=True, capture_output=True, timeout=min(timeout, remaining))
    emit("command", label=label, executable=command[0], callerUID=uid,
         exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if check and result.returncode:
        raise RuntimeError(f"{label} failed with exit code {result.returncode}")
    return result


# The snapshot connection is read-only. The only write is an INSERT for this run's
# unique probe bundle and the one service under investigation.
database_worker = r'''
import json
from pathlib import Path
import re
import sqlite3
import sys

operation, bundle_id, reason, selected, paths = sys.argv[1:]
assert operation in ("snapshot", "seed")
assert re.fullmatch(r"com\.sharexmac\.TCCProbe\.(both-r4|system-r4|user-r4|system-r2)-[0-9a-f]{32}", bundle_id)
assert reason in ("2", "4")
selected = json.loads(selected)
paths = json.loads(paths)
result = []
for scope, database_path in paths.items():
    path = Path(database_path)
    if not path.is_file():
        raise FileNotFoundError(database_path)
    mode = "rw" if operation == "seed" and scope in selected else "ro"
    with sqlite3.connect(path.as_uri() + "?mode=" + mode, uri=True, timeout=3) as connection:
        connection.row_factory = sqlite3.Row
        if mode == "rw":
            connection.execute(
                "INSERT INTO access "
                "(service,client,client_type,auth_value,auth_reason,auth_version,"
                "indirect_object_identifier,flags,last_modified) "
                "VALUES (?,?,0,2,?,1,'UNUSED',0,strftime('%s','now'))",
                ("kTCCServiceScreenCapture", bundle_id, int(reason)),
            )
        rows = [{key: value.hex() if isinstance(value, bytes) else value
                 for key, value in dict(row).items()}
                for row in connection.execute(
                    "SELECT * FROM access WHERE client = ? ORDER BY service, client_type",
                    (bundle_id,),
                )]
        result.append({"scope": scope, "databasePath": database_path, "rows": rows})
print(json.dumps(result, sort_keys=True))
'''


def database_state(scenario, bundle_id, reason, phase, seed_scopes=()):
    result = run(f"{scenario}:{phase}", [
        "/usr/bin/sudo", "-n", sys.executable, "-c", database_worker,
        "seed" if seed_scopes else "snapshot", bundle_id, str(reason),
        json.dumps(seed_scopes), json.dumps(databases),
    ])
    state = json.loads(result.stdout)
    emit("database_snapshot", scenario=scenario, phase=phase, bundleID=bundle_id, databases=state)
    return state


def preflight(scenario, bundle_id, app, phase):
    report = root / f"{scenario}-{phase}.json"
    run(f"{scenario}:{phase}:launch", ["/usr/bin/open", "-n", "-W", str(app), "--args", str(report)])
    observation = json.loads(report.read_text())
    assert observation["bundleID"] == bundle_id
    assert observation["uid"] == uid
    assert Path(observation["executablePath"]).resolve() == app / "Contents/MacOS/TCCProbe"
    emit("preflight", scenario=scenario, phase=phase, **observation)
    return observation


emit("start", uid=uid, home=str(home), runnerTemp=str(runner_temp), probeRoot=str(root),
     databases=databases, accountScope="Actual disposable runner account; no HOME isolation")
run("macOS", ["/usr/bin/sw_vers"])
source = root / "TCCProbe.swift"
source.write_text('''import AppKit
import CoreGraphics
import Darwin

_ = NSApplication.shared
let observation: [String: Any] = [
    "bundleID": Bundle.main.bundleIdentifier ?? "",
    "executablePath": Bundle.main.executablePath ?? "",
    "pid": getpid(),
    "uid": getuid(),
    "screenCaptureGranted": CGPreflightScreenCaptureAccess()
]
let data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: [.atomic])
''')
binary = root / "TCCProbe"
run("compile", ["/usr/bin/xcrun", "swiftc", str(source), "-o", str(binary)], timeout=90)

summaries = []
for scenario, scopes, reason in (
    ("both-r4", ("system", "user"), 4),
    ("system-r4", ("system",), 4),
    ("user-r4", ("user",), 4),
    ("system-r2", ("system",), 2),
):
    bundle_id = f"com.sharexmac.TCCProbe.{scenario}-{uuid.uuid4().hex}"
    app = root / f"{scenario}.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    shutil.copy2(binary, contents / "MacOS/TCCProbe")
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "TCCProbe",
        "CFBundleName": "TCCProbe", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
    }))
    run(f"{scenario}:sign", ["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
    run(f"{scenario}:register", [lsregister, "-f", str(app)])
    initial = database_state(scenario, bundle_id, reason, "initial")
    assert not any(item["rows"] for item in initial), "Probe identity is not fresh."
    database_state(scenario, bundle_id, reason, "seeded", scopes)
    before = preflight(scenario, bundle_id, app, "before-reset")
    database_state(scenario, bundle_id, reason, "before-reset")
    reset = run(f"{scenario}:ordinary-user-reset", [
        "/usr/bin/tccutil", "reset", "ScreenCapture", bundle_id,
    ], check=False)
    after_reset = database_state(scenario, bundle_id, reason, "after-reset")
    after = preflight(scenario, bundle_id, app, "after-reset")
    assert before["pid"] != after["pid"], "Preflight did not use a fresh process."
    after_preflight = database_state(scenario, bundle_id, reason, "after-reset-preflight")
    summaries.append({
        "scenario": scenario, "bundleID": bundle_id, "seededScopes": scopes,
        "authReason": reason, "resetExitCode": reset.returncode,
        "beforeGranted": before["screenCaptureGranted"], "afterGranted": after["screenCaptureGranted"],
        "afterReset": after_reset, "afterResetPreflight": after_preflight,
    })

emit("complete", scenarios=summaries, scenarioCount=len(summaries), preflightCount=2 * len(summaries),
     cleanup="Probe rows and temporary directories are left for disposable runner teardown.")
PY
