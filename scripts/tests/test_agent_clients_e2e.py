import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock
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
