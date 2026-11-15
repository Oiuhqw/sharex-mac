import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "profiler-preflight.py"
SPEC = importlib.util.spec_from_file_location("profiler_preflight", SCRIPT)
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)
XCTRACE_DOCUMENTATION_NAMES = ("xctrace-record-help", "xctrace-export-help", "xctrace-templates")


def child(name, code, manual=False):
    return PREFLIGHT.Command(name, (sys.executable, "-u", "-c", code), manual=manual)


class CommandCollectionTests(unittest.TestCase):
    def collect(self, command, timeout=5):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            record = PREFLIGHT.collect_command(command, out, timeout=timeout)
            files = {path.name: path.read_bytes() for path in out.iterdir()}
            self.assertEqual(json.loads(files[f"{command.name}.json"]), record)
            self.assertLessEqual(record["started"]["monotonicBeforeNs"], record["started"]["monotonicAfterNs"])
            self.assertLessEqual(record["started"]["monotonicAfterNs"], record["finished"]["monotonicBeforeNs"])
            self.assertLessEqual(record["finished"]["monotonicBeforeNs"], record["finished"]["monotonicAfterNs"])
            self.assertTrue(record["started"]["wallUTC"].endswith("+00:00"))
            self.assertTrue(record["finished"]["wallUTC"].endswith("+00:00"))
            return record, files

    def test_raw_bytes_and_nonzero_exit_are_preserved(self):
        record, files = self.collect(child("failure", "import sys; sys.stdout.buffer.write(b'raw\\xff'); "
                                         "sys.stderr.buffer.write(b'error\\xfe'); sys.exit(7)"))
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["exitCode"], 7)
        self.assertEqual(files[record["stdout"]], b"raw\xff")
        self.assertEqual(files[record["stderr"]], b"error\xfe")

    def test_missing_executable_retains_error_and_empty_raw_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = str(Path(temporary) / "absent-program")
            record, files = self.collect(PREFLIGHT.Command("missing", (missing,)))
        self.assertEqual(record["status"], "launch_error")
        self.assertEqual(record["error"]["type"], "FileNotFoundError")
        self.assertIn(missing, record["error"]["message"])
        self.assertIsNone(record["exitCode"])
        self.assertFalse(record["executableCheck"]["isFile"])
        self.assertEqual(files[record["stdout"]], b"")
        self.assertEqual(files[record["stderr"]], b"")

    def test_existing_invalid_executable_retains_launch_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            invalid = Path(temporary) / "invalid-program"
            invalid.write_text("not an executable", encoding="utf-8")
            invalid.chmod(0o700)
            record, _ = self.collect(PREFLIGHT.Command("invalid", (str(invalid),)))
        self.assertEqual(record["status"], "launch_error")
        self.assertIn("error", record)
        self.assertIsNone(record["exitCode"])

    def test_timeout_kills_owned_process_and_retains_partial_output(self):
        started = time.monotonic()
        record, files = self.collect(child("hang", "import time; print('before timeout'); time.sleep(60)"), timeout=0.2)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(record["status"], "timed_out")
        self.assertIsNotNone(record["exitCode"])
        self.assertNotEqual(record["exitCode"], 0)
        self.assertEqual(files[record["stdout"]], b"before timeout" + os.linesep.encode())
        self.assertEqual(record["termination"]["ownedPID"], record["pid"])
        self.assertEqual(record["termination"]["processGroup"], os.name == "posix")

    def test_shell_characters_are_literal_arguments_and_pagers_are_disabled(self):
        literal = "$(echo leaked) & echo leaked; `echo leaked`"
        command = PREFLIGHT.Command("literal", (sys.executable, "-c",
            "import json, os, sys; print(json.dumps([sys.argv[1], os.environ['MANPAGER'], os.environ['PAGER']]))",
            literal))
        record, files = self.collect(command)
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(json.loads(files[record["stdout"]]), [literal, "cat", "cat"])

    def test_manual_raw_and_plain_output_are_both_preserved(self):
        record, files = self.collect(child("manual", "import sys; sys.stdout.buffer.write(b'X\\bX _\\bY \\x1b[1mZ\\x1b[0m\\n')", manual=True))
        self.assertEqual(record["status"], "completed")
        self.assertEqual(files[record["stdout"]], b"X\bX _\bY \x1b[1mZ\x1b[0m\n")
        self.assertEqual(files[record["plainText"]].decode().strip(), "X Y Z")

    def test_zero_exit_with_empty_manual_is_incomplete(self):
        record, files = self.collect(child("manual", "pass", manual=True))
        self.assertEqual(record["status"], "empty_manual")
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(files[record["plainText"]], b"")

    def test_xctrace_documentation_on_either_stream_preserves_raw_output(self):
        for name in XCTRACE_DOCUMENTATION_NAMES:
            for stream in ("stdout", "stderr"):
                with self.subTest(name=name, stream=stream):
                    record, files = self.collect(child(name,
                        f"import sys; sys.{stream}.buffer.write(b'installed documentation\\n')"))
                    self.assertEqual(record["status"], "completed")
                    self.assertEqual(record["exitCode"], 0)
                    for output in ("stdout", "stderr"):
                        expected = b"installed documentation\n" if output == stream else b""
                        self.assertEqual(files[record[output]], expected)


