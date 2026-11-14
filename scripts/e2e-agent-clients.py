#!/usr/bin/env python3
"""Exercise installed Release capture through actual Codex and Claude Code tools.

Codex routes ShareX MCP calls through an ephemeral app-server thread. Claude Code
exposes its real Bash tool through `--bare mcp serve` and executes the ShareX CLI.
No prompt, model turn, API credential, or inference is used. This does not test
LLM tool selection. Requires the same native desktop prerequisites as the media
evaluation. Exit codes: 0 passed, 1 failed, 3 blocked.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
import uuid


SPEC = importlib.util.spec_from_file_location("agent_capture_e2e", Path(__file__).with_name("e2e-agent-capture.py"))
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)
Failure, Blocked, require = NATIVE.Failure, NATIVE.Blocked, NATIVE.require
VERSIONS = {"codex": "codex-cli 0.169.0", "claude": "2.1.323 (Claude Code)"}
SOURCES = ["https://learn.chatgpt.com/docs/app-server",
           "https://code.claude.com/docs/en/mcp#use-claude-code-as-an-mcp-server",
           "https://registry.npmjs.org/@openai/codex/0.169.0",
           "https://registry.npmjs.org/@anthropic-ai/claude-code/2.1.323"]


def isolated_environment(directory):
    directory.mkdir()
    allowed = {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "SYSTEMDRIVE",
               "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMDATA", "NUMBER_OF_PROCESSORS",
               "PROCESSOR_ARCHITECTURE", "LANG", "LC_ALL"}
    environment = {key: value for key, value in os.environ.items() if key.upper() in allowed}
    environment.update(HOME=str(directory), USERPROFILE=str(directory),
                       APPDATA=str(directory), LOCALAPPDATA=str(directory),
                       TEMP=str(directory), TMP=str(directory), TMPDIR=str(directory),
                       XDG_CONFIG_HOME=str(directory / "config"), XDG_CACHE_HOME=str(directory / "cache"),
                       HTTP_PROXY="http://127.0.0.1:9", HTTPS_PROXY="http://127.0.0.1:9",
                       ALL_PROXY="http://127.0.0.1:9", NO_PROXY="127.0.0.1,localhost",
                       CLAUDE_CONFIG_DIR=str(directory / "claude"),
                       CLAUDE_CODE_SIMPLE="1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
                       CLAUDE_CODE_DISABLE_FEATURE_FLAGS="1", DISABLE_AUTOUPDATER="1",
                       CODEX_HOME=str(directory / "codex"))
    for name in ("claude", "codex", "config", "cache"):
        (directory / name).mkdir()
    if os.name == "nt":
        git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        if git_bash.is_file():
            environment["CLAUDE_CODE_GIT_BASH_PATH"] = str(git_bash)
    return environment


def close_client(process):
    if process.poll() is None:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               capture_output=True, timeout=5, check=False)
            else:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
    if os.name != "nt":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    require(process.poll() is not None, "Client process survived cleanup.")


class ClientRPC:
    def __init__(self, run, label, command, environment, cwd):
        self.run, self.label = run, label
        self.serial, self.calls = 0, 0
        self.lines = queue.Queue()
        self.stderr = run.evidence.path(label, "stderr.log").open("wb")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, text=True, encoding="utf-8", env=environment,
                                        cwd=cwd, start_new_session=os.name != "nt")
        run.children.append(self.process)
        run.evidence.emit("client_started", client=label, pid=self.process.pid, command=command)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while line := self.process.stdout.readline(8 * 1024 * 1024 + 1):
                if len(line) > 8 * 1024 * 1024:
                    self.lines.put(Failure("Client protocol line exceeds eight MiB."))
                    return
                try:
                    self.lines.put(json.loads(line))
                except ValueError:
                    self.lines.put(Failure("Client wrote non-JSON protocol output."))
                    return
        finally:
            self.lines.put(None)

    def send(self, message):
        self.run.evidence.emit("client_request", client=self.label, id=message.get("id"),
                               method=message.get("method"),
                               tool=message.get("params", {}).get("tool", message.get("params", {}).get("name")))
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def rpc(self, method, parameters, timeout=25):
        self.serial += 1
        self.send({"jsonrpc": "2.0", "id": self.serial, "method": method, "params": parameters})
        deadline = time.monotonic() + timeout
        while True:
            try:
                message = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty as problem:
                raise Failure(f"{self.label} {method} exceeded {timeout} seconds.") from problem
            if isinstance(message, Exception):
                raise message
            require(message is not None, f"{self.label} exited before replying to {method}.")
            require(isinstance(message, dict), "Client protocol message is not an object.")
            self.run.evidence.emit("client_response", client=self.label, id=message.get("id"),
                                   method=message.get("method"), hasError="error" in message)
            require(not ("method" in message and "id" in message),
                    "Client requested an unexpected approval or external operation.")
            if message.get("id") == self.serial:
                require("error" not in message and "result" in message,
                        f"{self.label} rejected {method}: {message.get('error')}.")
                return message["result"]
            require(time.monotonic() < deadline, f"{self.label} {method} timed out amid notifications.")

    def close(self):
        if self.stderr.closed:
            return
        close_client(self.process)
        self.reader.join(timeout=2)
        self.process.stdout.close()
        self.stderr.close()
        self.run.evidence.emit("client_stopped", client=self.label, pid=self.process.pid,
                               exitCode=self.process.returncode, toolCalls=self.calls)


class Codex(ClientRPC):
    def __init__(self, run, command, environment, cwd):
        super().__init__(run, "codex", command, environment, cwd)
        run.clients.append(self)
        initialized = self.rpc("initialize", {"clientInfo": {"name": "sharex-native-evaluation", "version": "1"},
                                               "capabilities": {"experimentalApi": True}})
        require(Path(initialized["codexHome"]).resolve() == Path(environment["CODEX_HOME"]).resolve(),
                "Codex did not use this run's isolated configuration.")
        self.send({"method": "initialized", "params": {}})
        started = self.rpc("thread/start", {"cwd": str(cwd), "ephemeral": True,
                                             "approvalPolicy": "never", "sandbox": "read-only"})
        thread = started["thread"]
        require(thread["ephemeral"] is True and thread.get("path") is None and thread["turns"] == [],
                "Codex must use an ephemeral thread with no model turns.")
        self.thread_id = thread["id"]
        catalog = self.rpc("mcpServerStatus/list", {"threadId": self.thread_id, "serverName": "sharex_evaluation",
                                                    "detail": "toolsAndAuthOnly", "limit": 1})["data"]
        require(len(catalog) == 1 and set(catalog[0]["tools"]) == {NATIVE.tool_name(op) for op in NATIVE.OPERATIONS}
                and catalog[0].get("toolsError") is None, "Codex did not discover all eight ShareX tools.")
        run.evidence.emit("client_catalog", client="codex", tools=sorted(catalog[0]["tools"]), ephemeral=True)

    def call(self, operation, arguments=None, request_id=None):
        request_id = request_id or str(uuid.uuid4())
        self.run.track_request(operation, arguments or {}, request_id)
        result = self.rpc("mcpServer/tool/call", {"threadId": self.thread_id, "server": "sharex_evaluation",
                                                 "tool": NATIVE.tool_name(operation),
                                                 "arguments": {**(arguments or {}), "requestID": request_id}})
        self.calls += 1
        require(not result.get("isError"), f"Codex ShareX {operation} returned a tool error.")
        NATIVE.tool_result_content(result, operation)
        return NATIVE.decode_response(result["structuredContent"], request_id)


class Claude(ClientRPC):
    def __init__(self, run, command, environment, cwd):
        super().__init__(run, "claude", command, environment, cwd)
        run.clients.append(self)
        initialized = self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                               "clientInfo": {"name": "sharex-native-evaluation", "version": "1"}})
        require(initialized["serverInfo"]["version"] == "2.1.323", "Claude MCP server version differs from the pinned CLI.")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        names = [tool["name"] for tool in self.rpc("tools/list", {})["tools"]]
        require("Bash" in names, "Claude Code does not expose its Bash tool.")
        run.evidence.emit("client_catalog", client="claude", tools=names)
        self.binary = run.binary

    def track_request(self, operation, arguments, request_id):
        self.run.track_request(operation, arguments, request_id)

    def command(self, command, check=False):
        result = self.rpc("tools/call", {"name": "Bash", "arguments": {
            "command": shlex.join([str(part) for part in command]), "timeout": 20000,
            "description": "Run a ShareX capture operation"}})
        self.calls += 1
        require(not result.get("isError"),
                "Claude Bash reported a failed ShareX CLI command: " + str(result.get("content", []))[:4000])
        content = result.get("content", [])
        require(len(content) == 1 and content[0].get("type") == "text", "Claude Bash returned no structured command result.")
        output = json.loads(content[0]["text"])
        require(output.get("interrupted") is False and not output.get("backgroundOutputPath")
                and isinstance(output.get("stdout"), str), "Claude Bash did not finish the command in the foreground.")
        # Bash reports nonzero commands through isError; it does not return a
        # numeric exit code. Run.cli also checks ShareX's success envelope and ID.
        return {"exitCode": 0, "stdout": output["stdout"], "stderr": output.get("stderr", "")}

    def call(self, operation, arguments=None, request_id=None):
        return NATIVE.Run.cli(self, operation, arguments, request_id)


class Run(NATIVE.Run):
    def preflight(self):
        with self.evidence.step("pinned_clients_and_isolated_configuration") as step:
            if sys.platform != "darwin":
                raise Blocked("Native client capture requires macOS. No native capture was executed.")
            self.client_home = self.evidence.directory / "client-home"
            self.environment = isolated_environment(self.client_home)
            self.client_paths = {}
            for name in VERSIONS:
                path = shutil.which(str(getattr(self.args, name)))
                if not path:
                    raise Blocked(f"Install the pinned {name} CLI and pass its path with --{name}.")
                result = subprocess.run([path, "--version"], cwd=self.client_home, env=self.environment,
                                        text=True, capture_output=True, timeout=10, check=False)
                require(result.returncode == 0 and result.stdout.strip() == VERSIONS[name],
                        f"Expected {VERSIONS[name]}; received {result.stdout.strip()}.")
                self.client_paths[name] = path
            step["versions"] = VERSIONS
            step["sources"] = SOURCES
        super().preflight()
        config = '\n'.join(['cli_auth_credentials_store = "file"', '[analytics]', 'enabled = false',
                            '[feedback]', 'enabled = false', '[history]', 'persistence = "none"',
                            '[mcp_servers.sharex_evaluation]', f'command = {json.dumps(str(self.binary))}',
                            'args = ["--agent", "mcp"]', 'startup_timeout_sec = 15', 'tool_timeout_sec = 20']) + '\n'
        (Path(self.environment["CODEX_HOME"]) / "config.toml").write_text(config, encoding="utf-8")

    def stories(self):
        for name, client_type, suffix in (("codex", Codex, ["app-server", "--listen", "stdio://"]),
                                          ("claude", Claude, ["--bare", "mcp", "serve"])):
            with self.evidence.step(f"{name}_capabilities_and_discovery") as step:
                client = client_type(self, [self.client_paths[name], *suffix], self.environment, self.client_home)
                require(client.call("capabilities") == self.cli("capabilities"),
                        f"{name} capabilities differ from the installed app.")
                self.discover(client)
                step["route"] = "app-server to ShareX MCP" if name == "codex" else "Claude Bash tool to ShareX CLI"
            with self.evidence.step(f"{name}_real_png") as step:
                self.control("stage", stage=0)
                session = client.call("screenshot", self.selection("window"))
                require(session["state"] == "completed", f"{name} screenshot did not complete.")
                step["media"] = self.validate_media(session, "window", "screenshot", [0])
                self.validate_manifest(session)
                self.unchanged()
            with self.evidence.step(f"{name}_real_recording_status_mark_stop_artifacts") as step:
                started = client.call("recording.start", {**self.selection("window"), "fps": 15, "maxDurationSeconds": 30})
                require(started["state"] == "recording" and started["acceptedFrames"] >= 1,
                        f"{name} recording did not acknowledge a complete frame.")
                session_id = started["id"]
                stage_start = time.monotonic()
                status = client.call("recording.status", {"sessionID": session_id})
                require(status["state"] == "recording" and status["acceptedFrames"] >= 1, "Recording status is not active.")
                label = f"{name} real client invocation"
                marked = client.call("session.mark", {"sessionID": session_id, "label": label, "outcome": "passed"})
                require(marked["markers"][-1]["label"] == label, "Client marker was not committed.")
                time.sleep(max(0, 0.9 - (time.monotonic() - stage_start)))
                stage_seconds = time.monotonic() - stage_start
                require(stage_seconds < 5, "Client status and marker calls consumed the recording timing budget.")
                self.control("stage", stage=1)
                time.sleep(stage_seconds + 0.3)
                self.control("stage", stage=2)
                time.sleep(stage_seconds)
                completed = client.call("recording.stop", {"sessionID": session_id})
                require(completed["state"] == "completed" and completed["stopReason"] == "user_stop",
                        "Client stop did not finalize the recording.")
                require(client.call("artifacts.list", {"sessionID": session_id}) == completed,
                        "Client artifacts differ from the committed recording.")
                step["media"] = self.validate_media(completed, "window", "recording", [0, 1, 2], minimum=2.5, maximum=20)
                self.validate_manifest(completed)
                self.unchanged()
                step["toolCalls"] = client.calls
                client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/ShareX.app"))
    parser.add_argument("--build-settings", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--display-name")
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--claude", default="claude")
    args = parser.parse_args()
    output = args.out.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        print(json.dumps({"status": "blocked", "reason": "Use a fresh, empty --out directory."}))
        return 3
    evidence = NATIVE.Evidence(output)
    run = Run(args, evidence)
    status, code, reason = "failed", 1, None
    original_handlers = {}

    def interrupted(signum, frame):
        raise Failure(f"Client evaluation interrupted by signal {signum}.")

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
        errors = run.cleanup(failed=status != "passed")
        if errors:
            status, code, reason = "failed", 1, "Cleanup failed: " + "; ".join(errors)
        report = {"schemaVersion": 1, "status": status, "reason": reason,
                  "scope": "Actual Codex MCP routing and Claude Code Bash CLI execution; no LLM selection or inference.",
                  "durationSeconds": time.monotonic() - evidence.start, "steps": evidence.steps,
                  "statistics": {"passedSteps": sum(step["status"] == "passed" for step in evidence.steps),
                                 "failedSteps": sum(step["status"] == "failed" for step in evidence.steps),
                                 "blockedSteps": sum(step["status"] == "blocked" for step in evidence.steps),
                                 "sessions": len(run.sessions), "artifacts": sum(item["artifacts"] for item in run.sessions),
                                 "clientToolCalls": sum(client.calls for client in run.clients), "modelTurns": 0},
                  "sessions": run.sessions, "sources": SOURCES,
                  "remainingValidation": ["LLM selection of tools from a natural-language prompt is outside this credential-free check."]}
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
