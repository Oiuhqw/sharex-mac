#!/usr/bin/env python3
"""Exercise Agents setup through public macOS Accessibility and the installed Release CLI.

Compile e2e-agent-setup.swift separately and grant that executable Accessibility.
Use an unlocked desktop with ShareX Screen Recording permission already granted.
Start with agent access disabled and no running ShareX process. Successful evaluation
leaves access enabled and the managed CLI installed for the native media evaluation.
Exit codes are 0 for passed, 1 for failed, and 3 for blocked. This script never edits TCC.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import sys
import time
import traceback
import uuid


SPEC = importlib.util.spec_from_file_location("agent_capture_e2e", Path(__file__).with_name("e2e-agent-capture.py"))
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)
Blocked, Failure, require = NATIVE.Blocked, NATIVE.Failure, NATIVE.require
WRAPPER_PREFIX = "#!/bin/sh\n# ShareX managed CLI v1\n"
REFERENCE_DATE_UNIX_SECONDS = 978_307_200
DAY_SECONDS = 86_400
CAPTURE_AGE_DAYS = 30
CONFIRMATION = re.compile(r"Delete (\d+) captures? older than 30 days\?")
NOTHING_OLD = "No captures are older than 30 days."
STORED = re.compile(r"(\d+) captures? stored")


def wrapper_content(binary):
    return WRAPPER_PREFIX + "exec " + NATIVE.shell_quote(binary) + ' --agent "$@"\n'


def wire_date(unix_seconds):
    return unix_seconds - REFERENCE_DATE_UNIX_SECONDS


def aged_manifest(manifest, days, now):
    shift = wire_date(now - days * DAY_SECONDS) - manifest["endedAt"]

    def shifted(record, keys):
        return {**record, **{key: record[key] + shift for key in keys if isinstance(record.get(key), (int, float))}}

    return {**shifted(manifest, ("createdAt", "startedAt", "endedAt")),
            "artifacts": [shifted(artifact, ("createdAt",)) for artifact in manifest["artifacts"]]}


def write_private_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def session_folders(root):
    folders = set()
    for directory in root.iterdir():
        try:
            folders.add(str(uuid.UUID(directory.name)).upper())
        except ValueError:
            continue
    return folders


def old_final_sessions(root, now):
    found = set()
    for name in session_folders(root):
        directory = root / name
        manifest = directory / "manifest.json"
        if directory.is_symlink() or not manifest.is_file() or directory.stat().st_mode & 0o077:
            continue
        try:
            session = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        dates = [session.get("createdAt"), *(artifact.get("createdAt") for artifact in session.get("artifacts", []))]
        if session.get("endedAt") is not None:
            dates.append(session["endedAt"])
        if (session.get("state") in NATIVE.TERMINAL and all(isinstance(date, (int, float)) for date in dates)
                and wire_date(now) - max(dates) > CAPTURE_AGE_DAYS * DAY_SECONDS):
            found.add(name)
    return found


def confirmation(elements):
    matches = {(match.group(0), int(match.group(1))) for element in elements
               for key in ("title", "description", "AXValue") if isinstance(element.get(key), str)
               for match in [CONFIRMATION.search(element[key])] if match}
    counts = {count for _, count in matches}
    require(len(counts) <= 1, f"Settings shows conflicting delete confirmations: {sorted(matches)}.")
    return {"text": min(matches)[0], "count": counts.pop()} if matches else None


def nothing_old(elements):
    shown = any(NOTHING_OLD in element[key] for element in elements
                for key in ("title", "description", "AXValue") if isinstance(element.get(key), str))
    require(not shown or all(element.get("identifier") != "settings.agents.deleteOld.confirm" for element in elements),
            "Settings offers Delete when no capture is older than 30 days.")
    return shown


def stored_count(element):
    match = STORED.search(json.dumps(element))
    require(match is not None, f"settings.agents.storage does not read 'N captures stored': {element}.")
    return int(match.group(1))


def check_wrapper_destination(wrapper, uid=None):
    uid = os.getuid() if uid is None else uid
    for directory in (wrapper.parent.parent, wrapper.parent):
        if directory.exists() or directory.is_symlink():
            metadata = directory.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid or metadata.st_mode & 0o022:
                raise Blocked(f"CLI directory is not a private, user-owned real directory: {directory}.")
    if not wrapper.exists() and not wrapper.is_symlink():
        return
    metadata = wrapper.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid or metadata.st_nlink != 1
            or metadata.st_mode & 0o022 or metadata.st_size > 16_384):
        raise Blocked(f"An unrelated or unsafe command exists at {wrapper}. It was not changed.")
    if not wrapper.read_bytes().startswith(WRAPPER_PREFIX.encode()):
        raise Blocked(f"An unrelated command exists at {wrapper}. It was not changed.")


def decode_helper(result):
    try:
        response = json.loads(result["stdout"])
    except json.JSONDecodeError as problem:
        raise Failure("Accessibility helper did not return one JSON result.") from problem
    if response.get("status") == "blocked" and result["exitCode"] == 3:
        raise Blocked(response.get("reason", "Accessibility helper is blocked."))
    require(response.get("status") == "passed" and result["exitCode"] == 0,
            f"Accessibility action failed: {response}.")
    return response


def validate_recording_files(session, session_root, evidence_directory):
    require(session["state"] == "completed", "UI stop did not complete the recording.")
    directory = session_root / str(uuid.UUID(session["id"])).upper()
    require(directory.is_dir() and not directory.is_symlink(), "Recording session directory is not a real directory.")
    require(directory.resolve().is_relative_to(session_root.resolve()), "Recording session escaped its storage root.")
    recordings = [artifact for artifact in session["artifacts"] if artifact["kind"] == "recording"]
    require(len(recordings) == 1, "UI recording must have exactly one video artifact.")
    artifact = recordings[0]
    source = Path(artifact["path"])
    require(source.is_absolute() and source.is_file() and not source.is_symlink()
            and source.resolve().is_relative_to(directory.resolve()), "Recording artifact escaped its session directory.")
    require(artifact["state"] == "completed" and artifact["byteCount"] > 0
            and source.stat().st_size == artifact["byteCount"] and NATIVE.digest(source) == artifact["sha256"],
            "UI recording artifact has incomplete or mismatched bytes.")
    require(artifact.get("durationSeconds", 0) > 0 and session.get("acceptedFrames", 0) > 0,
            "UI recording has no accepted frames or duration.")
    destination = evidence_directory / f"{session['id']}-{artifact['id']}{source.suffix}"
    require(not destination.exists(), "Recording evidence already exists.")
    shutil.copyfile(source, destination)
    return artifact


class Run(NATIVE.Run):
    def helper(self, action, **options):
        command = [self.args.helper, "--action", action]
        if self.app:
            require(self.app.poll() is None, "The owned ShareX app exited during UI evaluation.")
            command.extend(["--pid", self.app.pid])
        for key, value in options.items():
            command.extend(["--" + key, value])
        return decode_helper(self.command(command, timeout=20, check=False))

    def inspect(self, identifier):
        return self.helper("inspect", identifier=identifier)["element"]

    def press(self, identifier):
        return self.helper("press", identifier=identifier)

    def stored(self):
        return stored_count(self.inspect("settings.agents.storage"))

    def delete_confirmation(self):
        return self.wait_for(lambda: confirmation(self.helper("snapshot")["elements"]), 15, "delete confirmation text")

    def open_agents_settings(self):
        self.helper("menu", title="Settings…")
        self.helper("select", identifier="settings.page.agents")

    def screenshot(self, label):
        path = self.evidence.path(label, "png")
        try:
            self.helper("screenshot", output=path)
            require(path.stat().st_size > 0, "Screenshot evidence is empty.")
            self.evidence.emit("screenshot", path=str(path), sha256=NATIVE.digest(path))
        except Blocked as problem:
            self.evidence.emit("screenshot_unavailable", reason=str(problem))

    def access(self, enabled):
        self.capabilities = self.wait_for(
            lambda: value if (value := self.cli("capabilities"))["access"]["enabled"] is enabled else None,
            8, f"agent access {enabled}")
        element = self.inspect("settings.agents.enabled")
        require(element.get("AXValue") in (int(enabled), str(int(enabled))),
                "The Agents toggle does not match the production CLI access state.")
        return self.capabilities

    def preflight(self):
        with self.evidence.step("installed_release_and_desktop_prerequisites") as step:
            if sys.platform != "darwin":
                raise Blocked("Agents setup requires macOS. This run did not execute native UI or capture.")
            identity = NATIVE.installed_release_identity(self.args.app, self.args.build_settings, self.command)
            self.binary = Path(identity["binary"])
            self.bundle_id = identity["bundleID"]
            step.update(identity)
        with self.evidence.step("external_accessibility_and_cli_destination") as step:
            if not self.args.helper or not self.args.helper.is_file() or not os.access(self.args.helper, os.X_OK):
                raise Blocked("Pass --helper with the compiled, Accessibility-approved e2e-agent-setup executable.")
            self.args.helper = self.args.helper.resolve()
            step["helper"] = str(self.args.helper)
            step["helperSHA256"] = NATIVE.digest(self.args.helper)
            step["permissions"] = self.helper("preflight")
            self.wrapper = Path.home() / ".local/bin/sharex"
            check_wrapper_destination(self.wrapper)
            step["wrapperExisted"] = self.wrapper.exists()

    def start_recording(self):
        targets = self.cli("targets.list")["targets"]
        displays = [target for target in targets if target["kind"] == "display"]
        if not displays:
            raise Blocked("No real display is available in this logged-in desktop.")
        target = sorted(displays, key=lambda item: item["token"])[0]
        session = self.cli("recording.start", {"target": target["token"], "fps": 15, "maxDurationSeconds": 45})
        require(session["state"] == "recording" and session["acceptedFrames"] > 0,
                "Production recording did not acknowledge an accepted frame.")
        self.inspect("settings.agents.recordingStatus")
        require(self.inspect("settings.agents.stop").get("AXEnabled") == 1, "Settings does not offer an enabled recording stop control.")
        time.sleep(1.2)
        return session, target

    def check_terminal(self, session, reason):
        require(session.get("stopReason") == reason, f"Expected recording stop reason {reason}.")
        artifact = validate_recording_files(session, Path(self.capabilities["sessionRoot"]), self.evidence.directory)
        self.validate_manifest(session)
        self.evidence.emit("ui_recording_verified", sessionID=session["id"], stopReason=reason, artifact=artifact)

    def read_terminal(self, session_id):
        manifest = Path(self.capabilities["sessionRoot"]) / str(uuid.UUID(session_id)).upper() / "manifest.json"

        def ready():
            if not manifest.is_file():
                return None
            value = json.loads(manifest.read_text(encoding="utf-8"))
            require(uuid.UUID(value["id"]) == uuid.UUID(session_id), "Revoked recording manifest has a different session ID.")
            return value if value["state"] in NATIVE.TERMINAL else None

        return self.wait_for(ready, 20, "revoked recording's terminal manifest")

    def stories(self):
        with self.evidence.step("menu_settings_agents_disabled_to_enabled") as step:
            self.start_app()
            if self.capabilities["access"]["enabled"]:
                raise Blocked("Start with agentCaptureEnabled=false on this isolated evaluation account.")
            self.open_agents_settings()
            self.access(False)
            self.cli("targets.list", error="disabled")
            permission = self.inspect("settings.agents.permissionStatus")
            require("Permission" in json.dumps(permission), "Agents page has no readable Screen Recording status.")
            if not self.capabilities["access"]["screenRecordingGranted"]:
                raise Blocked("Grant Screen Recording permission to the installed Release app before evaluation.")
            require("granted" in json.dumps(permission), "The UI permission status contradicts the production CLI.")
            self.press("settings.agents.enabled")
            step["capabilities"] = self.access(True)
            self.screenshot("agents-enabled")
        with self.evidence.step("install_update_and_execute_managed_cli") as step:
            for attempt in ("install", "update"):
                check_wrapper_destination(self.wrapper)
                previous_inode = self.wrapper.stat().st_ino if self.wrapper.exists() else None
                self.press("settings.agents.installCLI")
                expected = wrapper_content(self.binary.resolve())
                self.wait_for(lambda: self.wrapper.is_file() and self.wrapper.stat().st_ino != previous_inode
                              and self.wrapper.read_text(encoding="utf-8") == expected,
                              8, "installed CLI wrapper")
                message = self.inspect("settings.agents.setupStatus")
                require("Installed" in json.dumps(message), "CLI installation has no success feedback in Settings.")
                require(os.access(self.wrapper, os.X_OK), "Installed CLI is not executable.")
                response = self.command([self.wrapper, "capabilities"])
                capabilities = NATIVE.decode_response(json.loads(response["stdout"]))
                require(capabilities == self.cli("capabilities"), "Installed wrapper addresses a different app or capability state.")
                step[attempt] = {"path": str(self.wrapper), "sha256": NATIVE.digest(self.wrapper), "capabilities": capabilities}
        with self.evidence.step("copy_exact_claude_and_codex_commands") as step:
            for client in ("claude", "codex"):
                before = self.helper("pasteboard")
                self.press(f"settings.agents.copy.{client}")
                copied = self.helper("pasteboard")
                expected = NATIVE.registration_command(client, self.binary.resolve())
                require(copied["changeCount"] > before["changeCount"], f"Copy {client} did not write to the real pasteboard.")
                require(copied["text"] == expected, f"The copied {client} command differs from the exact installed app command.")
                require(shlex.split(copied["text"])[-3:] == [str(self.binary.resolve()), "--agent", "mcp"],
                        "Registration command quoting does not preserve the installed app path.")
                step[client] = copied["text"]
            self.screenshot("agents-client-commands")
        with self.evidence.step("production_recording_stopped_through_menu") as step:
            started, _ = self.start_recording()
            self.helper("menu", title="Stop Agent Recording")
            ended = self.terminal(started["id"], timeout=20)
            self.check_terminal(ended, "user_stop")
            step["sessionID"] = ended["id"]
        with self.evidence.step("revoke_access_during_production_recording") as step:
            started, target = self.start_recording()
            self.press("settings.agents.enabled")
            self.access(False)
            self.cli("screenshot", {"target": target["token"]}, error="disabled")
            self.cli("recording.start", {"target": target["token"]}, error="disabled")
            self.cli("recording.status", {"sessionID": started["id"]}, error="disabled")
            ended = self.read_terminal(started["id"])
            self.check_terminal(ended, "access_revoked")
            require(not self.cli("capabilities").get("activeSessionID"), "Revocation left an active recording slot.")
            step["sessionID"] = ended["id"]
            self.screenshot("agents-revoked")
        with self.evidence.step("restore_enabled_for_native_media_evaluation") as step:
            self.press("settings.agents.enabled")
            step["capabilities"] = self.access(True)
            require(self.cli("recording.status", {"sessionID": ended["id"]}) == ended,
                    "Re-enabled CLI returned a different terminal revocation manifest.")
            self.helper("snapshot")
        with self.evidence.step("delete_old_captures_from_settings") as step:
            root = Path(self.capabilities["sessionRoot"])
            displays = sorted((target for target in self.cli("targets.list")["targets"] if target["kind"] == "display"),
                              key=lambda item: item["token"])
            if not displays:
                raise Blocked("No real display is available in this logged-in desktop.")
            old = self.cli("screenshot", {"target": displays[0]["token"]})
            recent = self.cli("screenshot", {"target": displays[0]["token"]})
            for session in (old, recent):
                self.validate_manifest(session)
            old_name = str(uuid.UUID(old["id"])).upper()
            manifest = root / old_name / "manifest.json"
            NATIVE.stop_process(self.app)
            write_private_json(manifest, aged_manifest(json.loads(manifest.read_text(encoding="utf-8")), 40, time.time()))
            self.start_app()
            self.open_agents_settings()
            expected = old_final_sessions(root, time.time())
            require(old_name in expected, "The aged capture is not final and older than 30 days by its manifest.")
            before, folders = self.stored(), session_folders(root)
            self.press("settings.agents.deleteOld")
            asked = self.delete_confirmation()
            require(asked["count"] == len(expected),
                    f"Settings offers to delete {asked['count']} captures. {len(expected)} are final and older than 30 days.")
            self.press("settings.agents.deleteOld.cancel")
            time.sleep(1)
            require(session_folders(root) == folders and self.stored() == before, "Cancel changed the stored captures.")
            self.press("settings.agents.deleteOld")
            require(self.delete_confirmation()["count"] == len(expected), "The second delete confirmation changed its count.")
            self.press("settings.agents.deleteOld.confirm")
            self.wait_for(lambda: not (root / old_name).exists(), 10, "deletion of the old session folder")
            require(session_folders(root) == folders - expected,
                    "Delete removed a capture that is newer than 30 days or not final, or kept an old one.")
            self.wait_for(lambda: self.stored() == before - len(expected), 15, "the stored capture count after deletion")
            self.cli("recording.status", {"sessionID": old["id"]}, error="session_not_found")
            require(self.cli("artifacts.list", {"sessionID": recent["id"]}) == recent, "The recent capture changed after deletion.")
            self.press("settings.agents.deleteOld")
            self.wait_for(lambda: nothing_old(self.helper("snapshot")["elements"]), 15, "the text for no old captures")
            self.press("settings.agents.deleteOld.cancel")
            step.update(confirmation=asked["text"], deleted=sorted(expected),
                        storedBefore=before, storedAfter=before - len(expected))
            self.screenshot("agents-old-captures-deleted")


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
                  "sessions": run.sessions,
                  "remainingValidation": ["Human permission grant and macOS permission revocation dialogs.",
                                          "Real Claude Code and Codex registration and invocation.",
                                          "Independent media decode in the companion native media evaluation."]}
        NATIVE.write_json(output / "result.json", report)
        evidence.emit("run_finished", status=status, reason=reason, exitCode=code)
        evidence.events.close()
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
    print(json.dumps({"status": status, "reason": reason, "result": str(output / "result.json"),
                      "statistics": report["statistics"]}, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
