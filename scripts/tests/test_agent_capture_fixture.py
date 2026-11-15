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
            return (f'{indent}FileHandle.standardError.write(Data("{WRITE_START}\\n".utf8))\n'
                    f"{indent}Thread.sleep(forTimeInterval: 0.75)\n"
                    f"{match[0]}\n"
                    f'{indent}FileHandle.standardError.write(Data("{WRITE_END}\\n".utf8))')

        source, count = re.subn(pattern, slow_write, source)
        if count != 1:
            raise AssertionError(f"Expected one atomic fixture state write, found {count}.")
        source = source.replace("NSApp.terminate(nil)", "NSApp.terminate(nil)\n            NSApp.terminate(nil)")
        blocked = "screen.visibleFrame.width >= 760"
        encoding = 'if let failure { state["reason"] = failure }'
        if source.count(blocked) != 1 or source.count(encoding) != 1:
            raise AssertionError("Fixture launch or JSON serialization injection point changed.")
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

    def events(self):
        return [line for line in self.log_path.read_text().splitlines() if line in (WRITE_START, WRITE_END)]

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

    def next_write(self):
        previous = self.events().count(WRITE_START)
        return self.wait_for(lambda: (starts if (starts := self.events().count(WRITE_START)) > previous else None),
                             "a write before quit")

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

        active = self.next_write()
        quit_id = self.command("quit")
        self.assertEqual(self.process.wait(timeout=6), 0, self.log_path.read_text())
        final = self.state()
        self.assertEqual(final["commandID"], quit_id)
        self.assertEqual(final["draws"], static["draws"])
        self.assertGreater(final["uptime"], observations[-1]["uptime"])
        self.assertEqual(self.events(), [WRITE_START, WRITE_END] * (active + 1),
                         "Quit must drain the active write and publish exactly one final snapshot.")

    def test_blocked_launch_publishes_reason_before_exit_three(self):
        self.launch("blocked")
        self.assertEqual(self.process.wait(timeout=6), 3)
        state = self.state()
        self.assertEqual(state["status"], "blocked")
        self.assertIn("local desktop", state["reason"])
        self.assertEqual(self.events(), [WRITE_START, WRITE_END])

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
        self.assertEqual(self.events(), [WRITE_START])
        self.assertIn("Fixture state write failed:", self.log_path.read_text())

    def test_final_write_failure_exits_three(self):
        self.launch()
        self.wait_for(self.state, "first state")
        active = self.next_write()
        self.command("quit")
        self.wait_for(lambda: self.events().count(WRITE_START) == active + 1, "final write")
        self.state_path.unlink()
        self.state_path.mkdir()
        self.assertEqual(self.process.wait(timeout=6), 3)
        self.assertEqual(self.events(), [WRITE_START, WRITE_END] * active + [WRITE_START])
        self.assertIn("Fixture state write failed:", self.log_path.read_text())


if __name__ == "__main__":
    unittest.main()
