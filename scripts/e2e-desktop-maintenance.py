#!/usr/bin/env python3
"""Drive manual recording, permission reset and uninstall on a disposable macOS runner.

This gate uses the installed Release app and public Accessibility controls. It changes
the real runner account's defaults, TCC grants and login registration, then trashes
the installed app. Run it after the other installed-app evaluations. No fake HOME,
injected production code, paid services or artifact uploads are required.
"""

import argparse
import base64
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import stat
import sys
import time
import traceback
from urllib.parse import unquote, urlparse
import uuid


SPEC = importlib.util.spec_from_file_location("agent_setup_e2e", Path(__file__).with_name("e2e-agent-setup.py"))
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)
NATIVE = SETUP.NATIVE
Blocked, Failure, require = NATIVE.Blocked, NATIVE.Failure, NATIVE.require
BUNDLE_ID = "com.sharexmac.ShareX"
RECORDING_WINDOW = "ShareX Recording"
TCC_QUERY = """
import json, os, sqlite3, sys
result = {}
for path in ('/Library/Application Support/com.apple.TCC/TCC.db',
             sys.argv[1] + '/Library/Application Support/com.apple.TCC/TCC.db'):
    if not os.path.isfile(path):
        continue
    with sqlite3.connect('file:' + path + '?mode=ro', uri=True) as database:
        database.row_factory = sqlite3.Row
        result[path] = [{key: value.hex() if isinstance(value, bytes) else value for key, value in dict(row).items()}
                       for row in database.execute(
            'SELECT * FROM access WHERE client IN (?, ?) ORDER BY service, client, client_type', sys.argv[2:4])]
print(json.dumps(result, sort_keys=True))
"""
DARWIN_SOL_LOCAL = 0
DARWIN_LOCAL_PEERPID = 2


def tree_hashes(root):
    require(root.is_dir() and not root.is_symlink(), f"Evidence root is not a real directory: {root}.")
    result = {}
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                result[relative] = {"link": os.readlink(path)}
            elif stat.S_ISREG(metadata.st_mode):
                result[relative] = {"bytes": metadata.st_size, "sha256": NATIVE.digest(path)}
            elif stat.S_ISDIR(metadata.st_mode):
                result[relative] = {"directory": True}
            else:
                raise Failure(f"Unexpected special file in evidence: {path}.")
    return result


def login_records(output, app):
    records = []
    for block in re.split(r"(?m)^\s*#\d+:[^\n]*$", output):
        urls = re.findall(r"(?m)^\s*URL:\s*(\S+)\s*$", block)
        if not any(unquote(urlparse(url).path).rstrip("/") == app.as_posix() for url in urls):
            continue
        disposition = re.findall(r"(?m)^\s*Disposition:\s*\[([^\]]*)\]", block)
        require(len(disposition) == 1, "Cannot identify the installed app's login-item disposition.")
        records.append({"enabled": "enabled" in [item.strip() for item in disposition[0].split(",")],
                        "disposition": disposition[0]})
    return records


def permission_rows(snapshot, client):
    return {database: [row for row in rows if row["client"] == client]
            for database, rows in snapshot.items()}


def permission_probe_response(connection, pid):
    peer_pid = connection.getsockopt(DARWIN_SOL_LOCAL, DARWIN_LOCAL_PEERPID)
    require(peer_pid == pid, "The agent socket belongs to another process.")
    request_id = str(uuid.uuid4())
    request = {"version": 1, "id": request_id, "operation": "capabilities", "arguments": {}}
    body = json.dumps(request).encode()
    connection.sendall(len(body).to_bytes(4, "big") + body)
    with connection.makefile("rb") as reader:
        header = reader.read(4)
        require(len(header) == 4, "The permission probe response has no complete frame header.")
        size = int.from_bytes(header, "big")
        require(0 < size <= 1_048_576, "The permission probe response exceeds its frame limit.")
        response = reader.read(size)
        require(len(response) == size, "The permission probe response frame is incomplete.")
    return {"socketPeerPID": peer_pid, "capabilities": NATIVE.decode_response(json.loads(response), request_id)}


def require_permission_removed(before, after, helper, all_services=False):
    initial = [row for rows in permission_rows(before, BUNDLE_ID).values() for row in rows
               if row["service"] == "kTCCServiceScreenCapture" and row["auth_value"] == 2]
    require(bool(initial), "No actual bundle-scoped Screen Recording grant existed before maintenance.")
    remaining = [row for rows in permission_rows(after, BUNDLE_ID).values() for row in rows
                 if all_services or row["service"] == "kTCCServiceScreenCapture"]
    require(not remaining, f"App permission records remain after maintenance: {remaining}.")
    witnesses = permission_rows(before, str(helper))
    require(any(witnesses.values()), "No independent helper permission exists to prove scoped reset.")
    require(witnesses == permission_rows(after, str(helper)), "Maintenance changed the helper's unrelated permissions.")


