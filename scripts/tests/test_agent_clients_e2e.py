import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock
import urllib.error
import urllib.request
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "e2e-agent-clients.py"
SPEC = importlib.util.spec_from_file_location("agent_clients_e2e", SCRIPT)
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class IsolatedClientsTests(unittest.TestCase):
    def test_child_environment_drops_credentials_hooks_and_user_settings(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {
                "OPENAI_API_KEY": "secret", "ANTHROPIC_API_KEY": "secret", "GITHUB_TOKEN": "secret",
                "CLAUDE_CODE_OAUTH_TOKEN": "secret", "BASH_ENV": "/private/startup", "NODE_OPTIONS": "--require hook",
                "HOME": "/private/home", "CODEX_HOME": "/private/codex", "CLAUDE_CONFIG_DIR": "/private/claude"}):
            root = Path(directory) / "isolated"
            environment = DRIVER.isolated_environment(root)
            self.assertFalse(any(key in environment for key in
                                 ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "BASH_ENV", "NODE_OPTIONS")))
            self.assertEqual(environment["HOME"], str(root))
            self.assertEqual(environment["CODEX_HOME"], str(root / "codex"))
            self.assertEqual(environment["CLAUDE_CONFIG_DIR"], str(root / "claude"))
            self.assertEqual(environment["HTTPS_PROXY"], "http://127.0.0.1:9")

    @unittest.skipIf(sys.platform == "darwin", "This assertion specifically checks the non-native gate.")
    def test_non_native_host_is_blocked_without_clients_or_media(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, SCRIPT, "--out", directory], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 3)
            report = json.loads((Path(directory) / "result.json").read_text())
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["statistics"]["artifacts"], 0)
            self.assertEqual(report["statistics"]["clientToolCalls"], 0)


class ClaudeResultTests(unittest.TestCase):
    def setUp(self):
        self.client = DRIVER.Claude.__new__(DRIVER.Claude)
        self.client.calls = 0
        self.client.binary = "/Applications/Share X's $(never).app/Contents/MacOS/ShareX"
        self.client.run = types.SimpleNamespace(track_request=lambda *args: None)
        self.request_id = str(uuid.uuid4())
        self.commands = []
        self.envelope = {"version": 1, "id": self.request_id, "ok": True, "result": {"state": "completed"}}
        self.output = {"stdout": json.dumps(self.envelope), "stderr": "", "interrupted": False}
        self.error = False

        def rpc(method, parameters):
            self.commands.append(parameters)
            return {"isError": self.error, "content": [{"type": "text", "text": json.dumps(self.output)}]}

        self.client.rpc = rpc

    def test_real_cli_arguments_remain_literal_in_bash(self):
        label = "Quotes ' and $(not_a_command) `literal`\nsecond line"
        result = self.client.call("session.mark", {"sessionID": self.request_id, "label": label}, self.request_id)
        self.assertEqual(result, {"state": "completed"})
        command = shlex.split(self.commands[0]["arguments"]["command"])
        self.assertEqual(command[0], self.client.binary)
        self.assertEqual(command[command.index("--label") + 1], label)
        self.assertEqual(command[-2:], ["--request-id", self.request_id])

    def test_bash_failure_cannot_be_reported_as_capture_success(self):
        self.error = True
        with self.assertRaisesRegex(DRIVER.Failure, "failed ShareX CLI command"):
            self.client.call("capabilities", request_id=self.request_id)

    def test_background_or_interrupted_command_is_not_a_completed_capture(self):
        for change in ({"interrupted": True}, {"backgroundOutputPath": "/tmp/background.log"}):
            with self.subTest(change=change):
                old = dict(self.output)
                self.output.update(change)
                with self.assertRaisesRegex(DRIVER.Failure, "foreground"):
                    self.client.call("capabilities", request_id=self.request_id)
                self.output = old

    def test_sharex_response_must_match_the_request(self):
        self.output["stdout"] = json.dumps({**self.envelope, "id": str(uuid.uuid4())})
        with self.assertRaisesRegex(DRIVER.Failure, "request ID changed"):
            self.client.call("capabilities", request_id=self.request_id)


TARGETS = {"version": 1, "id": str(uuid.uuid4()).upper(), "ok": True, "result": {"targets": [
    {"kind": "display", "name": "Apple Virtual", "token": "display-token"},
    {"kind": "window", "name": "ShareX capture evaluation 1", "token": "window-token"}]}}
CLAUDE_TOOLS = [{"name": "Bash"}, *({"name": name} for name in sorted(DRIVER.EXPECTED_TOOLS["claude"]))]


def tool_result(text, *extra):
    return {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1",
                                         "content": [{"type": "text", "text": text}, *extra]}]}