class DiscoveryTests(unittest.TestCase):
    def discover(self, commands, tools=(sys.executable,)):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(PREFLIGHT, "TOOL_PATHS", tools):
            out = Path(temporary) / "evidence"
            report = PREFLIGHT.discover(out, "test-commit", commands=commands)
            self.assertEqual(json.loads((out / "preflight.json").read_text()), report)
            self.assertFalse(report["productionE2EPassed"])
            self.assertFalse(report["profileCollected"])
            self.assertFalse(report["samplingSyntaxValidated"])
            self.assertFalse(report["capabilityProbeRun"])
            for record in report["commands"]:
                self.assertTrue((out / record["stdout"]).is_file())
                self.assertTrue((out / record["stderr"]).is_file())
            return report

    def test_success_means_documentation_collected_only(self):
        report = self.discover((child("manual", "print('installed manual')", manual=True),))
        self.assertEqual(report["outcome"], "discovery_complete")
        self.assertEqual(report["failedCommands"], [])
        self.assertEqual(report["unavailableTools"], [])
        self.assertEqual(report["commit"], "test-commit")

    def test_zero_exit_with_empty_xctrace_documentation_is_incomplete(self):
        for name in XCTRACE_DOCUMENTATION_NAMES:
            for output in (b"", b" \t\r\n"):
                with self.subTest(name=name, output=output):
                    report = self.discover((child(name,
                        f"import sys; sys.stdout.buffer.write({output!r}); sys.stderr.buffer.write({output!r})"),))
                    self.assertEqual(report["outcome"], "incomplete")
                    self.assertEqual(report["failedCommands"], [name])
                    self.assertEqual(report["commands"][0]["status"], "empty_documentation")
                    self.assertEqual(report["commands"][0]["exitCode"], 0)

    def test_xctrace_documentation_on_either_stream_completes_discovery(self):
        for name in XCTRACE_DOCUMENTATION_NAMES:
            for stream in ("stdout", "stderr"):
                with self.subTest(name=name, stream=stream):
                    report = self.discover((child(name, f"import sys; print('installed documentation', file=sys.{stream})"),))
                    self.assertEqual(report["outcome"], "discovery_complete")
                    self.assertEqual(report["failedCommands"], [])

    def test_failed_xctrace_command_keeps_later_manual_and_inventory(self):
        report = self.discover((child("xctrace-templates", "import sys; print('unsupported', file=sys.stderr); sys.exit(64)"),
                                child("manual", "print('installed manual')", manual=True),
                                child("inventory", "print('pid ppid user lstart comm')")))
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["failedCommands"], ["xctrace-templates"])
        self.assertEqual([record["status"] for record in report["commands"]], ["failed", "completed", "completed"])
        self.assertEqual(report["commands"][0]["exitCode"], 64)

    def test_missing_manual_or_tool_cannot_pass(self):
        report = self.discover((child("manual", "pass", manual=True),))
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["failedCommands"], ["manual"])
        with tempfile.TemporaryDirectory() as temporary:
            absent = str(Path(temporary) / "spindump")
            report = self.discover((child("manual", "print('manual')", manual=True),), tools=(absent,))
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["unavailableTools"], [absent])

    def test_xctrace_path_must_resolve_to_an_available_executable(self):
        for output in ("", "relative/path", str(SCRIPT.parent / "absent-xctrace")):
            with self.subTest(output=output):
                report = self.discover((child("xctrace-path", f"print({output!r})"),))
                self.assertEqual(report["outcome"], "incomplete")

    def test_main_returns_failure_after_incomplete_discovery(self):
        commands = (child("manual", "pass", manual=True),)
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(PREFLIGHT, "TOOL_PATHS", (sys.executable,)):
            out = Path(temporary) / "evidence"
            discover = PREFLIGHT.discover
            with mock.patch.object(sys, "argv", [str(SCRIPT), "--out", str(out), "--commit", "test"]), \
                 mock.patch.object(PREFLIGHT, "discover", side_effect=lambda path, commit: discover(path, commit, commands)):
                self.assertEqual(PREFLIGHT.main(), 1)
            self.assertEqual(json.loads((out / "preflight.json").read_text())["outcome"], "incomplete")

    def test_cli_rejects_existing_output_without_overwriting_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "preflight.json"
            evidence.write_bytes(b"previous evidence")
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary, "--commit", "test"],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(evidence.read_bytes(), b"previous evidence")