def target_identifier(elements, kind, name=None, required=True):
    candidates = {element["identifier"] for element in elements
                  if element.get("identifier", "").startswith(f"recording.target.{kind}.")
                  and (name is None or any(name in str(element.get(key, ""))
                                           for key in ("title", "description", "AXValue", "content")))}
    require(len(candidates) <= 1 and (candidates or not required),
            f"Expected one {kind} recording target, found {sorted(candidates)}.")
    return candidates.pop() if candidates else None


def require_failed_recording(session, partial, blocked):
    require(session["origin"] == "human" and session["state"] == "failed" and session["stopReason"] == "maintenance",
            f"Maintenance did not retain a failed manual recording: {session}.")
    require(session.get("failure", {}).get("code") == "storage_failed"
            and "Cannot publish the completed artifact" in session["failure"].get("message", ""),
            "Recording failed for a reason other than the reserved publication destination.")
    recordings = [artifact for artifact in session["artifacts"] if artifact["kind"] == "recording"]
    require(len(recordings) == 1 and recordings[0]["state"] == "failed"
            and not recordings[0].get("path") and not recordings[0].get("sha256"),
            "Failed recording was reported as a published movie.")
    require(partial.is_file() and not partial.is_symlink() and partial.stat().st_size > 0,
            "Failed recording lost its real partial movie.")
    require(blocked.is_dir() and not blocked.is_symlink() and not list(blocked.iterdir()),
            "Recording publication replaced the reserved destination.")


def exact_trashed_bundle(trash, identity, expected):
    require(trash.is_dir() and not trash.is_symlink(), "Current account Trash is not a real directory.")
    matches = []
    for path in trash.iterdir():
        metadata = path.lstat()
        if (metadata.st_dev, metadata.st_ino) == identity:
            matches.append(path)
    require(len(matches) == 1, "The exact running app inode was not found once in the current account's Trash.")
    require(tree_hashes(matches[0]) == expected, "The trashed app's contents differ from the running Release bundle.")
    return matches[0]