class StandinModelTests(unittest.TestCase):
    def step(self, *messages, tools=CLAUDE_TOOLS):
        body = {"tools": tools, "messages": [{"role": "user", "content": "List targets."}, *messages]}
        return DRIVER.STANDIN.scripted_step(body, "ShareX capture evaluation 1")

    def test_script_lists_targets_then_captures_the_named_target_then_stops(self):
        self.assertEqual(self.step(), ("mcp__sharex__targets_list", {}))
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AA=="}}
        self.assertEqual(self.step(tool_result(json.dumps(TARGETS))), ("mcp__sharex__screenshot", {"target": "window-token"}))
        self.assertEqual(self.step(tool_result(json.dumps(TARGETS)), tool_result("{}", image)),
                         (None, DRIVER.STANDIN.DONE))

    def test_script_stops_with_a_reason_when_it_cannot_continue(self):
        self.assertEqual(self.step(tools=[{"name": "Bash"}]), (None, DRIVER.STANDIN.TOOL_NOT_OFFERED))
        self.assertEqual(self.step(tool_result("not json")), (None, DRIVER.STANDIN.TARGETS_UNREADABLE))
        other = {**TARGETS, "result": {"targets": [TARGETS["result"]["targets"][0]]}}
        self.assertEqual(self.step(tool_result(json.dumps(other))), (None, DRIVER.STANDIN.TARGET_MISSING))

    def test_streamed_tool_call_carries_the_input_as_one_json_delta(self):
        message = DRIVER.STANDIN.anthropic_message({"tools": CLAUDE_TOOLS, "messages": [tool_result(json.dumps(TARGETS))]},
                                                   "ShareX capture evaluation 1")
        events = DRIVER.STANDIN.anthropic_events(message)
        self.assertEqual([event["type"] for event in events],
                         ["message_start", "content_block_start", "content_block_delta", "content_block_stop",
                          "message_delta", "message_stop"])
        self.assertEqual(events[1]["content_block"]["input"], {})
        self.assertEqual(json.loads(events[2]["delta"]["partial_json"]), {"target": "window-token"})
        self.assertEqual(events[4]["delta"]["stop_reason"], "tool_use")
        self.assertTrue(DRIVER.STANDIN.sse(events).startswith(b"event: message_start\ndata: {"))

    def test_server_binds_loopback_records_bodies_and_refuses_other_model_apis(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "requests.jsonl"
            server = DRIVER.STANDIN.StandinServer(capture, "ShareX capture evaluation 1")
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address[:2]
                self.assertEqual(host, "127.0.0.1")
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

                def post(path, body):
                    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", json.dumps(body).encode(),
                                                     {"Content-Type": "application/json"})
                    try:
                        with opener.open(request, timeout=5) as response:
                            return response.status, json.loads(response.read())
                    except urllib.error.HTTPError as error:
                        return error.code, json.loads(error.read())

                status, reply = post("/v1/messages?beta=true", {"tools": CLAUDE_TOOLS, "messages": []})
                self.assertEqual((status, reply["content"][0]["name"]), (200, "mcp__sharex__targets_list"))
                self.assertEqual(post("/v1/responses", {"tools": []})[0], 500)
            finally:
                server.shutdown()
                server.server_close()
            self.assertEqual(len(DRIVER.STANDIN.recorded_bodies(capture, "/v1/messages")), 1)
            self.assertEqual(DRIVER.STANDIN.recorded_bodies(capture, "/responses"), [{"tools": []}])
            self.assertEqual(DRIVER.STANDIN.recorded_bodies(Path(directory) / "missing.jsonl", ""), [])


