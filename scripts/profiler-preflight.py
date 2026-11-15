#!/usr/bin/env python3
"""Collect installed Mac profiler documentation without starting a profile or capture."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from typing import NamedTuple


TIMEOUT_SECONDS = 10


class Command(NamedTuple):
    name: str
    argv: tuple[str, ...]
    manual: bool = False


COMMANDS = (
    Command("sw-vers", ("/usr/bin/sw_vers",)),
    Command("architecture", ("/usr/bin/uname", "-m")),
    Command("developer-directory", ("/usr/bin/xcode-select", "-p")),
    Command("xcode-version", ("/usr/bin/xcodebuild", "-version")),
    Command("uptime", ("/usr/bin/uptime",)),
    Command("logical-cpus", ("/usr/sbin/sysctl", "-n", "hw.logicalcpu")),
    Command("identity", ("/usr/bin/id",)),
    Command("noninteractive-sudo", ("/usr/bin/sudo", "-n", "/usr/bin/true")),
    Command("spindump-manual", ("/usr/bin/man", "8", "spindump"), manual=True),
    Command("sample-manual", ("/usr/bin/man", "1", "sample"), manual=True),
    Command("xctrace-path", ("/usr/bin/xcrun", "--find", "xctrace")),
    Command("xctrace-record-help", ("/usr/bin/xcrun", "xctrace", "help", "record")),
    Command("xctrace-export-help", ("/usr/bin/xcrun", "xctrace", "help", "export")),
    Command("xctrace-templates", ("/usr/bin/xcrun", "xctrace", "list", "templates")),
    Command("sip-status", ("/usr/bin/csrutil", "status")),
    Command("process-inventory", ("/bin/ps", "-axo", "pid,ppid,user,lstart,comm")),
)
TOOL_PATHS = tuple(sorted({command.argv[0] for command in COMMANDS}
                          | {"/usr/sbin/spindump", "/usr/bin/sample", "/usr/bin/true"}))


def clock():
    before = time.monotonic_ns()
    wall = datetime.now(timezone.utc).isoformat()
    return {"monotonicBeforeNs": before, "wallUTC": wall, "monotonicAfterNs": time.monotonic_ns()}


def executable_check(path):
    candidate = Path(path)
    return {"path": str(candidate), "resolvedPath": str(candidate.resolve()),
            "isFile": candidate.is_file(), "executable": os.access(candidate, os.X_OK)}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def plain_manual(raw):
    text = raw.decode("utf-8", errors="replace")
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    return re.sub(r"[^\n]\x08", "", text)


def collect_command(command, out, timeout=TIMEOUT_SECONDS):
    stdout_path = out / f"{command.name}.stdout.raw"
    stderr_path = out / f"{command.name}.stderr.raw"
    record_path = out / f"{command.name}.json"
    record = {"name": command.name, "argv": list(command.argv), "timeoutSeconds": timeout,
              "started": clock(), "status": "running", "exitCode": None,
              "stdout": stdout_path.name, "stderr": stderr_path.name,
              "executableCheck": executable_check(command.argv[0])}
    write_json(record_path, record)
    environment = dict(os.environ, MANPAGER="cat", PAGER="cat")
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = None
        try:
            if not record["executableCheck"]["isFile"]:
                raise FileNotFoundError(f"Executable is absent: {command.argv[0]}")
            process = subprocess.Popen(command.argv, stdin=subprocess.DEVNULL, stdout=stdout,
                                       stderr=stderr, env=environment, shell=False,
                                       start_new_session=os.name == "posix")
            record["pid"] = process.pid
            record["exitCode"] = process.wait(timeout=timeout)
            record["status"] = "completed" if record["exitCode"] == 0 else "failed"
        except subprocess.TimeoutExpired:
            record["status"] = "timed_out"
            record["termination"] = {"requested": clock(), "ownedPID": process.pid,
                                     "processGroup": os.name == "posix", "method": "kill"}
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
            except ProcessLookupError:
                pass
            except OSError as error:
                record["termination"]["error"] = str(error)
            try:
                record["exitCode"] = process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                record["termination"]["error"] = "Owned process did not exit within two seconds after kill"
        except OSError as error:
            record["status"] = "launch_error"
            record["error"] = {"type": type(error).__name__, "message": str(error)}
        finally:
            record["finished"] = clock()
            write_json(record_path, record)
    if command.manual:
        plain_path = out / f"{command.name}.plain.txt"
        rendered = plain_manual(stdout_path.read_bytes())
        plain_path.write_text(rendered, encoding="utf-8")
        record["plainText"] = plain_path.name
        if record["status"] == "completed" and not rendered.strip():
            record["status"] = "empty_manual"
    write_json(record_path, record)
    return record


def discover(out, commit, commands=COMMANDS):
    out.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "phase": "documentation_discovery", "commit": commit,
              "started": clock(), "outcome": "incomplete", "productionE2EPassed": False,
              "profileCollected": False, "samplingSyntaxValidated": False,
              "capabilityProbeRun": False, "developerDirectoryOverride": os.environ.get("DEVELOPER_DIR"),
              "pager": {"MANPAGER": "cat", "PAGER": "cat"},
              "toolChecks": [executable_check(path) for path in TOOL_PATHS], "commands": []}
    report_path = out / "preflight.json"
    write_json(report_path, report)
    for command in commands:
        result = collect_command(command, out)
        report["commands"].append(result)
        if command.name == "xctrace-path" and result["status"] == "completed":
            path = (out / result["stdout"]).read_text(encoding="utf-8", errors="replace").strip()
            if Path(path).is_absolute():
                report["toolChecks"].append(executable_check(path))
            else:
                result["status"] = "invalid_tool_path"
                write_json(out / f"{command.name}.json", result)
        write_json(report_path, report)
    report["failedCommands"] = [result["name"] for result in report["commands"]
                                if result["status"] != "completed"]
    report["unavailableTools"] = [check["path"] for check in report["toolChecks"]
                                  if not check["isFile"] or not check["executable"]]
    if not report["failedCommands"] and not report["unavailableTools"]:
        report["outcome"] = "discovery_complete"
    report["finished"] = clock()
    write_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    if args.out.exists():
        parser.error("--out must be a new directory to preserve earlier evidence")
    report = discover(args.out, args.commit)
    print(f"{report['outcome']}: {args.out / 'preflight.json'}")
    return 0 if report["outcome"] == "discovery_complete" else 1


if __name__ == "__main__":
    sys.exit(main())