class ReadOnlyScopeTests(unittest.TestCase):
    def test_production_commands_are_only_the_reviewed_documentation_discovery(self):
        self.assertEqual([command.argv for command in PREFLIGHT.COMMANDS], [
            ("/usr/bin/sw_vers",), ("/usr/bin/uname", "-m"), ("/usr/bin/xcode-select", "-p"),
            ("/usr/bin/xcodebuild", "-version"), ("/usr/bin/uptime",),
            ("/usr/sbin/sysctl", "-n", "hw.logicalcpu"), ("/usr/bin/id",),
            ("/usr/bin/sudo", "-n", "/usr/bin/true"), ("/usr/bin/man", "8", "spindump"),
            ("/usr/bin/man", "1", "sample"), ("/usr/bin/xcrun", "--find", "xctrace"),
            ("/usr/bin/xcrun", "xctrace", "help", "record"), ("/usr/bin/xcrun", "xctrace", "help", "export"),
            ("/usr/bin/xcrun", "xctrace", "list", "templates"), ("/usr/bin/csrutil", "status"),
            ("/bin/ps", "-axo", "pid,ppid,user,lstart,comm")])
        self.assertEqual(PREFLIGHT.TIMEOUT_SECONDS, 10)

    def test_workflow_routes_probe_to_script_validation_and_always_uploads_logs(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/agent-capture.yml").read_text()
        validation = workflow.split("  script-validation:", 1)[1].split("  native:", 1)[0]
        self.assertIn("if: ${{ inputs.frame_gap_probe }}", validation)
        self.assertIn("runs-on: macos-15", validation)
        self.assertIn("timeout-minutes: 5", validation)
        self.assertIn("DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer", validation)
        scripts, agent = validation.split("- name: Validate scripts", 1)[1].split("- name: Validate agent protocol", 1)
        agent, upload = agent.split("- name: Store validation logs", 1)
        for step, command in ((scripts, "python3 -m unittest discover -s scripts/tests -v 2>&1 | tee script-tests.log"),
                              (agent, "swift test --package-path Packages/ShareXAgent 2>&1 | tee agent-tests.log")):
            self.assertIn("shell: bash", step)
            self.assertIn("set -o pipefail", step)
            self.assertIn(command, step)
            self.assertNotIn("if:", step)
            self.assertNotIn("continue-on-error:", step)
        self.assertIn("if: ${{ always() }}", upload)
        self.assertIn("name: validation-${{ github.sha }}", upload)
        self.assertIn("script-tests.log", upload)
        self.assertIn("agent-tests.log", upload)
        native = workflow.split("  native:", 1)[1]
        self.assertIn("if: ${{ !inputs.frame_gap_probe }}", native.split("steps:", 1)[0])
        self.assertNotIn("scripts/frame-gap-probe.py", workflow)
        for excluded in ("actions: read", "SOURCE_", "download-artifact", "profiler-", "sudo", "ci-capture-permissions",
                         "codesign", "defaults write", "xcodebuild", "ci-setup", "frame-gap-", "agent-capture-e2e",
                         "agent-setup-e2e", "agent-clients-e2e", "pip install", "npm install"):
            self.assertNotIn(excluded, validation)
        dispatch = workflow.split("  workflow_dispatch:", 1)[1].split("permissions:", 1)[0]
        self.assertLessEqual(dispatch.count("type: boolean"), 10)


if __name__ == "__main__":
    unittest.main()