class ClientCheckTests(unittest.TestCase):
    def test_expected_tool_names_follow_each_client_naming(self):
        self.assertIn("mcp__sharex__targets_list", DRIVER.EXPECTED_TOOLS["claude"])
        self.assertIn("mcp__sharex/recording_start", DRIVER.EXPECTED_TOOLS["codex"])
        self.assertEqual(len(DRIVER.EXPECTED_TOOLS["claude"]), 8)
        self.assertEqual(len(DRIVER.EXPECTED_TOOLS["codex"]), 8)

    def test_offered_tools_read_claude_names_and_codex_namespaces(self):
        codex = {"tools": [{"type": "function", "name": "shell"}, {"type": "web_search"},
                           {"type": "namespace", "name": "mcp__sharex", "tools": [
                               {"type": "function", "name": DRIVER.NATIVE.tool_name(operation)}
                               for operation in DRIVER.NATIVE.OPERATIONS]}]}
        self.assertEqual(DRIVER.offered_sharex_tools([codex]), DRIVER.EXPECTED_TOOLS["codex"])
        self.assertEqual(DRIVER.offered_sharex_tools([{"tools": CLAUDE_TOOLS}, {"messages": []}, ["unexpected"]]),
                         DRIVER.EXPECTED_TOOLS["claude"])
        dotted = {"tools": [{"name": "mcp__sharex__targets.list"}]}
        self.assertNotEqual(DRIVER.offered_sharex_tools([dotted]), DRIVER.EXPECTED_TOOLS["claude"])

    def test_registration_runs_the_settings_command_with_the_pinned_client(self):
        binary = "/Applications/ShareX 'QA'.app/Contents/MacOS/ShareX"
        self.assertEqual(DRIVER.client_registration("claude", "/runner/bin/claude", binary),
                         ["/runner/bin/claude", "mcp", "add", "--transport", "stdio", "--scope", "user", "sharex", "--",
                          binary, "--agent", "mcp"])
        self.assertEqual(DRIVER.client_registration("codex", "/runner/bin/codex", binary),
                         ["/runner/bin/codex", "mcp", "add", "sharex", "--", binary, "--agent", "mcp"])

    def test_codex_config_keeps_the_registered_entry_and_adds_the_standin_only_on_request(self):
        registered = '[mcp_servers.sharex]\ncommand = "/Applications/ShareX.app/Contents/MacOS/ShareX"\n'
        plain = DRIVER.codex_config(registered)
        self.assertIn(registered.strip(), plain)
        self.assertNotIn("model_provider", plain)
        first_table = plain.index("[")
        self.assertIn('cli_auth_credentials_store = "file"', plain[:first_table])
        provider = DRIVER.codex_config(registered, 43123)
        self.assertIn('model_provider = "standin"', provider[:provider.index("[")])
        self.assertIn('base_url = "http://127.0.0.1:43123/v1"', provider)
        self.assertIn(f'env_key = "{DRIVER.STANDIN_KEY}"', provider)

    def test_registered_claude_environment_leaves_simple_mode(self):
        environment = DRIVER.registered_claude_environment({"CLAUDE_CODE_SIMPLE": "1", "HOME": "/isolated"})
        self.assertEqual(environment, {"HOME": "/isolated", "DISABLE_TELEMETRY": "1"})

    def test_claude_stream_yields_tool_calls_results_and_images(self):
        events = [{"type": "system", "subtype": "init"},
                  {"type": "assistant", "message": {"content": [
                      {"type": "tool_use", "name": "mcp__sharex__targets_list", "input": {}}]}},
                  {"type": "user", "message": {"content": [
                      {"type": "tool_result", "content": [{"type": "text", "text": '{"ok":true}'}]}]}},
                  {"type": "user", "message": {"content": "plain prompt"}},
                  {"type": "result", "subtype": "success"}]
        stream = "\n".join(json.dumps(event) for event in events) + "\nnot json\n"
        calls, results = DRIVER.claude_tool_exchange(stream)
        self.assertEqual(calls, [{"name": "mcp__sharex__targets_list", "input": {}}])
        self.assertEqual(results, [{"isError": False, "text": '{"ok":true}'}])
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AA=="}}
        body = {"messages": [tool_result("{}"), tool_result("{}", image)]}
        self.assertEqual(DRIVER.tool_result_images(body), 1)
        self.assertEqual(DRIVER.tool_result_images(["unexpected"]), 0)


class BoundedProtocolTests(unittest.TestCase):
    def exercise(self, source, action):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = DRIVER.NATIVE.Evidence(root)
            run = types.SimpleNamespace(evidence=evidence, children=[])
            helper = root / "protocol-child.py"
            helper.write_text(source)
            environment = DRIVER.isolated_environment(root / "isolated")
            client = DRIVER.ClientRPC(run, "test", [sys.executable, "-u", str(helper)], environment, root)
            try:
                action(client)
            finally:
                client.close()
                evidence.events.close()
            self.assertIsNotNone(client.process.poll())

    def test_hung_client_times_out_and_is_stopped(self):
        def check(client):
            started = time.monotonic()
            with self.assertRaisesRegex(DRIVER.Failure, "exceeded"):
                client.rpc("test", {}, timeout=0.1)
            self.assertLess(time.monotonic() - started, 2)

        self.exercise("import time\ntime.sleep(60)\n", check)

    def test_unexpected_approval_request_is_rejected(self):
        def check(client):
            with self.assertRaisesRegex(DRIVER.Failure, "unexpected approval"):
                client.rpc("test", {})

        self.exercise("import json, sys\nsys.stdin.readline()\nprint(json.dumps({'id': 99, 'method': 'approval', 'params': {}}))\n", check)


if __name__ == "__main__":
    unittest.main()
