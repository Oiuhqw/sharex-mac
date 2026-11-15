#!/usr/bin/env python3
"""Collect one bounded system timeline focused on an owned sleep process."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


SPEC = importlib.util.spec_from_file_location("profiler_preflight", Path(__file__).with_name("profiler-preflight.py"))
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)

TOTAL_SECONDS = 30
REPORT_LIMIT_SECONDS = 20
HELPER = ("/bin/sleep", "60")
INVENTORY = ("/bin/ps", "-axo", "pid,ppid,pgid,user,lstart,comm")
WAIT_API = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT", "CLD_EXITED", "getpgid", "getsid", "killpg")
MANUAL_CLAUSES = (
    "When run manually, spindump samples user and kernel callstacks for every process in the system.",
    "pid or partial-name the process to be sorted topmost in the report.",
    "duration the duration of the sampling in seconds.",
    "interval the number of miliseconds between samples.",
    "-timeline Sort callstacks chronologically",
    "-o path Specifies where the report should be written.",
    "-timelimit t Exit after t seconds even if the report hasn't been saved",
    "-displayIdleWorkQueueThreads Display idle work queue threads in the textual report (by default they are omitted)",
    "includes a binary representation of its data at the end of reports",
)


def executable_identity(path):
    identity = preflight.executable_check(path)
    if identity["isFile"]:
        stat = Path(path).stat()
        identity.update(sizeBytes=stat.st_size, device=stat.st_dev, inode=stat.st_ino,
                        sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest())
    return identity


class Cancellation:
    def __init__(self):
        self.error = None

    def request(self, signum, frame):
        if self.error is None:
            self.error = InterruptedError(f"Supervisor received signal {signum}")

    def check(self):
        if self.error is not None:
            raise self.error


class OwnedChild:
    """Keep a direct child unreaped until its entire owned group is signalled."""

    def __init__(self, name, argv, out):
        self.path = out / f"{name}.json"
        self.process = None
        self.record = {"argv": list(argv), "started": preflight.clock(), "status": "launch_error",
                       "exitCode": None, "executable": executable_identity(argv[0]), "signals": [],
                       "stdout": f"{name}.stdout.raw", "stderr": f"{name}.stderr.raw"}
        self.save()
        try:
            with (out / self.record["stdout"]).open("wb") as stdout, (out / self.record["stderr"]).open("wb") as stderr:
                try:
                    self.process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                                    shell=False, start_new_session=True)
                    self.record.update(pid=self.process.pid, pgid=self.process.pid, status="running")
                except OSError as error:
                    self.record["error"] = str(error)
                    self.record["finished"] = preflight.clock()
                self.save()
        except BaseException:
            self.close(time.monotonic() + 1)
            raise

    def save(self):
        preflight.write_json(self.path, self.record)

    def exited(self):
        if self.process is None:
            return True
        return os.waitid(os.P_PID, self.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None

    def wait(self, deadline, cancellation=None):
        while not self.exited():
            if cancellation is not None:
                cancellation.check()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.record["status"] = "timed_out"
                self.save()
                return False
            time.sleep(min(0.02, remaining))
        if self.process is not None:
            result = os.waitid(os.P_PID, self.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            self.record["exitCode"] = result.si_status if result.si_code == os.CLD_EXITED else -result.si_status
            self.record["status"] = "completed" if self.record["exitCode"] == 0 else "failed"
            self.record["exitObserved"] = preflight.clock()
            self.save()
        return self.record["status"] == "completed"

    def signal_group(self, sig):
        # WNOWAIT retains the direct child's PID even after exit, so this group cannot be reused.
        os.waitid(os.P_PID, self.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        pgid = os.getpgid(self.process.pid)
        sid = os.getsid(self.process.pid)
        if pgid != self.process.pid or sid != self.process.pid:
            raise RuntimeError("Owned child is no longer its recorded session and process-group leader")
        event = {"signal": sig.name, "requested": preflight.clock(), "pid": self.process.pid,
                 "verifiedPGID": pgid, "verifiedSID": sid, "ownership": "unreaped_direct_child"}
        self.record["signals"].append(event)
        os.killpg(pgid, sig)
        event["sent"] = preflight.clock()

    def close(self, deadline):
        if self.process is None:
            self.record["cleanupComplete"] = True
            self.save()
            return
        try:
            self.signal_group(signal.SIGTERM)
            time.sleep(max(0, min(0.1, deadline - time.monotonic())))
            self.signal_group(signal.SIGKILL)
            self.record["exitCode"] = self.process.wait(timeout=max(0, deadline - time.monotonic()))
            if self.record["status"] == "running":
                self.record["status"] = "stopped"
            self.record["cleanupComplete"] = True
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            self.record["cleanupComplete"] = False
            self.record["cleanupError"] = str(error)
        finally:
            self.record["finished"] = preflight.clock()
            self.save()


def validate_documentation(directory, commit):
    manifest = json.loads((directory / "preflight.json").read_text(encoding="utf-8"))
    if manifest["commit"] != commit or manifest["outcome"] != "discovery_complete":
        raise ValueError("The matching commit requires complete installed-tool discovery")
    manual_path = directory / "spindump-manual.plain.txt"
    manual = " ".join(manual_path.read_text(encoding="utf-8").split())
    missing = [clause for clause in MANUAL_CLAUSES if clause not in manual]
    if missing:
        raise ValueError(f"Installed spindump manual does not confirm: {missing}")
    return {"directory": str(directory.resolve()), "manualSHA256": hashlib.sha256(manual_path.read_bytes()).hexdigest(),
            "confirmedClauses": list(MANUAL_CLAUSES)}


def collector_command(pid, report_path):
    return ("/usr/sbin/spindump", str(pid), "1", "20", "-timeline", "-displayIdleWorkQueueThreads",
            "-timelimit", str(REPORT_LIMIT_SECONDS), "-o", str(report_path))


def inventory(name, out, deadline):
    child = OwnedChild(name, INVENTORY, out)
    try:
        child.wait(min(time.monotonic() + 2, deadline - 0.5))
    finally:
        child.close(deadline)
    return child.record


def collect_probe(out, commit, documentation, total_seconds=TOTAL_SECONDS, cancellation=None):
    if cancellation is None:
        cancellation = Cancellation()
    out.mkdir(parents=True, exist_ok=False)
    deadline = time.monotonic() + total_seconds
    report = {"schemaVersion": 1, "phase": "profiler_capability_collection", "commit": commit,
              "started": preflight.clock(), "totalLimitSeconds": total_seconds, "outcome": "incomplete",
              "productionE2EPassed": False, "sourceProfileCollected": False, "capabilityValidated": False,
              "validationPending": "Inspect actual timeline, WindowServer/replayd stacks, and clock mapping",
              "runtime": {"platform": sys.platform, "pythonVersion": sys.version,
                          "pythonExecutable": executable_identity(sys.executable),
                          "effectiveUID": os.geteuid() if hasattr(os, "geteuid") else None,
                          "waitAPI": {name: hasattr(os, name) for name in WAIT_API}}}
    report_path = out / "capability.json"
    preflight.write_json(report_path, report)
    helper = collector = None
    try:
        cancellation.check()
        if not all(report["runtime"]["waitAPI"].values()):
            raise RuntimeError("Owned process-group cleanup requires waitid with WNOWAIT support")
        report["documentation"] = validate_documentation(documentation, commit)
        report["preInventory"] = inventory("processes-before", out, min(deadline - 5, time.monotonic() + 3))
        cancellation.check()
        if report["preInventory"]["status"] != "completed" or not report["preInventory"]["cleanupComplete"]:
            raise RuntimeError("Pre-collection process inventory failed")
        helper = OwnedChild("helper", HELPER, out)
        cancellation.check()
        if helper.exited():
            raise RuntimeError("Owned sleep helper did not stay alive")
        raw = out / "report"
        raw.mkdir()
        collector = OwnedChild("collector", collector_command(helper.process.pid, raw / "system.spindump.txt"), out)
        cancellation.check()
        collector.wait(deadline - 5, cancellation)
    except (OSError, ValueError, RuntimeError, KeyError, InterruptedError, KeyboardInterrupt) as error:
        report["error"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        for name, child in (("collector", collector), ("helper", helper)):
            if child is not None:
                try:
                    child.close(min(deadline - 3, time.monotonic() + 1))
                except OSError as error:
                    report["error"] = {"type": type(error).__name__, "message": str(error)}
                report[name] = child.record
                if name == "collector" and helper is not None:
                    report["helperAliveAtCollectorExit"] = not helper.exited()
        if all(report["runtime"]["waitAPI"].values()):
            try:
                report["postInventory"] = inventory("processes-after", out, deadline)
                groups = {child.process.pid for child in (helper, collector)
                          if child is not None and child.process is not None}
                lines = (out / report["postInventory"]["stdout"]).read_text(encoding="utf-8", errors="replace").splitlines()
                if len(lines) < 2 or lines[0].split()[:3] != ["PID", "PPID", "PGID"]:
                    raise ValueError("Post-collection inventory has no process identity columns")
                report["remainingOwnedProcessGroups"] = []
                for line in lines[1:]:
                    fields = line.split(maxsplit=3)
                    if len(fields) != 4 or not all(value.isdigit() for value in fields[:3]):
                        raise ValueError("Post-collection inventory has an invalid process identity")
                    if int(fields[2]) in groups:
                        report["remainingOwnedProcessGroups"].append(line)
            except (OSError, ValueError, RuntimeError, InterruptedError, KeyboardInterrupt) as error:
                report["postInventoryError"] = str(error)
        report["files"] = []
        try:
            out.chmod(0o755)
            for path in sorted(out.rglob("*")):
                if path.is_symlink():
                    raise RuntimeError(f"Unexpected symlink in owned output: {path.name}")
                path.chmod(0o755 if path.is_dir() else 0o644)
                if path.is_file() and path != report_path:
                    report["files"].append({"path": str(path.relative_to(out)), "sizeBytes": path.stat().st_size})
        except (OSError, RuntimeError) as error:
            report["error"] = {"type": type(error).__name__, "message": str(error)}
        report_file = out / "report" / "system.spindump.txt"
        if cancellation.error is not None:
            report["error"] = {"type": type(cancellation.error).__name__, "message": str(cancellation.error)}
        if ("error" not in report and "postInventoryError" not in report
                and collector is not None and collector.record["status"] == "completed"
                and report.get("helperAliveAtCollectorExit") and report_file.is_file() and report_file.stat().st_size
                and all(report.get(name, {}).get("cleanupComplete") for name in ("collector", "helper"))
                and report.get("postInventory", {}).get("status") == "completed"
                and report["postInventory"]["cleanupComplete"] and report.get("remainingOwnedProcessGroups") == []
                and time.monotonic() <= deadline):
            report["outcome"] = "collection_complete"
        report["finished"] = preflight.clock()
        preflight.write_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--preflight", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    if args.out.exists():
        parser.error("--out must be a new directory to preserve earlier evidence")
    if sys.platform != "darwin" or os.geteuid() != 0:
        parser.error("Run this Mac-only probe supervisor explicitly through noninteractive sudo")

    cancellation = Cancellation()
    signal.signal(signal.SIGTERM, cancellation.request)
    signal.signal(signal.SIGINT, cancellation.request)
    report = collect_probe(args.out, args.commit, args.preflight, cancellation=cancellation)
    print(f"{report['outcome']}: {args.out / 'capability.json'}; capability validation remains pending")
    return 0 if report["outcome"] == "collection_complete" else 1


if __name__ == "__main__":
    sys.exit(main())
