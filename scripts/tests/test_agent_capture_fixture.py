import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


SOURCE = Path(__file__).resolve().parents[1] / "agent-capture-fixture.swift"
WRITE_START = "fixture-test-write-start"
WRITE_END = "fixture-test-write-end"
WRITE_HELD = "fixture-test-write-held"
COMMAND_HANDLED = "fixture-test-command-handled"


@unittest.skipUnless(sys.platform == "darwin", "The fixture requires a macOS desktop.")
class NativeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="sharex-fixture-build-")
        cls.addClassCleanup(cls.build.cleanup)
        source = SOURCE.read_text()
        pattern = r"(?m)^([ \t]*)try data\.write\(to: .+, options: \.atomic\)$"

        def slow_write(match):
            indent = match[1]
            return (f'{indent}let snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Any]\n'
                    f'{indent}let commandID = snapshot["commandID"] as! String\n'
                    f'{indent}let gate = URL(fileURLWithPath: CommandLine.arguments[1])\n'
                    f'{indent}    .appendingPathComponent("hold-\\(commandID)")\n'
                    f"{indent}Thread.sleep(forTimeInterval: 0.75)\n"
                    f'{indent}if FileManager.default.fileExists(atPath: gate.path) {{\n'
                    f'{indent}    FileHandle.standardError.write(Data("{WRITE_HELD}\\t\\(commandID)\\n".utf8))\n'
                    f'{indent}    let deadline = ProcessInfo.processInfo.systemUptime + 10\n'
                    f'{indent}    while FileManager.default.fileExists(atPath: gate.path) {{\n'
                    f'{indent}        guard ProcessInfo.processInfo.systemUptime < deadline else {{\n'
                    f'{indent}            throw NSError(domain: "FixtureTestWriteGateTimeout", code: 1)\n'
                    f'{indent}        }}\n'
                    f'{indent}        Thread.sleep(forTimeInterval: 0.01)\n'
                    f'{indent}    }}\n'
                    f'{indent}}}\n'
                    f'{indent}FileHandle.standardError.write(Data("{WRITE_START}\\t\\(commandID)\\n".utf8))\n'
                    f"{match[0]}\n"
                    f'{indent}FileHandle.standardError.write(Data("{WRITE_END}\\t\\(commandID)\\n".utf8))')

        source, count = re.subn(pattern, slow_write, source)
        if count != 1:
            raise AssertionError(f"Expected one atomic fixture state write, found {count}.")
        source = source.replace("NSApp.terminate(nil)", "NSApp.terminate(nil)\n            NSApp.terminate(nil)")
        blocked = "screen.visibleFrame.width >= 760"
        encoding = 'if let failure { state["reason"] = failure }'
        handled = "lastCommand = id"
        if any(source.count(point) != 1 for point in (blocked, encoding, handled)):
            raise AssertionError("Fixture launch or JSON serialization injection point changed.")
        source = source.replace(handled, handled + '\n            FileHandle.standardError.write('
                                f'Data("{COMMAND_HANDLED}\\t\\(id)\\n".utf8))')
        variants = {
            "slow": source,
            "blocked": source.replace(blocked, "screen.visibleFrame.width >= 1_000_000"),
            "encoding-failure": source.replace(encoding, encoding + '\n        state["uptime"] = Double.nan'),
        }
        cls.executables = {}
        for name, text in variants.items():
            path = Path(cls.build.name) / f"{name}.swift"
            executable = path.with_suffix("")
            path.write_text(text)
            result = subprocess.run(
                ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
                 "-target", f"{platform.machine()}-apple-macosx14.0", str(path), "-o", str(executable)],
                capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise AssertionError(f"Fixture compilation failed:\n{result.stdout}\n{result.stderr}")
            cls.executables[name] = executable

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sharex-fixture-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.state_path = self.directory / "state.json"
        self.log_path = self.directory / "stderr.log"
        self.process = None
        self.previous_state = None

    def launch(self, variant="slow"):
        log = self.log_path.open("wb")
        self.addCleanup(log.close)
        self.process = subprocess.Popen(
            [str(self.executables[variant]), str(self.directory), "ShareX fixture regression " + str(uuid.uuid4())],
            stdout=log, stderr=log)
        self.addCleanup(self.stop)

    def stop(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)

    def state(self):
        try:
            value = json.loads(self.state_path.read_text())
        except FileNotFoundError:
            return None
        if self.previous_state:
            for field in ("uptime", "tick", "draws"):
                self.assertGreaterEqual(value[field], self.previous_state[field], field)
        self.previous_state = value
        return value

    def events(self, *kinds):
        return [tuple(line.split("\t", 1)) for line in self.log_path.read_text().splitlines()
                if line.partition("\t")[0] in (kinds or (WRITE_START, WRITE_END))]

    def assert_paired_writes(self, events):
        self.assertEqual(len(events) % 2, 0, events)
        for start, end in zip(events[::2], events[1::2]):
            self.assertEqual(start[0], WRITE_START)
            self.assertEqual(end, (WRITE_END, start[1]))

    def wait_for(self, predicate, description, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            if self.process.poll() is not None:
                self.fail(f"Fixture exited with {self.process.returncode} while waiting for {description}: "
                          + self.log_path.read_text())
            time.sleep(0.01)
        self.fail(f"Timed out waiting for {description}: " + self.log_path.read_text())

    def command(self, action, **values):
        command_id = str(uuid.uuid4())
        temporary = self.directory / "command.tmp"
        temporary.write_text(json.dumps({"id": command_id, "action": action, **values}))
        temporary.replace(self.directory / "command.json")
        return command_id

    def control(self, action, **values):
        command_id = self.command(action, **values)
        return self.wait_for(lambda: (state if (state := self.state())
                                     and state["commandID"] == command_id else None), action)

    def quit_during_write(self, hold_final=False):
        previous_id = self.previous_state["commandID"]
        gate = self.directory / f"hold-{previous_id}"
        gate.touch()
        self.wait_for(lambda: (WRITE_HELD, previous_id) in self.events(WRITE_HELD), "a held write before quit")
        command_id = self.command("quit")
        if hold_final:
            (self.directory / f"hold-{command_id}").touch()
        self.wait_for(lambda: (COMMAND_HANDLED, command_id) in self.events(COMMAND_HANDLED), "quit command")
        gate.unlink()
        return command_id

    def test_slow_atomic_writes_preserve_animation_commands_static_proof_and_final_ack(self):
        self.launch()
        first = self.wait_for(self.state, "first state")
        self.assertEqual(first["status"], "ready")
        for _ in range(3):
            following = self.wait_for(lambda: (state if (state := self.state())
                                              and state["uptime"] > first["uptime"] else None), "fresh state")
            self.assertGreaterEqual(following["draws"] - first["draws"], 3,
                                    "Slow state writes must not stop the fixture's main-thread drawing.")
            first = following

        stage = self.control("stage", stage=2)
        self.assertEqual(stage["stage"], 2)
        self.assertGreater(stage["draws"], first["draws"])
        static = self.control("mode", mode="static")
        observations = [self.control("observe") for _ in range(3)]
        for state in observations:
            for field in ("draws", "tick", "stage", "mode", "pid", "windowID"):
                self.assertEqual(state[field], static[field], field)
        self.assertGreaterEqual(observations[-1]["uptime"] - static["uptime"], 2)

        quit_id = self.quit_during_write()
        self.assertEqual(self.process.wait(timeout=6), 0, self.log_path.read_text())
        final = self.state()
        self.assertEqual(final["commandID"], quit_id)
        self.assertEqual(final["draws"], static["draws"])
        self.assertGreater(final["uptime"], observations[-1]["uptime"])
        events = self.events()
        self.assert_paired_writes(events)
        self.assertEqual(events[-2:], [(WRITE_START, quit_id), (WRITE_END, quit_id)])
        self.assertEqual(events.count((WRITE_START, quit_id)), 1,
                         "Quit must drain the active write and publish exactly one final snapshot.")

    def test_blocked_launch_publishes_reason_before_exit_three(self):
        self.launch("blocked")
        self.assertEqual(self.process.wait(timeout=6), 3)
        state = self.state()
        self.assertEqual(state["status"], "blocked")
        self.assertIn("local desktop", state["reason"])
        self.assertEqual(self.events(), [(WRITE_START, ""), (WRITE_END, "")])

    def test_serialization_failure_exits_three_without_writing(self):
        self.launch("encoding-failure")
        self.assertEqual(self.process.wait(timeout=6), 3)
        self.assertFalse(self.state_path.exists())
        self.assertEqual(self.events(), [])
        self.assertIn("Fixture state write failed:", self.log_path.read_text())

    def test_unwritable_state_exits_three(self):
        self.state_path.mkdir()
        self.launch()
        self.assertEqual(self.process.wait(timeout=6), 3)
        self.assertEqual(self.events(), [(WRITE_START, "")])
        self.assertIn("Fixture state write failed:", self.log_path.read_text())

    def test_final_write_failure_exits_three(self):
        self.launch()
        self.wait_for(self.state, "first state")
        quit_id = self.quit_during_write(hold_final=True)
        self.wait_for(lambda: (WRITE_HELD, quit_id) in self.events(WRITE_HELD), "held final write")
        self.state_path.unlink()
        self.state_path.mkdir()
        (self.directory / f"hold-{quit_id}").unlink()
        self.assertEqual(self.process.wait(timeout=6), 3)
        events = self.events()
        self.assert_paired_writes(events[:-1])
        self.assertEqual(events[-1], (WRITE_START, quit_id))
        self.assertEqual(events.count((WRITE_START, quit_id)), 1)
        self.assertIn("Fixture state write failed:", self.log_path.read_text())


if __name__ == "__main__":
    unittest.main()
