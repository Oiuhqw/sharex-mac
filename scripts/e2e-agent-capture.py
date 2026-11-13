#!/usr/bin/env python3
"""Validate installed Release capture through real CLI and stdio MCP processes.

Requires an unlocked macOS desktop, pregranted Screen Recording permission,
enabled agent access, and no running ShareX process. It never edits TCC.
Exit codes are 0 for passed, 1 for failed, and 3 for blocked. Evidence is retained.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import queue
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time
import traceback
import uuid


OPERATIONS = (
    "capabilities", "targets.list", "screenshot", "recording.start",
    "recording.status", "recording.stop", "session.mark", "artifacts.list",
)
TERMINAL = {"completed", "failed", "interrupted"}
COLORS = ((230, 32, 40), (32, 210, 80), (30, 80, 230), (240, 210, 40))
ROOT = Path(__file__).resolve().parent


class Failure(Exception):
    pass


class Blocked(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def installed_release_identity(app_path, build_settings_path, command):
    if "SHAREX_E2E" in os.environ:
        raise Blocked("Remove SHAREX_E2E from the environment. Production capture is required.")
    app = app_path.expanduser().resolve()
    if not any(app.is_relative_to(root) for root in (Path("/Applications"), Path.home() / "Applications")):
        raise Blocked("Install the Release app in /Applications or ~/Applications before evaluation.")
    if not (app / "Contents/Info.plist").is_file():
        raise Blocked(f"Installed app is missing: {app}.")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if not build_settings_path or not build_settings_path.is_file():
        raise Blocked("Pass --build-settings with the actual Release xcodebuild -showBuildSettings -json output.")
    entries = json.loads(build_settings_path.read_text(encoding="utf-8"))
    settings = [entry["buildSettings"] for entry in entries if entry.get("target") == "ShareX"]
    require(len(settings) == 1 and settings[0].get("CONFIGURATION") == "Release",
            "Build settings must identify exactly one ShareX Release product.")
    settings = settings[0]
    flags = str(settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")) + str(settings.get("OTHER_SWIFT_FLAGS", ""))
    require("SHAREX_E2E" not in flags, "Release build settings include production-forbidden capture fixtures.")
    built_binary = Path(settings["TARGET_BUILD_DIR"]) / settings["EXECUTABLE_PATH"]
    require(built_binary.is_file(), "The recorded Release build output is unavailable for comparison.")
    installed_hash = digest(binary)
    require(digest(built_binary) == installed_hash, "Installed binary differs from the recorded Release build.")
    strings = command(["/usr/bin/strings", "-a", binary])["stdout"]
    require(not any(marker in strings for marker in ("--e2e", "E2E PERF", "e2e-helper", "CGVirtualDisplay")),
            "Installed app contains production-forbidden capture fixtures.")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    running = command(["/usr/bin/pgrep", "-x", info["CFBundleExecutable"]], check=False)
    if running["exitCode"] == 0:
        raise Blocked("Quit the existing ShareX app before evaluation. Only this run's app PID may be terminated.")
    require(running["exitCode"] == 1, "Could not check for an existing app process.")
    return {"app": str(app), "binary": str(binary), "bundleID": info["CFBundleIdentifier"],
            "installedSHA256": installed_hash, "buildSettings": str(build_settings_path),
            "macOS": command(["/usr/bin/sw_vers"])["stdout"], "architecture": platform.machine()}


def static_window_proof(before, stop_requested, after):
    fields = ("mode", "pid", "windowID", "draws", "tick", "stage", "uptime")
    samples = [{key: state[key] for key in fields} for state in (before, stop_requested, after)]
    require(before["mode"] == "static" and before["draws"] > 0 and before["pid"] > 0 and before["windowID"] > 0,
            "Static recording requires a drawn fixture in static mode.")
    for sample in samples[1:]:
        require(all(sample[key] == before[key] for key in fields if key != "uptime"),
                "Static fixture changed mode, identity, draw count, tick, or stage during recording.")
    require(all(math.isfinite(sample["uptime"]) for sample in samples)
            and before["uptime"] + 2 <= stop_requested["uptime"] <= after["uptime"],
            "Static fixture must remain unchanged for at least two seconds before stop.")
    return dict(zip(("before", "stopRequested", "after"), samples))


def decode_response(response, request_id=None, error=None):
    require(isinstance(response, dict) and response.get("version") == 1,
            "Agent output is not a version 1 response envelope.")
    try:
        actual_id = uuid.UUID(response["id"])
    except (KeyError, ValueError, TypeError) as problem:
        raise Failure("Agent response has no UUID request ID.") from problem
    if request_id:
        require(actual_id == uuid.UUID(request_id), "Response request ID changed.")
    if error:
        require(response.get("ok") is False and response.get("error", {}).get("code") == error,
                f"Expected {error}, received {response}.")
        require(bool(response["error"].get("message")), "Failure has no actionable message.")
        return response["error"]
    require(response.get("ok") is True and isinstance(response.get("result"), dict),
            f"Agent operation failed: {response}.")
    return response["result"]


def media_expectation(fixture, target, mode, kind, stages, minimum=0, maximum=60, fps=15, static_window=None):
    window = fixture["windowBounds"]
    display = fixture["displayBounds"]
    window_rect = (window["X"] - display["x"], window["Y"] - display["y"],
                   window["Width"], window["Height"])
    if mode == "window":
        source = window_rect
    elif mode == "display":
        source = (0, 0, target["widthPoints"], target["heightPoints"])
    elif mode == "region":
        source = (window_rect[0] + 128, window_rect[1] + 96, 384, 288)
    else:
        raise Failure(f"Unknown capture mode {mode}.")
    width = round(source[2] * target["pixelScale"])
    height = round(source[3] * target["pixelScale"])
    if kind == "recording":
        factor = min(1, 3840 / width, 2160 / height)
        width = max(2, math.floor(width * factor / 2) * 2)
        height = max(2, math.floor(height * factor / 2) * 2)

    def anchor(x, y, rgb):
        return {"x": (window_rect[0] + window_rect[2] * x - source[0]) / source[2],
                "y": (window_rect[1] + window_rect[3] * y - source[1]) / source[3],
                "rgb": rgb}

    expected = {"width": width, "height": height,
            "anchors": [anchor(x, y, list(rgb)) for (x, y), rgb in
                        zip(((0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7)), COLORS)],
            "marker": anchor(0.5, 0.5, [0, 255, 255]), "stages": stages,
            "minimumDuration": minimum, "maximumDuration": maximum, "fps": fps, "motion": "animated"}
    if static_window is not None:
        proof = static_window_proof(static_window["before"], static_window["stopRequested"], static_window["after"])
        require(kind == "recording" and mode == "window" and stages == [proof["before"]["stage"]],
                "Static evidence requires one unchanged window recording stage.")
        expected.update(motion="static", staticWindow=proof)
        expected["minimumDuration"] = max(minimum, proof["stopRequested"]["uptime"] - proof["before"]["uptime"])
        bar_center = (proof["before"]["tick"] % 90) / 90 * 0.9 + 0.05
        expected["anchors"].extend([anchor(bar_center, 0.92, [255, 255, 255]),
                                    anchor(0.95 if bar_center < 0.5 else 0.05, 0.92, [0, 0, 0])])
    return expected


class Evidence:
    def __init__(self, directory):
        self.directory = directory
        self.start = time.monotonic()
        self.steps = []
        self.serial = 0
        self.events = (directory / "events.jsonl").open("w", encoding="utf-8")

    def emit(self, event, **data):
        record = {"event": event, "elapsedSeconds": round(time.monotonic() - self.start, 4), **data}
        self.events.write(json.dumps(record, sort_keys=True) + "\n")
        self.events.flush()

    def path(self, label, extension):
        self.serial += 1
        return self.directory / f"{self.serial:04d}-{label}.{extension}"

    @contextmanager
    def step(self, name):
        start = time.monotonic()
        record = {"name": name, "status": "running"}
        self.steps.append(record)
        self.emit("step_started", name=name)
        try:
            yield record
            record["status"] = "passed"
        except Blocked as problem:
            record.update(status="blocked", reason=str(problem))
            raise
        except BaseException as problem:
            record.update(status="failed", reason=str(problem))
            raise
        finally:
            record["durationSeconds"] = round(time.monotonic() - start, 4)
            self.emit("step_finished", **record)


def stop_process(process, force=False):
    if process.poll() is not None:
        return
    if force:
        process.kill()
    else:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


class MCP:
    def __init__(self, run):
        self.run = run
        self.serial = 0
        self.lines = queue.Queue()
        self.stderr = run.evidence.path("mcp", "stderr.log").open("wb")
        self.process = subprocess.Popen([str(run.binary), "--agent", "mcp"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, text=True, encoding="utf-8")
        run.children.append(self.process)
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        initialized = self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                             "clientInfo": {"name": "sharex-native-evaluation", "version": "1"}})
        require(initialized["result"]["protocolVersion"] == "2025-11-25", "MCP protocol version changed.")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        try:
            for line in self.process.stdout:
                self.lines.put(line)
        finally:
            self.lines.put(None)

    def send(self, message):
        self.run.evidence.emit("mcp_request", message=message, pid=self.process.pid)
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def rpc(self, method, params, expected_error=None):
        self.serial += 1
        self.send({"jsonrpc": "2.0", "id": self.serial, "method": method, "params": params})
        try:
            line = self.lines.get(timeout=25)
        except queue.Empty as problem:
            raise Failure(f"MCP {method} timed out.") from problem
        require(line is not None, f"MCP exited before replying to {method}.")
        try:
            response = json.loads(line)
        except json.JSONDecodeError as problem:
            raise Failure("MCP wrote non-JSON protocol output.") from problem
        self.run.evidence.emit("mcp_response", message=response, pid=self.process.pid)
        require(response.get("jsonrpc") == "2.0" and response.get("id") == self.serial,
                "MCP response does not match the request.")
        if expected_error is not None:
            require(response.get("error", {}).get("code") == expected_error,
                    f"MCP should return JSON-RPC error {expected_error}.")
        else:
            require("result" in response and "error" not in response, f"MCP failed: {response}.")
        return response

    def call(self, operation, arguments=None, request_id=None, error=None):
        request_id = request_id or str(uuid.uuid4())
        self.run.track_request(operation, arguments or {}, request_id)
        arguments = {**(arguments or {}), "requestID": request_id}
        result = self.rpc("tools/call", {"name": operation, "arguments": arguments})["result"]
        require(isinstance(result.get("structuredContent"), dict), "MCP result has no structured content.")
        content = result.get("content", [])
        require(len(content) == 1 and content[0].get("type") == "text", "MCP text result is missing.")
        require(json.loads(content[0]["text"]) == result["structuredContent"], "MCP text and structured content differ.")
        require(bool(result.get("isError", False)) == bool(error), "MCP tool error flag is incorrect.")
        return decode_response(result["structuredContent"], request_id, error)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                stop_process(self.process)
        self.thread.join(timeout=1)
        self.process.stdout.close()
        self.stderr.close()


class Run:
    def __init__(self, args, evidence):
        self.args = args
        self.evidence = evidence
        self.children = []
        self.handles = []
        self.clients = []
        self.app = None
        self.fixture = None
        self.capabilities = None
        self.sessions = []
        self.owned_session_ids = set()
        self.metrics = []
        self.metrics_stop = threading.Event()
        self.metrics_thread = None
        self.fixture_directory = evidence.directory / "fixture"
        self.fixture_directory.mkdir()

    def command(self, command, timeout=25, check=True):
        log = self.evidence.path("command", "json")
        started = time.monotonic()
        self.evidence.emit("command_started", command=[str(part) for part in command], log=str(log))
        process = subprocess.Popen([str(part) for part in command], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(process)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as problem:
            stop_process(process)
            stdout, stderr = process.communicate(timeout=3)
            write_json(log, {"command": [str(part) for part in command], "timedOut": True,
                             "stdout": stdout.decode("utf-8", "replace"), "stderr": stderr.decode("utf-8", "replace")})
            raise Failure(f"Command timed out after {timeout} seconds. See {log}.") from problem
        record = {"command": [str(part) for part in command], "exitCode": process.returncode,
                  "durationSeconds": time.monotonic() - started,
                  "stdout": stdout.decode("utf-8", "replace"), "stderr": stderr.decode("utf-8", "replace")}
        write_json(log, record)
        self.evidence.emit("command_finished", log=str(log), exitCode=process.returncode,
                           durationSeconds=record["durationSeconds"])
        if check:
            require(process.returncode == 0, f"Command exited {process.returncode}. See {log}.")
        return record

    def launch(self, command, label):
        log = self.evidence.path(label, "log").open("wb")
        self.handles.append(log)
        process = subprocess.Popen([str(part) for part in command], stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT)
        self.children.append(process)
        self.evidence.emit("process_started", pid=process.pid, command=[str(part) for part in command])
        return process

    def cli(self, operation, arguments=None, request_id=None, error=None):
        request_id = request_id or str(uuid.uuid4())
        self.track_request(operation, arguments or {}, request_id)
        command = [self.binary, "--agent", *operation.split(".")]
        names = {"sessionID": "session", "maxDurationSeconds": "duration", "maxBytes": "max-bytes"}
        for key, value in (arguments or {}).items():
            if key == "region":
                command.extend(["--region", ",".join(str(value[part]) for part in ("x", "y", "width", "height"))])
            elif key == "includeCursor":
                if value:
                    command.append("--include-cursor")
            else:
                command.extend(["--" + names.get(key, key), str(value)])
        command.extend(["--request-id", request_id])
        result = self.command(command, check=False)
        try:
            response = json.loads(result["stdout"])
        except json.JSONDecodeError as problem:
            raise Failure("CLI stdout is not one JSON response.") from problem
        require((result["exitCode"] == 0) == (error is None), "CLI exit code does not match its operation result.")
        return decode_response(response, request_id, error)

    def track_request(self, operation, arguments, request_id):
        if operation == "recording.start" or (operation == "screenshot" and "sessionID" not in arguments):
            self.owned_session_ids.add(request_id)

    def connect(self):
        client = MCP(self)
        self.clients.append(client)
        return client

    def wait_for(self, predicate, timeout, label):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)
        raise Failure(f"Timed out waiting for {label}.")

    def fixture_state(self):
        state = self.fixture_directory / "state.json"
        if not state.exists():
            return None
        return json.loads(state.read_text(encoding="utf-8"))

    def control(self, action, **values):
        command_id = str(uuid.uuid4())
        write_json(self.fixture_directory / "command.json", {"id": command_id, "action": action, **values})
        state = self.wait_for(lambda: (value if (value := self.fixture_state())
                                      and value.get("commandID") == command_id else None), 5, "fixture command")
        self.evidence.emit("fixture_command", action=action, values=values, state=state)
        return state

    def start_app(self):
        self.app = self.launch([self.binary], "app")

        def ready():
            require(self.app.poll() is None, "The installed ShareX app exited during startup.")
            result = self.command([self.binary, "--agent", "capabilities"], timeout=5, check=False)
            if result["exitCode"] != 0:
                return None
            return decode_response(json.loads(result["stdout"]))

        self.capabilities = self.wait_for(ready, 15, "agent endpoint")
        if self.fixture:
            self.control("observe", observedPID=self.app.pid)

    def _measure(self):
        while not self.metrics_stop.wait(0.5):
            process = self.app
            if process is None or process.poll() is not None:
                continue
            try:
                sample = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "rss=,%cpu=,time="],
                                        capture_output=True, text=True, timeout=2, check=False)
                parts = sample.stdout.split()
                if len(parts) == 3:
                    self.metrics.append({"elapsedSeconds": time.monotonic() - self.evidence.start,
                                         "pid": process.pid, "rssKiB": int(parts[0]),
                                         "psCPUPercent": float(parts[1]), "cpuTime": parts[2]})
            except (OSError, ValueError, subprocess.TimeoutExpired) as problem:
                self.metrics.append({"pid": process.pid, "error": str(problem)})

    def preflight(self):
        with self.evidence.step("installed_release_and_desktop_prerequisites") as step:
            if sys.platform != "darwin":
                raise Blocked("Native capture requires macOS. This run did not execute native capture.")
            identity = installed_release_identity(self.args.app, self.args.build_settings, self.command)
            self.binary = Path(identity["binary"])
            self.bundle_id = identity["bundleID"]
            step.update(identity)
        with self.evidence.step("agent_access_and_screen_recording_permission") as step:
            self.start_app()
            step["capabilities"] = self.capabilities
            if not self.capabilities["access"]["enabled"]:
                raise Blocked("Enable local agent access in ShareX Settings, then rerun this evaluation.")
            if not self.capabilities["access"]["screenRecordingGranted"]:
                raise Blocked("Grant Screen Recording permission to this installed ShareX app, then rerun. No fallback is allowed.")
            require(set(self.capabilities["operations"]) == set(OPERATIONS), "Capabilities do not expose exactly eight operations.")
        with self.evidence.step("build_and_show_independent_fixture") as step:
            for source in ("agent-capture-fixture", "verify-agent-media"):
                self.command(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
                              "-target", f"{platform.machine()}-apple-macosx14.0", ROOT / f"{source}.swift",
                              "-o", self.evidence.directory / source], timeout=120)
            title = "ShareX capture evaluation " + str(uuid.uuid4())
            self.fixture = self.launch([self.evidence.directory / "agent-capture-fixture", self.fixture_directory, title], "fixture")

            def ready():
                value = self.fixture_state()
                if value and value.get("status") == "blocked":
                    raise Blocked(value["reason"])
                require(self.fixture.poll() is None, "Independent fixture exited before it was ready.")
                return value if value and value.get("draws", 0) >= 10 and value.get("windowBounds") else None

            self.geometry = self.wait_for(ready, 10, "visible independent fixture")
            self.baseline = self.control("observe", observedPID=self.app.pid)
            step["fixture"] = self.geometry
        self.metrics_thread = threading.Thread(target=self._measure, daemon=True)
        self.metrics_thread.start()

    def discover(self, client):
        targets = self.cli("targets.list")["targets"]
        require(targets == client.call("targets.list")["targets"], "CLI and MCP discovered different targets.")
        windows = [target for target in targets if target["kind"] == "window" and target["name"] == self.geometry["title"]]
        require(len(windows) == 1, "Fixture window target is absent or ambiguous.")
        self.window_target = windows[0]
        display_bounds = self.geometry["displayBounds"]
        displays = [target for target in targets if target["kind"] == "display"
                    and target["widthPoints"] == display_bounds["width"]
                    and target["heightPoints"] == display_bounds["height"]
                    and (not self.args.display_name or target["name"] == self.args.display_name)]
        if len(displays) != 1:
            raise Blocked("Fixture display target is absent or ambiguous. Use one display or a unique --display-name.")
        self.display_target = displays[0]
        require(self.window_target["widthPoints"] == 640 and self.window_target["heightPoints"] == 480,
                "Window discovery does not report the fixture's actual logical dimensions.")
        require(self.window_target["pixelScale"] == self.geometry["scale"], "Fixture window pixel scale differs from discovery.")
        self.evidence.emit("targets_selected", window=self.window_target, display=self.display_target)

    def selection(self, mode):
        target = self.window_target if mode == "window" else self.display_target
        result = {"target": target["token"]}
        if mode == "region":
            bounds = self.geometry["windowBounds"]
            display = self.geometry["displayBounds"]
            result["region"] = {"x": bounds["X"] - display["x"] + 128,
                                "y": bounds["Y"] - display["y"] + 96, "width": 384, "height": 288}
        return result

    def unchanged(self):
        current = self.control("observe", observedPID=self.app.pid)
        for key in ("clipboardChangeCount", "frontmostPID", "observedWindows"):
            require(current[key] == self.baseline[key], f"Agent capture changed {key}: {self.baseline[key]} -> {current[key]}.")

    def validate_media(self, session, mode, kind, stages, minimum=0, maximum=60, static_window=None):
        target = self.window_target if mode == "window" else self.display_target
        artifacts = [artifact for artifact in session["artifacts"] if artifact["kind"] == kind]
        require(bool(artifacts), f"Session has no {kind} artifact.")
        artifact = artifacts[-1]
        require(artifact["state"] == "completed", "Incomplete media cannot pass native capture evaluation.")
        expected = media_expectation(self.geometry, target, mode, kind, stages, minimum, maximum,
                                     static_window=static_window)
        expected_path = self.evidence.path("media-expectation", "json")
        write_json(expected_path, expected)
        media = Path(artifact["path"])
        session_directory = Path(self.capabilities["sessionRoot"]) / session["id"]
        require(media.is_absolute() and media.resolve().is_relative_to(session_directory.resolve())
                and not media.is_symlink() and media.is_file(), "Artifact is not a regular file in its private session directory.")
        evidence_copy = self.evidence.directory / f"{session['id']}-{artifact['id']}{media.suffix}"
        require(not evidence_copy.exists(), "Evidence artifact would overwrite an earlier capture.")
        shutil.copyfile(media, evidence_copy)
        require(media.stat().st_size == artifact["byteCount"] and digest(media) == artifact["sha256"],
                "Artifact bytes differ from the session manifest size or SHA-256.")
        decoded = self.command([self.evidence.directory / "verify-agent-media", media, expected_path], timeout=90, check=False)
        verification = json.loads(decoded["stdout"])
        self.evidence.emit("media_decoded", sessionID=session["id"], artifact=artifact, verification=verification)
        require(decoded["exitCode"] == 0 and verification.get("status") == "passed",
                f"Independent media decode failed: {verification}.")
        require(verification["width"] == artifact["widthPixels"] and verification["height"] == artifact["heightPixels"],
                "Manifest dimensions differ from independently decoded dimensions.")
        require(verification["sha256"] == artifact["sha256"] and verification["bytes"] == artifact["byteCount"],
                "Independent verifier file hash or size differs from the manifest.")
        if kind == "recording":
            require(abs(verification["durationSeconds"] - artifact["durationSeconds"]) < 0.2,
                    "Manifest duration differs from the decoded video.")
            require(session["acceptedFrames"] >= verification["frameCount"] and session["droppedFrames"] >= 0,
                    "Recording frame metrics contradict the independently decoded video.")
        return verification

    def validate_manifest(self, session):
        directory = Path(self.capabilities["sessionRoot"]) / session["id"]
        manifest = directory / "manifest.json"
        require(manifest.is_file(), "Session has no committed manifest.")
        persisted = json.loads(manifest.read_text(encoding="utf-8"))
        write_json(self.evidence.directory / f"{session['id']}-manifest.json", persisted)
        require(persisted == session, "Committed manifest differs from the returned terminal session.")
        require(session["state"] in TERMINAL, "Manifest is not terminal.")
        require(all(artifact["state"] != "pending" for artifact in session["artifacts"]),
                "Terminal manifest contains pending evidence.")
        require(isinstance(session.get("endedAt"), (float, int)) and session["endedAt"] >= session["createdAt"],
                "Terminal manifest has invalid completion timestamps.")
        if session["state"] == "completed":
            require(all(artifact["state"] == "completed" for artifact in session["artifacts"]),
                    "Completed session contains incomplete evidence.")
        self.sessions.append({"id": session["id"], "state": session["state"], "stopReason": session.get("stopReason"),
                              "acceptedFrames": session["acceptedFrames"], "droppedFrames": session["droppedFrames"],
                              "artifacts": len(session["artifacts"]), "markers": len(session["markers"])})
        require(directory.stat().st_mode & 0o077 == 0, "Session directory is accessible by other users.")

    def terminal(self, session_id, timeout=15):
        def state():
            value = self.cli("recording.status", {"sessionID": session_id})
            return value if value["state"] in TERMINAL else None
        return self.wait_for(state, timeout, "terminal recording manifest")

    def transitions(self, initial_seconds=0.9):
        time.sleep(initial_seconds)
        self.control("stage", stage=1)
        time.sleep(initial_seconds + 0.3)
        self.control("stage", stage=2)
        time.sleep(initial_seconds)

    def stories(self):
        with self.evidence.step("mcp_initialize_catalog_and_cli_discovery") as step:
            client = self.connect()
            catalog = client.rpc("tools/list", {})["result"]["tools"]
            require(len(catalog) == 8 and {tool["name"] for tool in catalog}
                    == set(OPERATIONS), "MCP tool catalog differs from the shared eight operations.")
            require(client.call("capabilities") == self.capabilities, "CLI and MCP capabilities differ.")
            self.discover(client)
            step["toolNames"] = [tool["name"] for tool in catalog]
        with self.evidence.step("malformed_payload_invalid_target_and_limits"):
            client.rpc("tools/call", {"name": "screenshot", "arguments": []}, expected_error=-32602)
            client.call("recording.start", {**self.selection("window"), "fps": 0}, error="invalid_request")
            client.call("recording.start", {**self.selection("window"), "maxBytes": 1024}, error="invalid_request")
            self.cli("recording.start", {**self.selection("window"), "maxDurationSeconds": 7201}, error="invalid_request")
            self.cli("screenshot", {"target": "invalid-target-" + str(uuid.uuid4())}, error="target_not_found")
            client.call("screenshot", {**self.selection("display"), "region": {"x": -1, "y": 0, "width": 10, "height": 10}},
                        error="invalid_request")
            self.cli("recording.status", {"sessionID": str(uuid.uuid4())}, error="session_not_found")
        for mode, caller in (("window", self.cli), ("display", client.call), ("region", self.cli)):
            with self.evidence.step(f"real_{mode}_png_and_no_interactive_side_effects"):
                session = caller("screenshot", self.selection(mode))
                require(session["state"] == "completed", "Screenshot did not complete.")
                self.validate_media(session, mode, "screenshot", [0])
                self.validate_manifest(session)
                self.unchanged()
        with self.evidence.step("window_recording_checkpoint_retry_reconnect_and_markers") as step:
            request_id = str(uuid.uuid4())
            options = {**self.selection("window"), "fps": 15, "maxDurationSeconds": 60}
            started = client.call("recording.start", options, request_id)
            stage_zero_start = time.monotonic()
            require(started["state"] == "recording" and started["acceptedFrames"] >= 1,
                    "Recording start did not acknowledge an accepted frame.")
            session_id = started["id"]
            retry = self.cli("recording.start", options, request_id)
            require(retry["id"] == session_id, "Duplicate start created another session.")
            self.cli("recording.start", {**options, "fps": 30}, request_id, error="request_conflict")
            client.call("recording.start", self.selection("display"), error="busy")
            checkpoint = self.cli("screenshot", {**self.selection("window"), "sessionID": session_id})
            self.validate_media(checkpoint, "window", "screenshot", [0])
            client.close()
            client = self.connect()
            reconnected = client.call("recording.status", {"sessionID": session_id})
            require(reconnected["state"] == "recording", "Recording stopped when its MCP client exited.")
            label = "Reported application check failed while capture remained healthy"
            marked = client.call("session.mark", {"sessionID": session_id, "label": label, "outcome": "failed"})
            require(marked["markers"][-1]["outcome"] == "failed", "Session marker lost its reported test outcome.")
            time.sleep(max(0, 1 - (time.monotonic() - stage_zero_start)))
            first_stage_duration = time.monotonic() - stage_zero_start
            require(first_stage_duration < 15, "Control operations consumed too much of the recording duration limit.")
            self.control("stage", stage=1)
            time.sleep(first_stage_duration + 0.3)
            self.control("stage", stage=2)
            time.sleep(first_stage_duration)
            completed = self.cli("recording.stop", {"sessionID": session_id})
            duplicate = client.call("recording.stop", {"sessionID": session_id})
            require(duplicate == completed and completed["state"] == "completed", "Duplicate stop did not preserve the completed result.")
            require(len(completed["artifacts"]) == 2 and len(completed["markers"]) == 1,
                    "Session omitted or duplicated its checkpoint or marker.")
            require(completed["markers"][0]["outcome"] == "failed", "Capture completion overwrote the reported test outcome.")
            step["media"] = self.validate_media(completed, "window", "recording", [0, 1, 2], minimum=2.5)
            require(client.call("artifacts.list", {"sessionID": session_id}) == completed, "Artifacts listing differs from finalization.")
            self.validate_manifest(completed)
            self.unchanged()
        for mode, start_call, stop_call in (("display", self.cli, client.call), ("region", client.call, self.cli)):
            with self.evidence.step(f"real_{mode}_mp4_cross_client_finalization") as step:
                self.control("stage", stage=0)
                started = start_call("recording.start", {**self.selection(mode), "fps": 15, "maxDurationSeconds": 30})
                self.transitions()
                completed = stop_call("recording.stop", {"sessionID": started["id"]})
                require(completed["state"] == "completed", "Cross-client recording finalization failed.")
                step["media"] = self.validate_media(completed, mode, "recording", [0, 1, 2], minimum=2.5, maximum=8)
                self.validate_manifest(completed)
                self.unchanged()
        with self.evidence.step("static_window_recording_covers_explicit_stop") as step:
            self.control("stage", stage=0)
            self.control("mode", mode="static")
            started = client.call("recording.start", {**self.selection("window"), "fps": 15, "maxDurationSeconds": 20})
            require(started["state"] == "recording" and started["acceptedFrames"] >= 1,
                    "Static recording start did not acknowledge an accepted frame.")
            before = self.control("observe")
            time.sleep(2.5)
            stop_requested = self.control("observe")
            completed = self.cli("recording.stop", {"sessionID": started["id"]})
            after = self.control("observe")
            step["staticWindow"] = static_window_proof(before, stop_requested, after)
            require(completed["state"] == "completed" and completed["stopReason"] == "user_stop",
                    "Static recording did not complete after the explicit stop request.")
            step["media"] = self.validate_media(completed, "window", "recording", [0], maximum=10,
                                               static_window=step["staticWindow"])
            self.validate_manifest(completed)
            self.unchanged()
            self.control("mode", mode="animated")
        with self.evidence.step("duration_limit_finalizes_readable_video") as step:
            self.control("stage", stage=0)
            started = self.cli("recording.start", {**self.selection("region"), "fps": 15, "maxDurationSeconds": 3})
            completed = self.terminal(started["id"])
            require(completed["state"] == "completed" and completed["stopReason"] == "duration_limit",
                    "Duration limit did not produce an explicit completed terminal result.")
            step["media"] = self.validate_media(completed, "region", "recording", [0], minimum=2.6, maximum=3.7)
            self.validate_manifest(completed)
        with self.evidence.step("byte_limit_finalizes_readable_video") as step:
            self.control("noise", enabled=True)
            started = client.call("recording.start", {**self.selection("window"), "fps": 15,
                                  "maxDurationSeconds": 30, "maxBytes": 1048576})
            completed = self.terminal(started["id"], timeout=40)
            require(completed["state"] == "completed" and completed["stopReason"] == "byte_limit",
                    "Byte limit did not stop the real noisy video before its duration limit.")
            step["media"] = self.validate_media(completed, "window", "recording", [0], minimum=0.5, maximum=30)
            self.validate_manifest(completed)
            self.control("noise", enabled=False)
        with self.evidence.step("app_quit_finalizes_owned_recording") as step:
            started = self.cli("recording.start", {**self.selection("window"), "fps": 15, "maxDurationSeconds": 30})
            time.sleep(1.5)
            client.close()
            self.control("terminate-observed", observedPID=self.app.pid)
            try:
                self.app.wait(timeout=20)
            except subprocess.TimeoutExpired as problem:
                raise Failure("App quit did not finish within 20 seconds.") from problem
            self.start_app()
            completed = self.cli("artifacts.list", {"sessionID": started["id"]})
            require(completed["state"] == "completed" and completed["stopReason"] == "app_quit",
                    "App quit did not finalize its recording.")
            step["media"] = self.validate_media(completed, "window", "recording", [0], minimum=1, maximum=8)
            self.validate_manifest(completed)
            client = self.connect()
            self.discover(client)
        with self.evidence.step("abrupt_app_exit_recovers_incomplete_session"):
            started = client.call("recording.start", {**self.selection("window"), "fps": 15, "maxDurationSeconds": 30})
            time.sleep(1)
            old_token = self.window_target["token"]
            client.close()
            stop_process(self.app, force=True)
            self.start_app()
            recovered = self.cli("artifacts.list", {"sessionID": started["id"]})
            require(recovered["state"] == "interrupted" and recovered["stopReason"] == "app_restart",
                    "Unfinished recording was not recovered as interrupted.")
            require(all(artifact["state"] != "completed" for artifact in recovered["artifacts"]
                        if artifact["kind"] == "recording"), "Interrupted recording became complete evidence.")
            self.validate_manifest(recovered)
            self.cli("screenshot", {"target": old_token}, error="target_not_found")
            client = self.connect()
            self.discover(client)
            restart = self.cli("recording.start", {**self.selection("window"), "fps": 15, "maxDurationSeconds": 10})
            time.sleep(1.2)
            completed = client.call("recording.stop", {"sessionID": restart["id"]})
            self.validate_media(completed, "window", "recording", [0], minimum=1, maximum=5)
            self.validate_manifest(completed)
        with self.evidence.step("lost_window_never_substitutes_another_target"):
            started = client.call("recording.start", {**self.selection("window"), "fps": 15, "maxDurationSeconds": 20})
            time.sleep(0.5)
            self.control("close-window")
            ended = self.terminal(started["id"], timeout=10)
            require(ended["state"] in {"failed", "interrupted"}
                    and ended.get("failure", {}).get("code") in {"target_not_found", "target_changed", "recording_failed"}
                    and ended.get("stopReason") in {"target_lost", "target_changed", "stream_error"},
                    "Lost window was not reported as incomplete capture.")
            require(ended["selection"]["target"] == started["selection"]["target"], "Lost window changed the session target.")
            require(all(artifact["state"] != "completed" for artifact in ended["artifacts"]
                        if artifact["kind"] == "recording"), "Lost window recording was published as complete.")
            self.cli("screenshot", self.selection("window"), error="target_not_found")
            self.validate_manifest(ended)

    def cleanup(self, failed):
        errors = []
        self.metrics_stop.set()
        if self.metrics_thread:
            self.metrics_thread.join(timeout=3)
        for client in self.clients:
            try:
                if not client.stderr.closed:
                    client.close()
            except (OSError, ValueError, subprocess.TimeoutExpired) as problem:
                errors.append(str(problem))
        for process in reversed(self.children):
            try:
                stop_process(process)
            except (OSError, subprocess.TimeoutExpired) as problem:
                errors.append(str(problem))
        for handle in self.handles:
            handle.close()
        if self.capabilities:
            root = Path(self.capabilities["sessionRoot"])
            for session_id in self.owned_session_ids:
                directory = root / str(uuid.UUID(session_id)).upper()
                if not directory.is_dir() or directory.is_symlink():
                    continue
                try:
                    for source in directory.rglob("*"):
                        if not source.is_file() or source.is_symlink() or not source.resolve().is_relative_to(directory.resolve()):
                            continue
                        if not failed and source.name != "manifest.json" and ".partial." not in source.name:
                            continue
                        destination = self.evidence.directory / "session-snapshots" / directory.name / source.relative_to(directory)
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(source, destination)
                except OSError as problem:
                    errors.append(f"Could not retain session evidence {session_id}: {problem}")
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/ShareX.app"))
    parser.add_argument("--build-settings", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--display-name")
    args = parser.parse_args()
    output = args.out.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        print(json.dumps({"status": "blocked", "reason": "Evidence directory is not empty. Use a fresh --out directory."}))
        return 3
    evidence = Evidence(output)
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
            status, code = "failed", 1
            reason = "Process cleanup failed: " + "; ".join(cleanup_errors)
        samples = [sample for sample in run.metrics if "rssKiB" in sample]
        report = {"schemaVersion": 1, "status": status, "reason": reason,
                  "durationSeconds": time.monotonic() - started, "steps": evidence.steps,
                  "statistics": {"passedSteps": sum(step["status"] == "passed" for step in evidence.steps),
                                 "failedSteps": sum(step["status"] == "failed" for step in evidence.steps),
                                 "blockedSteps": sum(step["status"] == "blocked" for step in evidence.steps),
                                 "sessions": len(run.sessions), "artifacts": sum(session["artifacts"] for session in run.sessions),
                                 "metricSamples": len(samples),
                                 "peakRSSKiB": max((sample["rssKiB"] for sample in samples), default=None),
                                 "medianPSCPUPercent": statistics.median(sample["psCPUPercent"] for sample in samples) if samples else None},
                  "metricContext": {"process": "Only app PIDs started by this evaluation.",
                                    "cpu": "ps %cpu is a process CPU average, not an instantaneous sample.",
                                    "workload": "15 FPS, 640x480 point fixture, display/window/384x288 region, one static window and one noisy byte-limit test.",
                                    "comparison": "No baseline, speedup, or performance improvement is claimed."},
                  "sessions": run.sessions,
                  "remainingValidation": ["Real Claude Code and Codex client registration and invocation.",
                                          "Settings permission UX, CLI installation, and copyable registration commands.",
                                          "Permission revocation and actual disk reserve exhaustion on an isolated native host."]}
        write_json(output / "metrics.json", run.metrics)
        write_json(output / "result.json", report)
        evidence.emit("run_finished", status=status, reason=reason, exitCode=code)
        evidence.events.close()
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
    print(json.dumps({"status": status, "reason": reason, "result": str(output / "result.json"),
                      "statistics": report["statistics"]}, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