class Run(SETUP.Run):
    def preflight(self):
        super().preflight()
        with self.evidence.step("real_disposable_runner_account") as step:
            import pwd
            if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
                raise Blocked("Destructive maintenance evaluation requires a disposable GitHub macOS runner.")
            actual_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
            require(Path.home().resolve() == actual_home, "HOME is not the actual runner account home. It does not isolate TCC or ServiceManagement.")
            require(self.args.app.resolve() == Path("/Applications/ShareX.app"), "Maintenance gate requires the dedicated /Applications/ShareX.app installation.")
            self.command(["/usr/bin/sudo", "-n", "/usr/bin/true"], timeout=5)
            step.update(uid=os.getuid(), home=str(actual_home), identityScope="Actual runner account")
        self.start_app()
        require(self.capabilities["access"]["screenRecordingGranted"], "The installed Release app lacks Screen Recording permission.")
        self.root = Path(self.capabilities["sessionRoot"])
        self.prepare_fixture()

    def defaults(self, domain=BUNDLE_ID):
        result = self.command(["/usr/bin/defaults", "export", domain, "-"], check=False)
        if result["exitCode"]:
            require("does not exist" in result["stderr"], f"Could not inspect defaults for {domain}: {result}.")
            return None
        return plistlib.loads(result["stdout"].encode())

    def permissions(self):
        response = self.command(["/usr/bin/sudo", "-n", sys.executable, "-c", TCC_QUERY,
                                 Path.home(), BUNDLE_ID, self.args.helper])
        value = json.loads(response["stdout"])
        require(value, "No real TCC database was inspected.")
        return value

    def login(self):
        value = self.command(["/usr/bin/sudo", "-n", "/usr/bin/sfltool", "dumpbtm"], timeout=15)
        return login_records(value["stdout"], self.args.app)

    def capture_ui(self, label):
        self.control("back")
        source = self.evidence.directory / (label + "-full.png")
        preview = self.evidence.directory / (label + ".png")
        self.helper("screenshot", output=source)
        self.command(["/usr/bin/sips", "-Z", "900", source, "--out", preview], timeout=10)
        require(0 < preview.stat().st_size <= 250_000, "Native UI preview exceeds the bounded job-log image size.")
        self.evidence.emit("ui_preview", path=str(preview), sha256=NATIVE.digest(preview))
        print(f"E2E_IMAGE {preview.name} {base64.b64encode(preview.read_bytes()).decode('ascii')}", flush=True)

    def open_recording(self):
        self.helper("menu", title="Record Screen…")
        self.inspect("recording.status")

    def require_busy(self):
        elements = self.helper("snapshot")["elements"]
        require(not any(item.get("identifier") == "recording.start" and item.get("AXEnabled") == 1 for item in elements),
                "Human UI permits a second recording while the shared slot is occupied.")

    def open_maintenance(self):
        self.helper("menu", title="Settings…")
        self.helper("select", identifier="settings.page.maintenance")
        self.inspect("maintenance.reset")

    def enable_agents(self, enabled):
        self.open_agents_settings()
        if self.cli("capabilities")["access"]["enabled"] != enabled:
            self.press("settings.agents.enabled")
        self.access(enabled)

    def manifest(self, session_id):
        return json.loads((self.root / str(uuid.UUID(session_id)).upper() / "manifest.json").read_text(encoding="utf-8"))

    def start_human(self, mode, cursor=False):
        self.control("stage", stage=0)
        self.control("front", floating=False)
        self.open_recording()
        self.wait_for(lambda: self.inspect("recording.refresh").get("AXEnabled") == 1,
                      15, "initial recording target refresh")
        self.press("recording.refresh")

        def target_ready():
            elements = self.helper("snapshot")["elements"]
            if not any(item.get("identifier") == "recording.refresh" and item.get("AXEnabled") == 1 for item in elements):
                return None
            return target_identifier(elements, mode, self.geometry["title"] if mode == "window" else None, required=False)

        identifier = self.wait_for(target_ready, 15, f"refreshed {mode} recording target")
        self.helper("select", identifier=identifier)
        current = self.inspect("recording.cursor").get("AXValue")
        require(current in (0, 1, "0", "1"), "Cursor control does not expose a boolean value.")
        if int(current) != int(cursor):
            self.press("recording.cursor")
        if not self.sessions:
            self.capture_ui("manual-recording-window")
        before = SETUP.session_folders(self.root)
        self.control("front", floating=mode == "display")
        self.press("recording.start")

        def ready():
            added = SETUP.session_folders(self.root) - before
            require(len(added) <= 1, "One manual start created multiple session directories.")
            if not added:
                return None
            session = self.manifest(next(iter(added)))
            require(session.get("origin") == "human", "Manual recording was not persisted with human ownership.")
            require(session["state"] not in NATIVE.TERMINAL, f"Manual start failed: {session}.")
            return session if session["state"] == "recording" and session["acceptedFrames"] > 0 else None

        session = self.wait_for(ready, 15, "manual recording's first accepted frame")
        self.owned_session_ids.add(session["id"])
        require(session["source"]["kind"] == mode and session["selection"]["includeCursor"] is cursor,
                "Manual target or cursor option does not match the selected UI control.")
        require(session["options"] == {"fps": 30, "maxDurationSeconds": 1800, "maxBytes": 2_147_483_648},
                "Manual recording did not use the documented default limits.")
        if mode == "window":
            require(session["source"]["name"] == self.geometry["title"], "Manual capture selected a different window.")
            require(session["source"]["widthPoints"] == 640 and session["source"]["heightPoints"] == 480
                    and session["source"]["pixelScale"] == self.geometry["scale"],
                    "Manual window geometry differs from the independent fixture.")
            self.window_target = session["source"]
        else:
            require(session["source"]["widthPoints"] == self.geometry["displayBounds"]["width"]
                    and session["source"]["heightPoints"] == self.geometry["displayBounds"]["height"],
                    "Manual display geometry differs from the independent fixture's display.")
            self.display_target = session["source"]
        self.require_busy()
        require(self.inspect("recording.stop").get("AXEnabled") == 1, "Manual recording has no enabled Stop control.")
        require(re.search(r"\b\d{2}:\d{2}\b", self.inspect("recording.status").get("content", "")),
                "Manual recording does not show its elapsed duration.")
        self.control("front", floating=mode == "display")
        return session

    def verify_human(self, session_id, mode, stages=(0,), reason="user_stop"):
        ended = self.read_terminal(session_id)
        require(ended["origin"] == "human" and ended["state"] == "completed" and ended["stopReason"] == reason,
                f"Manual recording did not finalize with the expected owner and reason: {ended}.")
        self.validate_manifest(ended)
        decoded = self.validate_media(ended, mode, "recording", list(stages), minimum=1, maximum=120)
        return ended, decoded

    def reject_human_mutations(self, session_id, target):
        before = self.manifest(session_id)
        for operation, arguments in (
            ("recording.stop", {"sessionID": session_id}),
            ("session.mark", {"sessionID": session_id, "label": "must not be added", "outcome": "failed"}),
            ("screenshot", {"sessionID": session_id, "target": target}),
        ):
            self.cli(operation, arguments, error="permission_denied")
        after = self.manifest(session_id)
        for field in ("origin", "state", "markers", "artifacts"):
            require(after[field] == before[field], f"Agent mutation changed a human session's {field}.")

    def recording_stories(self):
        with self.evidence.step("manual_display_with_agents_disabled_close_reopen_menu_stop") as step:
            self.enable_agents(False)
            self.cli("targets.list", error="disabled")
            session = self.start_human("display", cursor=True)
            self.helper("close-window", title=RECORDING_WINDOW)
            time.sleep(2)
            require(self.manifest(session["id"])["state"] == "recording", "Closing the recording window stopped capture.")
            self.open_recording()
            require(self.inspect("recording.stop").get("AXEnabled") == 1, "Reopened recording window lost its active session.")
            self.helper("menu", title="Stop Recording")
            ended, step["decoded"] = self.verify_human(session["id"], "display")
            require(self.inspect("recording.reveal").get("AXEnabled") == 1, "Completed manual recording has no Reveal MP4 control.")
            self.press("recording.reveal")
            require(self.cli("capabilities")["access"]["enabled"] is False
                    and self.defaults().get("agentCaptureEnabled") is False, "Manual recording changed agent opt-in.")
            step["sessionID"] = ended["id"]
        with self.evidence.step("manual_window_with_agents_disabled_ui_stop") as step:
            session = self.start_human("window")
            time.sleep(2)
            self.press("recording.stop")
            _, step["decoded"] = self.verify_human(session["id"], "window")
            require(self.cli("capabilities")["access"]["enabled"] is False
                    and self.defaults().get("agentCaptureEnabled") is False, "Window recording changed agent opt-in.")
        with self.evidence.step("human_owner_rejects_agents_and_slot_contention") as step:
            self.enable_agents(True)
            session = self.start_human("window")
            target = session["source"]["token"]
            self.cli("recording.start", {"target": target}, error="busy")
            self.reject_human_mutations(session["id"], target)
            time.sleep(1.2)
            self.press("recording.stop")
            _, step["decoded"] = self.verify_human(session["id"], "window")
            self.quit_app()
            self.start_app()
            targets = self.cli("targets.list")["targets"]
            target = next(item["token"] for item in targets if item["kind"] == "window" and item["name"] == self.geometry["title"])
            self.reject_human_mutations(session["id"], target)
            step["ownershipSurvivedRestart"] = True
            started = self.cli("recording.start", {"target": target, "maxDurationSeconds": 30, "fps": 15})
            self.open_recording()
            self.require_busy()
            self.control("front")
            time.sleep(1.2)
            ended = self.cli("recording.stop", {"sessionID": started["id"]})
            self.validate_manifest(ended)
            self.validate_media(ended, "window", "recording", [0], minimum=1, maximum=30)
            self.enable_agents(False)

    def maintenance_snapshot(self, include_evidence=True):
        result = {"defaults": self.defaults(), "permissions": self.permissions(), "login": self.login(),
                  "wrapper": self.wrapper.read_bytes().hex(), "bundle": tree_hashes(self.args.app)}
        if include_evidence:
            result["evidence"] = tree_hashes(self.root)
        return result

    def cancel_maintenance(self, operation):
        self.open_maintenance()
        before = self.maintenance_snapshot()
        self.press(f"maintenance.{operation}")
        self.inspect("maintenance.confirm")
        self.capture_ui("maintenance-" + operation + "-confirmation")
        self.press("maintenance.cancel")
        require(self.maintenance_snapshot() == before, f"Cancelling {operation} changed account, evidence or installation state.")

    def wait_exit(self):
        try:
            self.wait_for(lambda: self.app.poll() is not None, 30, "maintenance to quit the owned app")
        except Failure:
            try:
                sample = self.evidence.directory / "termination-sample.txt"
                self.command(["/usr/bin/sample", str(self.app.pid), "2", "-file", sample], timeout=10, check=False)
                if sample.is_file():
                    self.evidence.emit("termination_sample", text=sample.read_text(encoding="utf-8", errors="replace")[:30000])
            except Exception as diagnostic:
                self.evidence.emit("termination_sample_unavailable", reason=str(diagnostic))
            raise
        require(self.app.returncode == 0, f"Maintenance exited with code {self.app.returncode}.")

    def maintenance_stories(self):
        with self.evidence.step("cancel_permission_reset_and_uninstall_preserves_state"):
            self.cancel_maintenance("reset")
            self.cancel_maintenance("uninstall")
        with self.evidence.step("reset_permission_finalizes_manual_capture_and_quits") as step:
            retained = tree_hashes(self.root)
            session = self.start_human("window")
            time.sleep(1.2)
            self.open_maintenance()
            before = self.permissions()
            defaults, login = self.defaults(), self.login()
            wrapper, bundle = NATIVE.digest(self.wrapper), tree_hashes(self.args.app)
            self.press("maintenance.reset")
            self.press("maintenance.confirm")
            self.wait_exit()
            ended, step["decoded"] = self.verify_human(session["id"], "window", reason="maintenance")
            after = self.permissions()
            require_permission_removed(before, after, self.args.helper)
            require(NATIVE.digest(self.wrapper) == wrapper and tree_hashes(self.args.app) == bundle,
                    "Permission reset changed the CLI or installed app.")
            require(self.defaults() == defaults and self.login() == login, "Permission reset changed preferences or launch at login.")
            after_files = tree_hashes(self.root)
            require(all(after_files.get(name) == value for name, value in retained.items()), "Permission reset changed prior capture evidence.")
            step.update(sessionID=ended["id"], permissionScope=BUNDLE_ID, retainedEvidenceEntries=len(retained))
        with self.evidence.step("permission_reset_visible_after_restart") as step:
            step.update(self.restore_permission_after_reset())
        self.failed_recording_story()
        with self.evidence.step("failed_recording_reset_visible_after_restart") as step:
            step.update(self.restore_permission_after_reset())
        self.uninstall_stories()

    def application_processes(self):
        response = SETUP.decode_helper(self.command(
            [self.args.helper, "--action", "applications", "--bundle-id", BUNDLE_ID], timeout=5, check=False))
        running = self.command(["/usr/bin/pgrep", "-x", self.binary.name], timeout=5, check=False)
        require(running["exitCode"] in (0, 1), "Could not enumerate ShareX processes.")
        return {"applications": response["applications"], "pids": sorted(int(pid) for pid in running["stdout"].split())}

    def launch_services_capabilities(self, phase):
        require(self.app is None or self.app.poll() is not None, "The directly owned app must exit before the permission probe.")
        empty = {"applications": [], "pids": []}
        require(self.application_processes() == empty, "A ShareX app is already running before the permission probe.")
        permissions_before = self.permissions()
        launched_at = time.time()
        launcher = self.launch(["/usr/bin/open", "-n", "-W", self.args.app, "--args", "--agent-background"], "launch-services")
        application = None

        def ready():
            nonlocal application
            require(launcher.poll() is None, "LaunchServices exited before the app permission probe was ready.")
            processes = self.application_processes()
            applications = processes["applications"]
            require(len(applications) <= 1 and len(processes["pids"]) <= 1,
                    "LaunchServices started more than one ShareX app.")
            if not applications:
                return None
            current = applications[0]
            require(current["bundleID"] == BUNDLE_ID and current["bundlePath"] == str(self.args.app.resolve())
                    and current["executablePath"] == str(self.binary.resolve())
                    and current["launchTime"] >= launched_at - 1 and current["pid"] > 0
                    and current["pid"] != launcher.pid,
                    f"LaunchServices did not start the exact installed ShareX app: {current}.")
            require(application is None or application == current, "The LaunchServices app identity changed during startup.")
            application = current
            if not processes["pids"]:
                return None
            require(processes["pids"] == [application["pid"]], "The permission probe does not own the only ShareX process.")
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(5)
                    connection.connect(str(self.agent_endpoint()))
                    response = permission_probe_response(connection, application["pid"])
            except (FileNotFoundError, ConnectionRefusedError):
                return None
            require(self.application_processes() == processes, "The permission probe app exited or changed identity.")
            observation = {"phase": phase, "launcherPID": launcher.pid, "application": application,
                           **response,
                           "permissionsBefore": permissions_before, "permissionsAfter": self.permissions()}
            self.evidence.emit("launch_services_permission_probe", **observation)
            return observation

        try:
            return self.wait_for(ready, 20, "LaunchServices app permission response")
        finally:
            try:
                if application is not None:
                    processes = self.application_processes()
                    if processes != empty:
                        require(processes == {"applications": [application], "pids": [application["pid"]]},
                                "Refusing to terminate a different ShareX app after the permission probe.")
                        self.control("terminate-observed", observedPID=application["pid"])
                    self.wait_for(lambda: self.application_processes() == empty, 20, "actual LaunchServices app PID to exit")
                    self.evidence.emit("launch_services_app_exited", phase=phase, pid=application["pid"])
                    launcher.wait(timeout=5)
                    self.evidence.emit("launch_services_launcher_exited", phase=phase, pid=launcher.pid,
                                       launcherExitCode=launcher.returncode)
            finally:
                NATIVE.stop_process(launcher)

    def restore_permission_after_reset(self):
        denied = self.launch_services_capabilities("after-reset")
        require(denied["capabilities"]["access"]["screenRecordingGranted"] is False,
                "The app still reports Screen Recording permission after reset and restart.")
        self.command(["/bin/bash", NATIVE.ROOT / "ci-capture-permissions.sh", self.args.app])
        granted = self.launch_services_capabilities("after-ci-regrant")
        require(granted["capabilities"]["access"]["screenRecordingGranted"] is True,
                "The LaunchServices app did not observe the restored app-scoped grant.")
        require(denied["application"]["pid"] != granted["application"]["pid"], "Permission probes reused an app PID.")
        self.start_app()
        require(self.capabilities["access"]["screenRecordingGranted"] is True,
                "Runner could not restore its app-scoped grant for remaining maintenance evaluation.")
        return {"denied": denied, "granted": granted, "resumedAppPID": self.app.pid}

    def enable_launch_at_login(self):
        self.helper("menu", title="Settings…")
        self.helper("select", identifier="settings.page.capture")
        if int(self.inspect("settings.startup.enabled")["AXValue"]) == 0:
            self.press("settings.startup.enabled")
        return self.wait_for(lambda: records if (records := self.login()) and any(item["enabled"] for item in records) else None,
                             15, "actual login-item registration")

    @contextmanager
    def blocked_recording_publish(self, session):
        directory = self.root / str(uuid.UUID(session["id"])).upper()
        recordings = [artifact for artifact in session["artifacts"] if artifact["kind"] == "recording"]
        require(len(recordings) == 1, "Publication fixture requires exactly one recording artifact.")
        folder = directory / str(uuid.UUID(recordings[0]["id"])).upper()
        partial = folder / "capture.partial.mp4"
        require(partial.is_file() and not partial.is_symlink() and folder.resolve().is_relative_to(directory.resolve()),
                "Publication fixture requires the owned recording's real partial file.")
        blocked = folder / "capture.mp4"
        blocked.mkdir()
        try:
            yield partial, blocked
        finally:
            require(blocked.is_dir() and not blocked.is_symlink() and not list(blocked.iterdir()),
                    "App changed the reserved recording destination; it was not removed.")
            blocked.rmdir()

    def retry_review(self):
        self.press("maintenance.retry")
        self.inspect("maintenance.confirm")
        elements = self.helper("snapshot")["elements"]
        text = json.dumps(elements)
        require("The previous attempt stopped:" in text and "Incomplete recording evidence is preserved" in text
                and "Confirm again to continue the remaining cleanup" in text,
                "Retry omitted the prior failure or fresh-confirmation disclosure.")
        require(self.app.poll() is None, "Retry quit before fresh confirmation.")
        return elements

    def failed_recording_story(self):
        with self.evidence.step("recording_publication_failure_preserves_state_and_requires_retry_confirmation") as step:
            self.enable_launch_at_login()
            retained = tree_hashes(self.root)
            session = self.start_human("window")
            time.sleep(1.2)
            with self.blocked_recording_publish(session) as (partial, blocked):
                partial_identity = partial.stat()
                self.open_maintenance()
                before = self.maintenance_snapshot(include_evidence=False)
                self.press("maintenance.reset")
                self.inspect("maintenance.confirm")
                require(self.cli("capabilities").get("activeSessionID") == session["id"],
                        "Recording failed before maintenance confirmation.")
                self.press("maintenance.confirm")
                step["failureUI"] = self.refusal(timeout=45)
                require("The recording could not be saved" in json.dumps(step["failureUI"]),
                        "Maintenance did not report the recording save failure.")
                ended = self.read_terminal(session["id"])
                require_failed_recording(ended, partial, blocked)
                require((partial.stat().st_dev, partial.stat().st_ino) == (partial_identity.st_dev, partial_identity.st_ino),
                        "Failed recording replaced its partial evidence file.")
                self.validate_manifest(ended)
                require(self.maintenance_snapshot(include_evidence=False) == before,
                        "Recording save failure changed account or installation state.")
                after_files = tree_hashes(self.root)
                require(all(after_files.get(name) == value for name, value in retained.items()),
                        "Recording save failure changed earlier capture evidence.")
                require("Recording failed" in self.inspect("recording.status").get("content", "")
                        and "Show Evidence Folder" in self.inspect("recording.reveal").get("content", ""),
                        "Failed recording UI offers a successful movie instead of incomplete evidence.")
                self.capture_ui("maintenance-recording-failure")
                step["retryReview"] = self.retry_review()
                require(self.maintenance_snapshot(include_evidence=False) == before and tree_hashes(self.root) == after_files,
                        "Retry review performed cleanup before confirmation.")
                self.press("maintenance.cancel")
                self.refusal()
                require(self.maintenance_snapshot(include_evidence=False) == before and tree_hashes(self.root) == after_files,
                        "Cancelling retry changed account, installation or incomplete evidence.")
                self.retry_review()
                self.press("maintenance.confirm")
                self.wait_exit()
                require_permission_removed(before["permissions"], self.permissions(), self.args.helper)
                require({key: value for key, value in self.maintenance_snapshot(include_evidence=False).items() if key != "permissions"}
                        == {key: value for key, value in before.items() if key != "permissions"},
                        "Confirmed reset retry changed app, CLI, preferences or login registration.")
                require(tree_hashes(self.root) == after_files, "Reset retry changed the failed recording evidence.")
                step.update(sessionID=ended["id"], partialSHA256=NATIVE.digest(partial), partialBytes=partial.stat().st_size,
                            retainedEvidenceEntries=len(retained))

    @contextmanager
    def immutable_bundle(self):
        app = self.args.app
        original = app.lstat()
        require(stat.S_ISDIR(original.st_mode) and original.st_uid == os.getuid()
                and not original.st_flags & stat.UF_IMMUTABLE,
                "Immutable fixture requires the owned app directory without an existing immutable flag.")
        try:
            self.command(["/usr/bin/chflags", "uchg", app])
            require(app.lstat().st_flags & stat.UF_IMMUTABLE, "Runner could not make the app directory immutable.")
            yield
        finally:
            current = app.lstat()
            require((current.st_dev, current.st_ino) == (original.st_dev, original.st_ino),
                    "Immutable app fixture moved or changed identity; no replacement was modified.")
            self.command(["/usr/bin/chflags", "nouchg", app])
            require(not app.lstat().st_flags & stat.UF_IMMUTABLE, "Runner could not clear its immutable app fixture.")

    @contextmanager
    def foreign_wrapper(self):
        original = self.wrapper.read_bytes()
        require(original == SETUP.wrapper_content(self.binary.resolve()).encode(), "Cannot replace a CLI wrapper this gate does not own.")
        marker = (SETUP.WRAPPER_PREFIX + 'exec /bin/echo "unrelated command"\n').encode()
        self.wrapper.write_bytes(marker)
        try:
            yield marker
        finally:
            require(self.wrapper.is_file() and self.wrapper.read_bytes() == marker, "App changed the foreign wrapper fixture.")
            self.wrapper.write_bytes(original)

    @contextmanager
    def replaced_bundle(self):
        app = self.args.app
        displaced = app.with_name("ShareX-maintenance-owned-" + str(uuid.uuid4()) + ".app")
        app.rename(displaced)
        app.mkdir()
        sentinel = app / "unrelated-file.txt"
        sentinel.write_text("This replacement is not the running app.\n", encoding="utf-8")
        try:
            yield
        finally:
            require(app.is_dir() and list(app.iterdir()) == [sentinel]
                    and sentinel.read_text(encoding="utf-8") == "This replacement is not the running app.\n",
                    f"App changed the unrelated bundle replacement. Original remains at {displaced}.")
            sentinel.unlink()
            app.rmdir()
            displaced.rename(app)

    def refusal(self, timeout=15):
        def ready():
            elements = self.helper("snapshot")["elements"]
            return elements if any(item.get("identifier") == "maintenance.retry" for item in elements) else None
        result = self.wait_for(ready, timeout, "visible maintenance refusal and Retry control")
        require(self.app.poll() is None, "Rejected maintenance quit the app.")
        return result

    def uninstall_stories(self):
        with self.evidence.step("foreign_wrapper_review_and_cancel_preserves_command") as step:
            self.open_maintenance()
            with self.foreign_wrapper():
                before = self.maintenance_snapshot()
                self.press("maintenance.uninstall")
                self.inspect("maintenance.confirm")
                text = json.dumps(self.helper("snapshot")["elements"])
                require("Keep ~/.local/bin/sharex" in text, "Uninstall review does not explain preservation of the foreign command.")
                self.press("maintenance.cancel")
                require(self.maintenance_snapshot() == before, "Cancelling foreign-wrapper uninstall changed state.")
                step["foreignCommandPreserved"] = True
        with self.evidence.step("foreign_marker_wrapper_is_preserved") as step:
            self.open_maintenance()
            self.press("maintenance.uninstall")
            self.inspect("maintenance.confirm")
            with self.foreign_wrapper() as marker:
                before = self.maintenance_snapshot()
                self.press("maintenance.confirm")
                step["refusal"] = self.refusal()
                require(self.maintenance_snapshot() == before, "Foreign-wrapper rejection changed installation or account state.")
                require(self.wrapper.read_bytes() == marker, "Foreign marker wrapper was removed or overwritten.")
            self.press("maintenance.retry")
            self.inspect("maintenance.confirm")
            self.press("maintenance.cancel")
        with self.evidence.step("replaced_bundle_is_rejected_before_cleanup") as step:
            self.open_maintenance()
            self.press("maintenance.uninstall")
            self.inspect("maintenance.confirm")
            with self.replaced_bundle():
                before = self.maintenance_snapshot()
                self.press("maintenance.confirm")
                step["refusal"] = self.refusal()
                require(self.maintenance_snapshot() == before, "Bundle replacement rejection changed account state or evidence.")
            self.press("maintenance.retry")
            self.inspect("maintenance.confirm")
            self.press("maintenance.cancel")
        with self.evidence.step("real_uninstall_preserves_evidence_and_trashes_exact_bundle") as step:
            before_login = self.enable_launch_at_login()
            self.open_maintenance()
            screenshot = Path.home() / "Pictures" / ("ShareX-retained-" + str(uuid.uuid4()) + ".png")
            screenshot.parent.mkdir(parents=True, exist_ok=True)
            self.helper("screenshot", output=screenshot)
            unrelated = self.wrapper.parent / ("sharex-unrelated-" + str(uuid.uuid4()))
            unrelated.write_text("Unrelated user command\n", encoding="utf-8")
            foreign_domain = "com.sharexmac.NativeGate.Unrelated"
            self.command(["/usr/bin/defaults", "write", foreign_domain, "retained", "-string", str(uuid.uuid4())])
            evidence = tree_hashes(self.root)
            before_permissions = self.permissions()
            before_defaults = self.defaults(foreign_domain)
            retained = {str(path): NATIVE.digest(path) for path in (screenshot, unrelated)}
            app_stat = self.args.app.stat()
            bundle = tree_hashes(self.args.app)

            def require_cleanup():
                require(not self.wrapper.exists() and not self.wrapper.is_symlink(), "Uninstall left the exact managed CLI installed.")
                require(self.defaults() in (None, {}), "Uninstall left app preferences in the real account domain.")
                require_permission_removed(before_permissions, self.permissions(), self.args.helper, all_services=True)
                require(not any(item["enabled"] for item in self.login()), "Uninstall left an enabled login registration.")
                require(tree_hashes(self.root) == evidence, "Uninstall changed retained capture evidence.")
                require(self.defaults(foreign_domain) == before_defaults, "Uninstall changed unrelated app preferences.")
                require({path: NATIVE.digest(Path(path)) for path in retained} == retained, "Uninstall changed unrelated user files.")

            with self.evidence.step("partial_uninstall_reports_completed_cleanup_before_retry") as failure_step:
                with self.immutable_bundle():
                    self.press("maintenance.uninstall")
                    self.inspect("maintenance.confirm")
                    self.press("maintenance.confirm")
                    failure_step["failureUI"] = self.refusal(timeout=45)
                    text = json.dumps(failure_step["failureUI"])
                    completed = ["Capture stopped. Completed recordings are saved.", "Launch at login is unregistered.",
                                 "Removed the exact ShareX CLI wrapper", "ShareX preferences are cleared.", "ShareX permissions are reset."]
                    require(all(message in text for message in completed), "Partial uninstall omitted its completed cleanup actions.")
                    require_cleanup()
                    require(tree_hashes(self.args.app) == bundle, "Failed Trash move changed the installed app contents.")
                    failure_step.update(completedActions=completed, retainedEvidenceEntries=len(evidence))
                    self.capture_ui("maintenance-partial-uninstall-failure")
                failure_step["retryReview"] = self.retry_review()
                text = json.dumps(failure_step["retryReview"])
                require("No CLI wrapper exists at ~/.local/bin/sharex." in text,
                        "Retry reused the old CLI review after the actual wrapper was removed.")
                require_cleanup()
                require(tree_hashes(self.args.app) == bundle, "Retry review removed or changed the app before confirmation.")
            self.press("maintenance.confirm")
            self.wait_exit()
            require(not self.args.app.exists(), "Uninstall left the installed app in place.")
            trashed = exact_trashed_bundle(Path.home() / ".Trash", (app_stat.st_dev, app_stat.st_ino), bundle)
            require_cleanup()
            step.update(trashedBundle=str(trashed), retainedEvidenceFiles=len(evidence),
                        retainedFiles=retained, loginBefore=before_login, loginAfter=self.login())

    def stories(self):
        self.recording_stories()
        self.maintenance_stories()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/ShareX.app"))
    parser.add_argument("--build-settings", type=Path)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    output = args.out.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        print(json.dumps({"status": "blocked", "reason": "Evidence directory is not empty. Use a fresh --out directory."}))
        return 3
    evidence = NATIVE.Evidence(output)
    run = Run(args, evidence)
    status, code, reason = "failed", 1, None
    started = time.monotonic()
    original_handlers = {}

    def interrupted(signum, frame):
        raise Failure(f"Evaluation interrupted by signal {signum}.")

    for signum in (signal.SIGINT, signal.SIGTERM):
        original_handlers[signum] = signal.signal(signum, interrupted)
    try:
        run.preflight()
        run.stories()
        status, code = "passed", 0
    except Blocked as problem:
        status, code, reason = "blocked", 3, str(problem)
    except Exception as problem:
        reason = str(problem)
        (output / "failure.txt").write_text(traceback.format_exc(), encoding="utf-8")
        if run.app and run.app.poll() is None:
            try:
                evidence.emit("failure_ui", **run.helper("snapshot"))
            except Exception as diagnostic:
                evidence.emit("failure_ui_unavailable", reason=str(diagnostic))
    finally:
        for signum in original_handlers:
            signal.signal(signum, signal.SIG_IGN)
        cleanup_errors = run.cleanup(failed=status != "passed")
        if cleanup_errors:
            status, code, reason = "failed", 1, "Process cleanup failed: " + "; ".join(cleanup_errors)
        report = {"schemaVersion": 1, "status": status, "reason": reason,
                  "durationSeconds": time.monotonic() - started, "steps": evidence.steps,
                  "statistics": {"passedSteps": sum(step["status"] == "passed" for step in evidence.steps),
                                 "failedSteps": sum(step["status"] == "failed" for step in evidence.steps),
                                 "blockedSteps": sum(step["status"] == "blocked" for step in evidence.steps),
                                 "sessions": len(run.sessions), "artifacts": sum(session["artifacts"] for session in run.sessions)},
                  "sessions": run.sessions, "accountScope": "Actual disposable runner account; no HOME isolation"}
        NATIVE.write_json(output / "result.json", report)
        evidence.emit("run_finished", status=status, reason=reason, exitCode=code)
        evidence.events.close()
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
