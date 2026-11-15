import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("frame_gap_startup", Path(__file__).resolve().parents[1] / "frame-gap-startup.py")
STARTUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STARTUP)
REQUEST = "00000000-0000-0000-0000-000000000001"


class PrefixTests(unittest.TestCase):
    def test_parser_supplies_the_real_discovery_arguments(self):
        targets = [{"kind": "window", "name": "fixture", "token": "window", "widthPoints": 640,
                    "heightPoints": 480, "pixelScale": 2},
                   {"kind": "display", "name": "display", "token": "display", "widthPoints": 1920,
                    "heightPoints": 1080, "pixelScale": 2}]

        def discover(args):
            run = object.__new__(STARTUP.StartupRun)
            run.args = args
            run.geometry = {"title": "fixture", "scale": 2, "displayBounds": {"width": 1920, "height": 1080}}
            run.cli = mock.Mock(return_value={"targets": targets})
            run.evidence = SimpleNamespace(emit=mock.Mock())
            client = SimpleNamespace(call=run.cli)
            run.discover(client)
            self.assertEqual(run.window_target["token"], "window")
            self.assertEqual(run.display_target["token"], "display")
            return 0

        with mock.patch.object(STARTUP.sys, "argv", ["startup", "--arm", "control", "--app", "/app",
                               "--build-settings", "/settings", "--out", "/out"]), \
             mock.patch.object(STARTUP, "run_arm", side_effect=discover):
            self.assertEqual(STARTUP.main(), 0)

    def run_with_prefix(self):
        run = object.__new__(STARTUP.StartupRun)
        run.evidence = SimpleNamespace(steps=[{"name": name, "status": "passed"} for name in STARTUP.PREFIX_STEPS], emit=mock.Mock())
        run.verified = [{"mode": mode, "kind": "screenshot"} for mode in ("window", "display", "region", "window")]
        run.verified += [{"mode": mode, "kind": "recording"} for mode in ("window", "display", "region", "window", "display", "window", "region")]
        run.app = SimpleNamespace(pid=11)
        run.fixture = SimpleNamespace(pid=22)
        return run

    def test_requires_every_original_step_and_decoder_in_order(self):
        run = self.run_with_prefix()
        run.check_prefix()
        run.evidence.emit.assert_called_once()
        for mutation in (lambda value: value.verified.pop(),
                         lambda value: value.evidence.steps.pop(5),
                         lambda value: value.evidence.steps[4].update(status="failed"),
                         lambda value: value.verified.reverse()):
            run = self.run_with_prefix()
            mutation(run)
            with self.assertRaises(STARTUP.NATIVE.Failure):
                run.check_prefix()

    def test_only_target_mcp_start_gets_selected_request_identity(self):
        client = object.__new__(STARTUP.StartupMCP)
        client.run = SimpleNamespace(request_id=REQUEST)
        with mock.patch.object(STARTUP.NATIVE.MCP, "call", return_value={}) as call:
            client.call("recording.start", {"maxBytes": 1048576})
            self.assertEqual(call.call_args.args[2], REQUEST)
            client.call("recording.start", {"maxBytes": 1024}, request_id="invalid", error="invalid_request")
            self.assertEqual(call.call_args.args[2], "invalid")
            client.call("recording.status", {"sessionID": REQUEST}, request_id="status")
            self.assertEqual(call.call_args.args[2], "status")

    def test_control_runs_original_byte_body_and_then_stops(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = STARTUP.StartupEvidence(Path(temporary))
            evidence.run = SimpleNamespace(args=SimpleNamespace(arm="control"), check_prefix=mock.Mock())
            ran = []
            with self.assertRaises(STARTUP.PrefixComplete):
                with evidence.step(STARTUP.BYTE_STEP):
                    ran.append("original-body")
            self.assertEqual(ran, ["original-body"])
            self.assertEqual(evidence.steps[-1]["status"], "passed")
            evidence.events.close()

    def test_metadata_never_runs_video_step_or_claims_it_passed(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = STARTUP.StartupEvidence(Path(temporary))
            evidence.run = SimpleNamespace(args=SimpleNamespace(arm="metadata"), check_prefix=mock.Mock(), metadata_capture=mock.Mock())
            with self.assertRaises(STARTUP.PrefixComplete):
                with evidence.step(STARTUP.BYTE_STEP):
                    self.fail("Metadata entered the original video step")
            evidence.run.metadata_capture.assert_called_once()
            self.assertEqual([step["name"] for step in evidence.steps], ["metadata_only_diagnostic_capture"])
            evidence.events.close()

    def test_target_uses_native_poll_delay_after_each_response(self):
        run = object.__new__(STARTUP.StartupRun)
        clock = [0.0]
        launches = []

        def status(*args):
            launches.append(clock[0])
            clock[0] += 0.03
            return {"state": "completed" if len(launches) == 3 else "recording"}

        run.cli = status
        with mock.patch.object(STARTUP.NATIVE.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(STARTUP.NATIVE.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            run.terminal(REQUEST)
        self.assertEqual(launches, [0, 0.13, 0.26])

    def test_noise_timing_routes_all_four_metadata_targets_in_the_required_order(self):
        for _, timing, _ in STARTUP.COMPARISONS["noise-timing"]:
            with self.subTest(timing=timing):
                run = object.__new__(STARTUP.StartupRun)
                run.args = SimpleNamespace(noise_timing=timing)
                run.request_id = REQUEST
                calls = mock.Mock()
                run.control = calls.control
                run.evidence = SimpleNamespace(emit=calls.emit)
                run.selection = mock.Mock(return_value={"mode": "window", "target": "fixture-token"})
                run.clients = [SimpleNamespace(call=calls.start)]
                calls.start.return_value = {"id": REQUEST, "state": "recording", "acceptedFrames": 0}
                completed = {"id": REQUEST, "state": "failed", "stopReason": "diagnostic_metadata_complete",
                             "acceptedFrames": 0, "artifacts": [{"state": "failed"}]}
                run.terminal = calls.terminal
                calls.terminal.return_value = completed
                run.validate_manifest = calls.manifest
                step = {}
                run.metadata_capture(step)
                start = mock.call.start("recording.start", {"mode": "window", "target": "fixture-token", "fps": 15,
                                                          "maxDurationSeconds": 30, "maxBytes": 1048576})
                ack = mock.call.emit("metadata_start_acknowledged", requestID=REQUEST, sessionID=REQUEST,
                                     noiseTiming=timing, acknowledgementUptime=mock.ANY)
                noise = mock.call.control("noise", enabled=True)
                expected = [noise, start, ack] if timing == "before" else [start, ack, noise]
                self.assertEqual(calls.mock_calls, expected + [mock.call.terminal(REQUEST, timeout=40),
                                 mock.call.manifest(completed), mock.call.control("noise", enabled=False)])
                self.assertEqual(step["session"], completed)
                self.assertTrue(step["diagnosticOnly"])
                self.assertFalse(step["byteLimitE2EPassed"])

    def test_noise_timing_parser_requires_an_explicit_metadata_arm(self):
        base = ["startup", "--app", "/app", "--build-settings", "/settings", "--out", "/out"]
        for extra in (["--arm", "control", "--comparison", "noise-timing", "--noise-timing", "after"],
                      ["--arm", "metadata", "--comparison", "noise-timing"],
                      ["--arm", "metadata", "--comparison", "late-noise"],
                      ["--arm", "metadata", "--comparison", "late-noise", "--noise-timing", "after"],
                      ["--arm", "metadata", "--comparison", "noise-timing", "--noise-timing", "late"],
                      ["--arm", "metadata", "--noise-timing", "after"]):
            with self.subTest(arguments=extra), mock.patch.object(STARTUP.sys, "argv", base + extra), \
                 mock.patch.object(STARTUP.sys, "stderr"), self.assertRaises(SystemExit) as raised:
                STARTUP.main()
            self.assertEqual(raised.exception.code, 2)

    def test_bitmap_content_parser_rejects_wrong_timing_arm_mode_and_environment(self):
        base = ["startup", "--app", "/app", "--build-settings", "/settings", "--out", "/out"]
        valid = ["--arm", "metadata", "--comparison", "bitmap-content", "--noise-timing", "before",
                 "--bitmap-content", "constant"]
        cases = [valid[:-2], valid[:], [part if part != "before" else "late" for part in valid],
                 [part if part != "metadata" else "control" for part in valid],
                 [part if part != "bitmap-content" else "noise-timing" for part in valid]]
        for extra in cases:
            with self.subTest(arguments=extra), mock.patch.object(STARTUP.sys, "argv", base + extra), \
                 mock.patch.dict(STARTUP.os.environ, {"SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK": "255"}), \
                 mock.patch.object(STARTUP.sys, "stderr"), self.assertRaises(SystemExit) as raised:
                STARTUP.main()
            self.assertEqual(raised.exception.code, 2)
        for content in ("original", "constant"):
            mask, _ = STARTUP.BITMAP_CONDITIONS[content]
            with mock.patch.object(STARTUP.sys, "argv", base + valid[:-1] + [content]), \
                 mock.patch.dict(STARTUP.os.environ, {"SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK": str(mask)}), \
                 mock.patch.object(STARTUP, "run_arm", return_value=0) as arm:
                self.assertEqual(STARTUP.main(), 0)
                self.assertEqual(arm.call_args.args[0].bitmap_content, content)

    def test_draw_path_parser_requires_matching_mask_primitive_and_no_profiler(self):
        base = ["startup", "--app", "/app", "--build-settings", "/settings", "--out", "/out",
                "--comparison", "bitmap-draw-path", "--arm", "metadata", "--noise-timing", "before"]
        for content, (mask, primitive) in STARTUP.BITMAP_CONDITIONS.items():
            for invalid in (None, "mask", "primitive", "profiler"):
                environment = {"SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK": str(mask),
                               "SHAREX_FRAME_GAP_BITMAP_DRAW_PRIMITIVE": primitive}
                arguments = base + ["--bitmap-content", content]
                if invalid == "mask":
                    environment["SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK"] = str(255 - mask)
                if invalid == "primitive":
                    environment["SHAREX_FRAME_GAP_BITMAP_DRAW_PRIMITIVE"] = "wrong"
                if invalid == "profiler":
                    arguments += ["--profile-preflight", "/profile"]
                with self.subTest(content=content, invalid=invalid), \
                     mock.patch.object(STARTUP.sys, "argv", arguments), mock.patch.dict(STARTUP.os.environ, environment), \
                     mock.patch.object(STARTUP, "run_arm", return_value=0) as arm, mock.patch.object(STARTUP.sys, "stderr"):
                    if invalid:
                        with self.assertRaises(SystemExit) as raised:
                            STARTUP.main()
                        self.assertEqual(raised.exception.code, 2)
                        arm.assert_not_called()
                    else:
                        self.assertEqual(STARTUP.main(), 0)


class LateNoisePollingTests(unittest.TestCase):
    def capture(self, timing, finish_after=3.0, control_error=False):
        clock = [10.0]
        sleeps, commands, controls = [], [], []
        completed = {"id": REQUEST, "state": "failed", "stopReason": "diagnostic_metadata_complete",
                     "acceptedFrames": 0, "artifacts": [{"state": "failed"}]}

        def sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds

        def command(arguments, **kwargs):
            started = clock[0]
            clock[0] += 0.03
            commands.append({"start": started, "end": clock[0], "arguments": arguments})
            session = completed if clock[0] >= acknowledged[0] + finish_after else {"state": "recording"}
            return {"exitCode": 0, "stdout": json.dumps({"id": arguments[-1], "version": 1,
                                                         "ok": True, "result": session})}

        def control(action, **values):
            controls.append({"start": clock[0], "enabled": values["enabled"]})
            clock[0] += 0.04
            if control_error and values["enabled"]:
                raise STARTUP.NATIVE.Failure("fixture control failed")

        acknowledged = []

        def start(operation, arguments):
            acknowledged.append(clock[0])
            return {"id": REQUEST, "state": "recording", "acceptedFrames": 0}

        with tempfile.TemporaryDirectory() as temporary, \
             mock.patch.dict(STARTUP.os.environ, {"SHAREX_FRAME_GAP_STARTUP_REQUEST_ID": REQUEST,
                                                  "SHAREX_FRAME_GAP_WORKLOAD": "1"}), \
             mock.patch.object(STARTUP.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(STARTUP.time, "sleep", side_effect=sleep):
            root = Path(temporary)
            evidence = STARTUP.StartupEvidence(root)
            run = STARTUP.StartupRun(SimpleNamespace(noise_timing=timing), evidence)
            run.binary = "ShareX"
            run.clients = [SimpleNamespace(call=start)]
            run.command = command
            run.control = control
            run.selection = lambda mode: {"mode": mode, "target": "fixture-token"}
            run.validate_manifest = mock.Mock()
            step = {}
            try:
                if control_error:
                    with self.assertRaisesRegex(STARTUP.NATIVE.Failure, "fixture control failed"):
                        run.metadata_capture(step)
                else:
                    run.metadata_capture(step)
                    self.assertEqual(step["session"], completed)
                    self.assertFalse(step["byteLimitE2EPassed"])
                self.assertIsNone(run.metadata_polling)
            finally:
                evidence.events.close()
            events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
        return acknowledged[0], commands, controls, sleeps, events

    def test_both_arms_start_polling_immediately_and_keep_native_response_delay(self):
        for timing in ("before", "late"):
            with self.subTest(timing=timing):
                ack, commands, controls, sleeps, events = self.capture(timing)
                self.assertEqual(commands[0]["start"], ack)
                self.assertTrue(sleeps)
                self.assertEqual(set(sleeps), {0.1})
                noise = [row for row in controls if row["enabled"]]
                self.assertEqual(len(noise), 1)
                boundaries = [row for row in events if row["event"] == "metadata_poll_boundary"]
                self.assertEqual(len(boundaries), len(commands))
                for previous, boundary in zip(commands, boundaries[1:]):
                    self.assertAlmostEqual(boundary["pollBoundaryUptime"] - previous["end"], 0.1)
                for boundary, launched in zip(boundaries, commands):
                    noise_delay = 0.04 if boundary["pollBoundaryUptime"] == noise[0]["start"] else 0
                    self.assertAlmostEqual(launched["start"] - boundary["pollBoundaryUptime"], noise_delay)
                if timing == "late":
                    eligible = next(row for row in boundaries if row["pollBoundaryUptime"] >= ack + 1)
                    self.assertEqual(noise[0]["start"], eligible["pollBoundaryUptime"])
                    self.assertAlmostEqual(noise[0]["start"] - ack, 1.04)
                    self.assertEqual(eligible["noiseDeadlineUptime"], ack + 1)
                else:
                    self.assertLess(noise[0]["start"], ack)

    def test_early_terminal_does_not_extend_capture_to_reach_noise(self):
        ack, commands, controls, sleeps, events = self.capture("late", finish_after=0.2)
        self.assertFalse(any(row["enabled"] for row in controls))
        self.assertLess(commands[-1]["end"], ack + 1)

    def test_noise_control_failure_propagates_without_another_status_or_retry(self):
        ack, commands, controls, sleeps, events = self.capture("late", control_error=True)
        self.assertEqual(len(controls), 1)
        self.assertLess(commands[-1]["end"], controls[0]["start"])

    def test_due_hook_does_not_trigger_for_another_session_or_operation(self):
        run = object.__new__(STARTUP.StartupRun)
        run.metadata_polling = {"sessionID": REQUEST, "noiseDeadlineUptime": 1}
        run.control = mock.Mock()
        with mock.patch.object(STARTUP.NATIVE.Run, "cli", return_value={}) as cli:
            run.cli("recording.status", {"sessionID": "another-session"})
            run.cli("recording.checkpoint", {"sessionID": REQUEST})
        self.assertEqual(cli.call_count, 2)
        run.control.assert_not_called()
        self.assertEqual(run.metadata_polling["noiseDeadlineUptime"], 1)


class ComparisonTests(unittest.TestCase):
    def test_abba_continues_after_failure_with_fresh_request_and_fixed_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ShareX.app"
            binary = app / "Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixed diagnostic build")
            setup = root / "setup.json"
            STARTUP.GAP.save(setup, {"status": "passed"})
            args = SimpleNamespace(out=root / "comparison", app=app, build_settings=root / "settings.json",
                                   setup_result=setup, commit="diagnostic-revision", comparison="sinks")
            calls = []

            def harness(arguments, log, environment, timeout):
                calls.append((arguments, environment, timeout))
                return {"exitCode": 1 if len(calls) == 1 else 0, "timedOut": False}

            def analysis(directory, arm, request_id, noise_timing=None, bitmap_content=None, draw_primitive=None):
                failed = len(calls) == 1
                return {"result": {"status": "failed" if failed else "diagnostic_complete",
                                   "byteLimitE2EPassed": arm == "control" and not failed}, "errors": []}

            with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                 mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true"}), \
                 mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), \
                 mock.patch.object(STARTUP, "analyze_arm", side_effect=analysis), mock.patch("builtins.print"):
                self.assertEqual(STARTUP.run_comparison(args), 1)
            self.assertEqual([env["SHAREX_FRAME_GAP_STARTUP_SINK"] for _, env, _ in calls], list(STARTUP.ORDER))
            self.assertEqual(len({env["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"] for _, env, _ in calls}), 4)
            for arguments, environment, timeout in calls:
                self.assertEqual(Path(arguments[1]).name, "frame-gap-startup.py")
                self.assertEqual(timeout, 480)
                self.assertEqual(environment["SHAREX_FRAME_GAP_HEARTBEAT"], "1")
                for key in ("SHAREX_FRAME_GAP_OWNED_BUFFERS", "SHAREX_FRAME_GAP_NV12", "SHAREX_FRAME_GAP_DEEPER_QUEUE"):
                    self.assertEqual(environment[key], "0")
            summary = STARTUP.GAP.read_json(args.out / "comparison.json")
            self.assertEqual(summary["incompleteArms"], 0)
            self.assertEqual(summary["failedControlGates"], 1)
            self.assertFalse(summary["productionE2EPassed"])

    def test_workflow_enables_capture_after_setup_and_excludes_maintenance(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/agent-capture.yml").read_text()
        startup = workflow.split("- name: Compare eight writer lifetime targets after the original native prefix", 1)[1].split("- name:", 1)[0]
        self.assertIn("steps.setup-ui.outcome == 'success'", startup)
        self.assertLess(startup.index("agentCaptureEnabled -bool true"), startup.index("python3 scripts/frame-gap-startup.py"))
        self.assertIn("--comparison writer-lifetime", startup)
        self.assertNotIn("--profile-preflight", startup)
        self.assertIn("timeout-minutes: 36", startup)
        native = workflow.split("  native:", 1)[-1]
        self.assertNotIn("python3 scripts/profiler-preflight.py", native)
        self.assertNotIn("scripts/profiler-clock-probe.py", native)
        dispatch = workflow.split("  workflow_dispatch:", 1)[1].split("permissions:", 1)[0]
        self.assertEqual(sum(line.startswith("      ") and not line.startswith("       ")
                             and line.endswith(":") for line in dispatch.splitlines()), 10)
        maintenance = workflow.split("- name: Validate manual recording, permission reset, and real uninstall", 1)[1].split("- name:", 1)[0]
        self.assertIn("!inputs.frame_gap_replay", maintenance)

    def check_noise_comparison(self, comparison, timings):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ShareX.app"
            binary = app / "Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixed diagnostic build")
            setup = root / "setup.json"
            STARTUP.GAP.save(setup, {"status": "passed"})
            args = SimpleNamespace(out=root / "comparison", app=app, build_settings=root / "settings.json",
                                   setup_result=setup, commit="diagnostic-revision", comparison=comparison)
            calls = []

            def harness(arguments, log, environment, timeout):
                with mock.patch.object(STARTUP.sys, "argv", [str(part) for part in arguments[1:]]), \
                     mock.patch.object(STARTUP, "run_arm", side_effect=lambda parsed: calls.append((parsed, environment)) or 0):
                    self.assertEqual(STARTUP.main(), 0)
                self.assertEqual(timeout, 480)
                return {"exitCode": 1 if len(calls) == 1 else 0, "timedOut": False}

            def analysis(directory, arm, request_id, noise_timing, bitmap_content=None, draw_primitive=None):
                self.assertEqual((arm, noise_timing), (calls[-1][0].arm, calls[-1][0].noise_timing))
                self.assertEqual(request_id, calls[-1][1]["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"])
                failed = len(calls) == 1
                return {"result": {"status": "failed" if failed else "diagnostic_complete", "byteLimitE2EPassed": False},
                        "errors": ["Missing target trace"] if failed else []}

            with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                 mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true"}), \
                 mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), \
                 mock.patch.object(STARTUP, "analyze_arm", side_effect=analysis), mock.patch("builtins.print"):
                self.assertEqual(STARTUP.run_comparison(args), 1)
            self.assertEqual([parsed.noise_timing for parsed, _ in calls], timings)
            self.assertEqual(len({env["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"] for _, env in calls}), 4)
            self.assertEqual(len({parsed.out for parsed, _ in calls}), 4)
            for parsed, environment in calls:
                self.assertEqual(parsed.arm, "metadata")
                self.assertEqual(parsed.comparison, comparison)
                self.assertEqual(parsed.app, app)
                self.assertEqual(parsed.build_settings, args.build_settings)
                self.assertIsNone(parsed.display_name)
                self.assertEqual(environment["SHAREX_FRAME_GAP_STARTUP_SINK"], "metadata")
                self.assertEqual(environment["SHAREX_FRAME_GAP_HEARTBEAT"], "1")
                self.assertEqual(environment["SHAREX_FRAME_GAP_FIXTURE_TRACE"], "1")
                for key in ("SHAREX_FRAME_GAP_OWNED_BUFFERS", "SHAREX_FRAME_GAP_NV12", "SHAREX_FRAME_GAP_DEEPER_QUEUE"):
                    self.assertEqual(environment[key], "0")
            summary = STARTUP.GAP.read_json(args.out / "comparison.json")
            self.assertEqual(summary["order"], timings)
            self.assertEqual(summary["incompleteArms"], 1)
            self.assertEqual(summary["status"], "diagnostic_incomplete")
            self.assertEqual(summary["runs"][0]["result"]["status"], "failed")
            self.assertFalse(summary["productionE2EPassed"])
            if comparison == "late-noise":
                self.assertEqual(summary["lateNoiseQualification"]["minimumCompleteCallbacks"], 8)
                self.assertEqual(summary["lateNoiseQualification"]["maximumCompleteSourceIntervalSeconds"], 0.2)
                self.assertIn("polling immediately", summary["acknowledgementCaveat"])
            else:
                self.assertIn("noise control response", summary["acknowledgementCaveat"])

    def test_noise_comparison_passes_all_four_actual_arguments_and_retains_a_failed_arm(self):
        self.check_noise_comparison("noise-timing", ["before", "after", "after", "before"])

    def test_late_noise_comparison_passes_all_four_actual_arguments_and_retains_a_failed_arm(self):
        self.check_noise_comparison("late-noise", ["before", "late", "late", "before"])


class AnalysisTests(unittest.TestCase):
    def evidence(self, directory, arm="metadata", failed_control=False):
        native = directory / "native"
        fixture = native / "fixture"
        fixture.mkdir(parents=True)
        traces = directory / "traces"
        traces.mkdir()
        save = STARTUP.GAP.save
        save(native / "result.json", {"status": "failed" if failed_control else "diagnostic_complete",
                                      "byteLimitE2EPassed": arm == "control" and not failed_control})
        save(fixture / "draw-trace.json", [{"entryUptime": 9.8, "exitUptime": 9.801, "noisy": True},
                                          {"entryUptime": 10.2, "exitUptime": 10.201, "noisy": True}])
        save(fixture / "operation-trace.json", [{"name": "state_write"}])
        for name in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
            (fixture / name).write_text("0")
        events = [{"event": "startup_prefix_validated"},
                  {"event": "command_started", "log": "decode.json", "command": ["/tmp/verify-agent-media"]},
                  {"event": "command_finished", "log": "decode.json", "monotonicSeconds": 9.7},
                  {"event": "command_started", "monotonicSeconds": 10.02,
                   "command": ["ShareX", "--agent", "recording", "status", "--session", REQUEST]}]
        if arm == "control":
            events.append({"event": "media_decoded", "sessionID": REQUEST,
                           "verification": {"status": "failed" if failed_control else "passed"}})
        (native / "events.jsonl").write_text("\n".join(json.dumps(row) for row in events))
        trace = {"overflow": 0, "operationOverflow": 0, "operations": [], "streamErrors": [],
                 "heartbeats": [10.1, 10.3], "limits": [],
                 "history": {"overflow": 0, "events": [{"name": "writer.init"}] * (7 if arm == "metadata" else 8)},
                 "context": {"startupSink": {"requestID": REQUEST, "arm": arm, "priorWriters": 7, "completedWriters": 7},
                             "machTimebaseNumerator": 1, "machTimebaseDenominator": 1},
                 "callbacks": [{"screen": True, "valid": True, "image": True, "status": 0, "pts": pts,
                                "displayTime": int(pts * 1e9), "entryUptime": pts + 0.001, "exitUptime": pts + 0.002}
                               for pts in (10.0, 10.6, 10.666)]}
        if arm == "control":
            trace["writerID"] = "writer-eight"
            for callback in trace["callbacks"]:
                callback["appended"] = True
        save(traces / "target-trace.json", trace)
        for index in range(7):
            save(traces / f"prior-{index}-trace.json", {**trace, "context": {}})
        return trace

    def test_metadata_long_source_gap_is_retained_as_diagnostic_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.evidence(root)
            result = STARTUP.analyze_arm(root, "metadata", REQUEST)
            self.assertEqual(result["errors"], [])
            self.assertAlmostEqual(result["firstPTSInterval"]["seconds"], 0.6)
            self.assertAlmostEqual(result["firstDisplayTimeInterval"]["seconds"], 0.6)
            self.assertAlmostEqual(result["verifierExitToFirstPTSSeconds"], 0.3)
            self.assertAlmostEqual(result["firstNoisyDrawToFirstPTSSeconds"], 0.2)
            self.assertEqual(result["firstIntervalContext"]["drawsCompleted"], 1)
            self.assertEqual(len(result["statusLaunches"]), 1)
            self.assertFalse(result["result"]["byteLimitE2EPassed"])

    def test_rejects_writer_construction_in_metadata_arm(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = self.evidence(root)
            trace["history"]["events"].append({"name": "writer.init"})
            trace["callbacks"][0]["appended"] = True
            STARTUP.GAP.save(root / "traces/target-trace.json", trace)
            errors = STARTUP.analyze_arm(root, "metadata", REQUEST)["errors"]
            self.assertTrue(any("construction count" in error for error in errors))
            self.assertTrue(any("retention, or copy" in error for error in errors))

    def test_retains_control_decode_failure_without_fabricating_missing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.evidence(root, "control", failed_control=True)
            result = STARTUP.analyze_arm(root, "control", REQUEST)
            self.assertEqual(result["errors"], [])
            self.assertEqual(result["result"]["status"], "failed")
            self.assertFalse(result["result"]["byteLimitE2EPassed"])

    def test_rejects_trace_overflow_stream_failure_and_missing_display_time(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = self.evidence(root)
            trace.update(overflow=1, streamErrors=["stopped"])
            del trace["callbacks"][0]["displayTime"]
            STARTUP.GAP.save(root / "traces/target-trace.json", trace)
            errors = STARTUP.analyze_arm(root, "metadata", REQUEST)["errors"]
            self.assertTrue(any("overflow" in error for error in errors))
            self.assertTrue(any("stream" in error for error in errors))
            self.assertTrue(any("displayTime" in error for error in errors))

    def timing_evidence(self, root, timing):
        trace = self.evidence(root)
        save = STARTUP.GAP.save
        result_path = root / "native/result.json"
        save(result_path, {**STARTUP.GAP.read_json(result_path), "noiseTiming": timing})
        noise, requested, controlled = (9.8, 9.79, 9.85) if timing == "before" else (10.05, 10.004, 10.08)
        save(root / "native/fixture/draw-trace.json", [
            {"entryUptime": value, "exitUptime": value + 0.001, "noisy": value >= noise}
            for value in (9.7, noise, 10.2, 10.9, 11.2)])
        save(root / "native/fixture/operation-trace.json", [
            {"name": "stateWrite", "phase": "begin", "uptime": noise + 0.1},
            {"name": "stateWrite", "phase": "end", "uptime": noise + 0.7}])
        events_path = root / "native/events.jsonl"
        events = [json.loads(line) for line in events_path.read_text().splitlines()]
        events[-1]["monotonicSeconds"] = max(10.003, controlled) + 0.001
        events.extend([
            {"event": "agent_operation_request", "operation": "recording.start", "requestID": REQUEST, "monotonicSeconds": 9.9},
            {"event": "metadata_start_acknowledged", "requestID": REQUEST, "noiseTiming": timing, "monotonicSeconds": 10.003},
            {"event": "fixture_command_requested", "action": "noise", "values": {"enabled": True}, "monotonicSeconds": requested},
            {"event": "fixture_command", "action": "noise", "values": {"enabled": True}, "monotonicSeconds": controlled}])
        events_path.write_text("\n".join(json.dumps(row) for row in events))
        trace["callbacks"].extend([{**trace["callbacks"][0], "pts": value, "displayTime": int(value * 1e9),
                                   "entryUptime": value + 0.001, "exitUptime": value + 0.002} for value in (11.2, 12.9)])
        save(root / "traces/target-trace.json", trace)
        return trace, events

    def bitmap_evidence(self, root, content):
        trace, events = self.timing_evidence(root, "before")
        result_path = root / "native/result.json"
        STARTUP.GAP.save(result_path, {**STARTUP.GAP.read_json(result_path), "bitmapContent": content,
                                       "drawPrimitive": STARTUP.BITMAP_CONDITIONS[content][1]})
        draws_path = root / "native/fixture/draw-trace.json"
        draws = STARTUP.GAP.read_json(draws_path)
        for tick, row in enumerate(draws):
            row["tick"] = tick
            if row["noisy"]:
                seed = tick + 1
                nonzero = 0
                mask, primitive = STARTUP.BITMAP_CONDITIONS[content]
                for _ in range(640 * 56):
                    seed = (seed * 6364136223846793005 + 1442695040888963407) % (2 ** 64)
                    nonzero += sum(((seed >> shift) & mask) != 0 for shift in (24, 32, 40))
                row["bitmap"] = {"entryUptime": row["entryUptime"] + 0.0001,
                                 "exitUptime": row["exitUptime"] - 0.0001,
                                 "componentMask": mask, "width": 640, "height": 56,
                                 "bitsPerComponent": 8, "bitsPerPixel": 32, "bytesPerRow": 2560,
                                 "byteCount": 143360, "bitmapInfo": 5, "colorSpaceModel": 1,
                                 "shouldInterpolate": False, "destination": [0, 422.4, 640, 57.6],
                                 "rgbNonzeroCount": nonzero, "finalSeed": seed,
                                 "drawPrimitive": primitive, "cgImageConstructed": True}
        STARTUP.GAP.save(draws_path, draws)
        (root / "native/agent-capture-fixture").write_bytes(b"identical fixture binary")
        return trace, events, draws

    def test_bitmap_content_keeps_actual_draw_proof_and_source_gap_without_production_success(self):
        for content in STARTUP.BITMAP_CONDITIONS:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trace, _, draws = self.bitmap_evidence(root, content)
                sample = trace["callbacks"][0]
                trace["callbacks"].extend({**sample, "status": 1, "pts": value,
                                           "entryUptime": value + 0.001, "exitUptime": value + 0.002,
                                           "displayTime": int(value * 1e9)} for value in (10.3, 10.9))
                trace["callbacks"].sort(key=lambda row: row["pts"])
                STARTUP.GAP.save(root / "traces/target-trace.json", trace)
                result = STARTUP.analyze_arm(root, "metadata", REQUEST, "before", content)
                self.assertEqual(result["errors"], [])
                self.assertEqual(result["firstBitmapDraw"], draws[1])
                self.assertEqual(result["bitmapDrawCount"], 4)
                self.assertEqual(result["firstBitmapDraw"]["bitmap"]["rgbNonzeroCount"] == 0,
                                 STARTUP.BITMAP_CONDITIONS[content][0] == 0)
                window = result["postNoiseFirstSecond"]
                self.assertAlmostEqual(window["maximumPTSInterval"]["seconds"], 0.6)
                self.assertAlmostEqual(window["maximumAllSourcePTSInterval"]["seconds"], 0.3)
                self.assertAlmostEqual(result["maximumTargetFixtureOperationSpan"]["seconds"], 0.6)
                self.assertEqual(len(result["allSourcePTSIntervals"]), len(trace["callbacks"]) - 1)
                self.assertFalse(result["result"]["byteLimitE2EPassed"])
                if content == "original":
                    draws[1]["bitmap"]["rgbNonzeroCount"] -= 1
                    STARTUP.GAP.save(root / "native/fixture/draw-trace.json", draws)
                    errors = STARTUP.analyze_arm(root, "metadata", REQUEST, "before", content)["errors"]
                    self.assertTrue(any("RGB byte count" in error for error in errors))

    def test_bitmap_content_rejects_missing_wrong_or_unsubmitted_draw_evidence(self):
        cases = {
            "missing draw": ("successful bitmap draw", lambda draws: draws[1].pop("bitmap")),
            "prefix image": ("non-noisy prefix", lambda draws: draws[0].update(bitmap=draws[1]["bitmap"])),
            "wrong mask": ("layout", lambda draws: draws[1]["bitmap"].update(componentMask=255)),
            "wrong byte count": ("layout", lambda draws: draws[1]["bitmap"].update(byteCount=143359)),
            "wrong image height": ("layout", lambda draws: draws[1]["bitmap"].update(height=57)),
            "wrong stride": ("layout", lambda draws: draws[1]["bitmap"].update(bytesPerRow=640)),
            "wrong format": ("layout", lambda draws: draws[1]["bitmap"].update(bitmapInfo=1)),
            "wrong color model": ("layout", lambda draws: draws[1]["bitmap"].update(colorSpaceModel=0)),
            "wrong scaling": ("rectangle", lambda draws: draws[1]["bitmap"].update(destination=[0, 422.4, 640, 56])),
            "outside draw": ("timing", lambda draws: draws[1]["bitmap"].update(exitUptime=10)),
            "nonconstant bytes": ("RGB byte", lambda draws: draws[1]["bitmap"].update(rgbNonzeroCount=1)),
            "wrong loop seed": ("complete LCG", lambda draws: draws[1]["bitmap"].update(finalSeed=1)),
            "missing tick": ("source tick", lambda draws: draws[1].pop("tick")),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, _, original = self.bitmap_evidence(root, "constant")
            for name, (expected, mutate) in cases.items():
                with self.subTest(case=name):
                    draws = json.loads(json.dumps(original))
                    mutate(draws)
                    STARTUP.GAP.save(root / "native/fixture/draw-trace.json", draws)
                    result = STARTUP.analyze_arm(root, "metadata", REQUEST, "before", "constant")
                    self.assertTrue(any(expected in error for error in result["errors"]), result["errors"])
                    self.assertFalse(result["result"]["byteLimitE2EPassed"])
            STARTUP.GAP.save(root / "native/fixture/draw-trace.json", original)
            errors = STARTUP.analyze_arm(root, "metadata", REQUEST, "before", "original")["errors"]
            self.assertTrue(any("requested bitmap content" in error for error in errors))
            (root / "native/fixture/draw-trace-overflow.txt").write_text("1")
            errors = STARTUP.analyze_arm(root, "metadata", REQUEST, "before", "constant")["errors"]
            self.assertTrue(any("overflow" in error for error in errors))

    def test_bitmap_comparison_runs_fixed_abba_and_rejects_changed_or_missing_fixture_binaries(self):
        for binary_failure in (None, "changed", "missing"):
            with self.subTest(binary=binary_failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "ShareX.app"
                binary = app / "Contents/MacOS/ShareX"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"fixed diagnostic app")
                setup = root / "setup.json"
                STARTUP.GAP.save(setup, {"status": "passed"})
                args = SimpleNamespace(out=root / "comparison", app=app, build_settings=root / "settings.json",
                                       setup_result=setup, commit="diagnostic-revision", comparison="bitmap-content")
                calls = []

                def harness(arguments, log, environment, timeout):
                    with mock.patch.object(STARTUP.sys, "argv", [str(part) for part in arguments[1:]]), \
                         mock.patch.dict(STARTUP.os.environ, environment), \
                         mock.patch.object(STARTUP, "run_arm", side_effect=lambda parsed: calls.append((parsed, environment)) or 0):
                        self.assertEqual(STARTUP.main(), 0)
                    parsed = calls[-1][0]
                    directory = log.parent
                    (directory / "traces").rmdir()
                    self.bitmap_evidence(directory, parsed.bitmap_content)
                    fixture = directory / "native/agent-capture-fixture"
                    if len(calls) == 2 and binary_failure:
                        if binary_failure == "missing":
                            fixture.unlink()
                        else:
                            fixture.write_bytes(b"different fixture binary")
                    for path in directory.rglob("*"):
                        if path.suffix in (".json", ".jsonl"):
                            path.write_text(path.read_text().replace(REQUEST, environment["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"]))
                    return {"exitCode": 0, "timedOut": False}

                with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                     mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true", "SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK": "17"}), \
                     mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), mock.patch("builtins.print"):
                    self.assertEqual(STARTUP.run_comparison(args), int(binary_failure is not None))
                result = STARTUP.GAP.read_json(args.out / "comparison.json")
                self.assertEqual(result["order"], ["original", "constant", "constant", "original"])
                self.assertEqual([parsed.bitmap_content for parsed, _ in calls], result["order"])
                self.assertEqual([env["SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK"] for _, env in calls], ["255", "0", "0", "255"])
                self.assertTrue(all(parsed.noise_timing == "before" and parsed.arm == "metadata" for parsed, _ in calls))
                self.assertEqual(len({env["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"] for _, env in calls}), 4)
                self.assertEqual(result["incompleteArms"], int(binary_failure is not None))
                self.assertEqual(result["status"], "diagnostic_incomplete" if binary_failure else "diagnostic_complete")
                self.assertTrue(all(run["firstBitmapDraw"] for run in result["runs"]))
                self.assertFalse(result["productionE2EPassed"])
                self.assertEqual(result["fixtureBinarySHA256"], STARTUP.WORKLOAD.digest(args.out / "arm-01-original/native/agent-capture-fixture"))

    def test_draw_path_proof_rejects_image_fallback_and_missing_construction(self):
        for content, (_, primitive) in STARTUP.BITMAP_CONDITIONS.items():
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, _, original = self.bitmap_evidence(root, content)
                self.assertEqual(STARTUP.analyze_arm(root, "metadata", REQUEST, "before", content, primitive)["errors"], [])
                for mutation in (lambda proof: proof.pop("drawPrimitive"),
                                 lambda proof: proof.update(drawPrimitive="cgimage" if primitive != "cgimage" else "black-rectangle"),
                                 lambda proof: proof.pop("cgImageConstructed"),
                                 lambda proof: proof.update(cgImageConstructed=False)):
                    draws = json.loads(json.dumps(original))
                    mutation(draws[-1]["bitmap"])
                    STARTUP.GAP.save(root / "native/fixture/draw-trace.json", draws)
                    result = STARTUP.analyze_arm(root, "metadata", REQUEST, "before", content, primitive)
                    self.assertTrue(any("layout" in error for error in result["errors"]), result["errors"])

    def test_six_draw_path_arms_finish_before_pixel_check_and_pixel_failure_keeps_all_traces(self):
        for pixel_status in ("passed", "failed"):
            with self.subTest(pixels=pixel_status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                binary = root / "ShareX.app/Contents/MacOS/ShareX"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"fixed app")
                setup = root / "setup.json"
                STARTUP.GAP.save(setup, {"status": "passed"})
                args = SimpleNamespace(out=root / "comparison", app=root / "ShareX.app", build_settings=root / "settings",
                                       setup_result=setup, commit="diagnostic", comparison="bitmap-draw-path")
                calls = []

                def harness(arguments, log, environment, timeout):
                    with mock.patch.object(STARTUP.sys, "argv", [str(part) for part in arguments[1:]]), \
                         mock.patch.dict(STARTUP.os.environ, environment), \
                         mock.patch.object(STARTUP, "run_arm", side_effect=lambda parsed: calls.append((parsed, environment)) or 0):
                        self.assertEqual(STARTUP.main(), 0)
                    self.assertEqual(timeout, 240)
                    directory = log.parent
                    (directory / "traces").rmdir()
                    self.bitmap_evidence(directory, calls[-1][0].bitmap_content)
                    for path in directory.rglob("*"):
                        if path.suffix in (".json", ".jsonl"):
                            path.write_text(path.read_text().replace(REQUEST, environment["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"]))
                    return {"exitCode": 0, "timedOut": False}

                def pixels(*values):
                    self.assertEqual(len(calls), 6)
                    self.assertEqual(len(STARTUP.GAP.read_json(args.out / "comparison.json")["runs"]), 6)
                    return {"status": pixel_status}

                with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                     mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true"}), \
                     mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), \
                     mock.patch.object(STARTUP, "compare_black_pixels", side_effect=pixels), mock.patch("builtins.print"):
                    self.assertEqual(STARTUP.run_comparison(args), int(pixel_status != "passed"))
                summary = STARTUP.GAP.read_json(args.out / "comparison.json")
                self.assertEqual(summary["order"], ["original", "constant", "rectangle", "rectangle", "constant", "original"])
                self.assertEqual([call.bitmap_content for call, _ in calls], summary["order"])
                self.assertEqual([env["SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK"] for _, env in calls], ["255", "0", "0", "0", "0", "255"])
                self.assertEqual([env["SHAREX_FRAME_GAP_BITMAP_DRAW_PRIMITIVE"] for _, env in calls],
                                 ["cgimage", "cgimage", "black-rectangle", "black-rectangle", "cgimage", "cgimage"])
                self.assertTrue(all(call.arm == "metadata" and call.noise_timing == "before" for call, _ in calls))
                self.assertEqual(len({env["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"] for _, env in calls}), 6)
                self.assertFalse(summary["profilerPresent"])
                self.assertFalse(summary["productionE2EPassed"])
                self.assertEqual(summary["incompleteArms"], 0)
                self.assertEqual(summary["status"], "diagnostic_complete" if pixel_status == "passed" else "diagnostic_incomplete")
                self.assertTrue(all(Path(row["trace"]).is_file() and row["bitmapDrawCount"] == 4 for row in summary["runs"]))

    def test_after_arm_accepts_noise_after_first_pts_and_keeps_crossing_gaps_and_fixture_stalls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.timing_evidence(root, "after")
            result = STARTUP.analyze_arm(root, "metadata", REQUEST, "after")
            self.assertEqual(result["errors"], [])
            self.assertEqual(result["firstNoiseUptime"], 10.05)
            self.assertEqual(result["firstCapturePTS"], 10.0)
            self.assertAlmostEqual(result["firstNoisyDrawToFirstPTSSeconds"], -0.05)
            window = result["postNoiseFirstSecond"]
            self.assertEqual(window["maximumPTSInterval"]["start"], 10.0)
            self.assertAlmostEqual(window["maximumPTSInterval"]["seconds"], 0.6)
            self.assertAlmostEqual(window["maximumDisplayTimeInterval"]["seconds"], 0.6)
            self.assertAlmostEqual(window["maximumCallbackEntryInterval"]["seconds"], 0.6)
            self.assertGreater(window["ptsIntervals"][-1]["end"], window["end"])
            self.assertAlmostEqual(window["maximumFixtureOperationSpan"]["seconds"], 0.6)
            self.assertAlmostEqual(result["maximumTargetFixtureOperationSpan"]["seconds"], 0.6)
            self.assertAlmostEqual(result["acknowledgementToFirstStatusLaunchSeconds"], 0.078)
            self.assertAlmostEqual(result["noiseControlToFirstStatusLaunchSeconds"], 0.001)
            self.assertFalse(result["result"]["byteLimitE2EPassed"])

    def test_before_arm_preserves_noise_before_mcp_and_reports_the_cli_launch_difference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.timing_evidence(root, "before")
            result = STARTUP.analyze_arm(root, "metadata", REQUEST, "before")
            self.assertEqual(result["errors"], [])
            self.assertAlmostEqual(result["firstNoisyDrawToFirstPTSSeconds"], 0.2)
            self.assertAlmostEqual(result["acknowledgementToFirstStatusLaunchSeconds"], 0.001)

    def test_after_arm_rejects_wrong_noise_order_missing_timing_and_short_observation(self):
        mutations = {
            "started before": lambda trace, events: events[-2].update(monotonicSeconds=9.9),
            "first-use command": lambda trace, events: events.append(events[-2]),
            "first second": lambda trace, events: trace.update(callbacks=trace["callbacks"][:3]),
            "first target status": lambda trace, events: events[3].update(monotonicSeconds=10.001),
            "first noise control": lambda trace, events: events[-1].update(monotonicSeconds=10.04),
        }
        for expected, mutate in mutations.items():
            with self.subTest(mutation=expected), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trace, events = self.timing_evidence(root, "after")
                mutate(trace, events)
                STARTUP.GAP.save(root / "traces/target-trace.json", trace)
                (root / "native/events.jsonl").write_text("\n".join(json.dumps(row) for row in events))
                errors = STARTUP.analyze_arm(root, "metadata", REQUEST, "after")["errors"]
                self.assertTrue(any(expected in error for error in errors), errors)

    def late_evidence(self, root):
        trace, events = self.timing_evidence(root, "late")
        noise = 11.08
        STARTUP.GAP.save(root / "native/fixture/draw-trace.json", [
            {"entryUptime": value, "exitUptime": value + 0.001, "noisy": value >= noise}
            for value in (9.7, 10.1, 10.5, 11.0, noise, 11.2, 11.9, 12.2)])
        STARTUP.GAP.save(root / "native/fixture/operation-trace.json", [
            {"name": "stateWrite", "phase": "begin", "uptime": noise},
            {"name": "stateWrite", "phase": "end", "uptime": noise + 0.01}])
        events[3]["monotonicSeconds"] = 10.004
        events[-2]["monotonicSeconds"] = 11.044
        events[-1]["monotonicSeconds"] = 11.1
        events += [{"event": "metadata_poll_boundary", "requestID": REQUEST,
                    "pollBoundaryUptime": value, "noiseDeadlineUptime": 11.003 if value <= 11.043 else None}
                   for value in (10.003, 10.133, 10.263, 10.393, 10.523, 10.653, 10.783, 10.913, 11.043, 11.23)]
        sample = trace["callbacks"][0]
        trace["callbacks"] = [
            {**sample, "pts": value, "displayTime": int(value * 1e9), "entryUptime": value + 0.001,
             "exitUptime": value + 0.002, "status": status}
            for value, status in sorted([(10 + index / 8, 0) for index in range(9)] +
                                        [(10.0625 + index / 8, 1) for index in range(8)] +
                                        [(11.3, 1), (11.65, 0), (11.8, 0), (12.1, 0), (12.9, 0)])]
        STARTUP.GAP.save(root / "traces/target-trace.json", trace)
        (root / "native/events.jsonl").write_text("\n".join(json.dumps(row) for row in events))
        return trace, events

    def test_late_noise_qualifies_observed_cadence_and_keeps_full_crossing_interval(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.late_evidence(root)
            result = STARTUP.analyze_arm(root, "metadata", REQUEST, "late")
            self.assertEqual(result["errors"], [])
            self.assertAlmostEqual(result["noiseDeadlineUptime"], 11.003)
            self.assertAlmostEqual(result["noiseTriggerPollBoundaryUptime"], 11.043)
            self.assertAlmostEqual(result["deadlineToNoiseCommandSeconds"], 0.041)
            pre = result["preNoiseCapture"]
            self.assertTrue(pre["qualified"])
            self.assertEqual(pre["end"], 11.08)
            self.assertEqual(pre["completeCallbacks"], 9)
            self.assertEqual(pre["allSourceCallbacks"], 17)
            self.assertEqual(pre["completeSourceSpanSeconds"], 1)
            self.assertEqual(pre["maximumCompleteSourcePTSInterval"]["seconds"], 0.125)
            self.assertEqual(pre["maximumAllSourcePTSInterval"]["seconds"], 0.0625)
            self.assertAlmostEqual(pre["lastCompletePTSAgeSeconds"], 0.08)
            self.assertAlmostEqual(pre["lastCompleteCallbackExitAgeSeconds"], 0.078)
            self.assertEqual(pre["callbackStatusCounts"], {"0": 9, "1": 8})
            crossing = result["completeSourceIntervalsCrossingNoise"]
            self.assertEqual(len(crossing), 1)
            self.assertAlmostEqual(crossing[0]["seconds"], 0.65)
            self.assertAlmostEqual(result["allSourceIntervalsCrossingNoise"][0]["seconds"], 0.3)
            first = result["firstLongCompleteSourceInterval"]
            self.assertEqual(first["position"], "crossing")
            self.assertAlmostEqual(first["startRelativeToNoiseSeconds"], -0.08)
            self.assertAlmostEqual(first["endRelativeToNoiseSeconds"], 0.57)
            self.assertEqual(result["firstLongAllSourceInterval"]["position"], "after")
            self.assertFalse(result["result"]["byteLimitE2EPassed"])

    def test_late_noise_missing_cadence_timing_or_coverage_is_incomplete_with_raw_data_retained(self):
        def fewer_complete(trace, events):
            trace["callbacks"] = [row for row in trace["callbacks"] if row["pts"] not in (10.875, 11.0)]

        def short_span(trace, events):
            pre = [row for row in trace["callbacks"] if row["status"] == 0 and row["pts"] <= 11]
            for index, row in enumerate(pre):
                value = 10 + index * 0.09
                row.update(pts=value, displayTime=int(value * 1e9), entryUptime=value + 0.001, exitUptime=value + 0.002)
            trace["callbacks"].sort(key=lambda row: row["entryUptime"])

        def long_interval(trace, events):
            for row in trace["callbacks"]:
                if row["pts"] == 10.5:
                    row["status"] = 1

        mutations = {
            "fewer callbacks": ("pre-noise", fewer_complete),
            "short span": ("pre-noise", short_span),
            "long complete interval": ("pre-noise", long_interval),
            "stale last complete": ("pre-noise", lambda trace, events: trace.update(
                callbacks=[row for row in trace["callbacks"] if row["pts"] != 11])),
            "short observation": ("first second", lambda trace, events: trace.update(
                callbacks=[row for row in trace["callbacks"] if row["pts"] < 12.08])),
            "no command": ("first-use command", lambda trace, events: events.remove(events[6])),
            "duplicate command": ("first-use command", lambda trace, events: events.append(events[6])),
            "delayed trigger": ("fixed deadline", lambda trace, events: events[8].update(pollBoundaryUptime=11.004)),
            "early trigger": ("fixed deadline", lambda trace, events: events[6].update(monotonicSeconds=11.0)),
            "delayed polling": ("before its deadline", lambda trace, events: events[3].update(monotonicSeconds=11.101)),
        }
        for name, (expected, mutate) in mutations.items():
            with self.subTest(mutation=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trace, events = self.late_evidence(root)
                mutate(trace, events)
                STARTUP.GAP.save(root / "traces/target-trace.json", trace)
                (root / "native/events.jsonl").write_text("\n".join(json.dumps(row) for row in events))
                result = STARTUP.analyze_arm(root, "metadata", REQUEST, "late")
                self.assertTrue(any(expected in error for error in result["errors"]), result["errors"])
                self.assertEqual(STARTUP.GAP.read_json(root / "traces/target-trace.json"), trace)
                self.assertFalse(result["result"]["byteLimitE2EPassed"])

    def test_late_qualification_uses_actual_draw_and_includes_complete_frames_after_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace, events = self.late_evidence(root)
            sample = trace["callbacks"][0]
            trace["callbacks"] = [row for row in trace["callbacks"] if row["pts"] > 11.08]
            trace["callbacks"][:0] = [
                {**sample, "pts": value, "displayTime": int(value * 1e9),
                 "entryUptime": value + 0.001, "exitUptime": value + 0.002}
                for value in (10, 10.15, 10.3, 10.45, 10.6, 10.75, 10.9, 11.06)]
            STARTUP.GAP.save(root / "traces/target-trace.json", trace)
            result = STARTUP.analyze_arm(root, "metadata", REQUEST, "late")
            self.assertEqual(result["errors"], [])
            self.assertTrue(result["preNoiseCapture"]["qualified"])
            self.assertEqual(result["preNoiseCapture"]["completeCallbacks"], 8)
            self.assertLess(result["noiseCommandRequestedUptime"], 11.06)
            self.assertAlmostEqual(result["preNoiseCapture"]["lastCompletePTSAgeSeconds"], 0.02)

    def test_comparison_returns_incomplete_for_actual_failed_cadence_and_keeps_all_four_arms(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ShareX.app"
            binary = app / "Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixed diagnostic build")
            setup = root / "setup.json"
            STARTUP.GAP.save(setup, {"status": "passed"})
            args = SimpleNamespace(out=root / "comparison", app=app, build_settings=root / "settings.json",
                                   setup_result=setup, commit="diagnostic-revision", comparison="late-noise")
            calls = []

            def harness(arguments, log, environment, timeout):
                directory = log.parent
                (directory / "traces").rmdir()
                timing = arguments[arguments.index("--noise-timing") + 1]
                calls.append(timing)
                trace, _ = self.late_evidence(directory) if timing == "late" else self.timing_evidence(directory, "before")
                if len(calls) == 2:
                    trace["callbacks"] = [row for row in trace["callbacks"] if row["pts"] != 11]
                    STARTUP.GAP.save(directory / "traces/target-trace.json", trace)
                for path in directory.rglob("*"):
                    if path.suffix in (".json", ".jsonl"):
                        path.write_text(path.read_text().replace(REQUEST, environment["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"]))
                return {"exitCode": 0, "timedOut": False}

            with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                 mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true"}), \
                 mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), mock.patch("builtins.print"):
                self.assertEqual(STARTUP.run_comparison(args), 1)
            result = STARTUP.GAP.read_json(args.out / "comparison.json")
            self.assertEqual(calls, ["before", "late", "late", "before"])
            self.assertEqual(result["status"], "diagnostic_incomplete")
            self.assertEqual(result["incompleteArms"], 1)
            self.assertFalse(result["productionE2EPassed"])
            self.assertTrue(any("pre-noise" in error for error in result["runs"][1]["errors"]))
            self.assertFalse(result["runs"][1]["preNoiseCapture"]["qualified"])
            self.assertTrue(result["runs"][2]["preNoiseCapture"]["qualified"])
            self.assertTrue(all(Path(row["trace"]).exists() for row in result["runs"]))


class PixelCheckTests(unittest.TestCase):
    def test_pixel_comparison_rejects_edge_mismatch_or_changed_png_hash(self):
        for outcome in ("equal", "edge_mismatch", "changed_hash"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                args = SimpleNamespace(out=root, app=root / "app", build_settings=root / "settings")
                captures = []

                def harness(arguments, log, environment, timeout):
                    content = arguments[arguments.index("--bitmap-content") + 1]
                    output = Path(arguments[arguments.index("--out") + 1])
                    output.mkdir()
                    captures.append(content)
                    self.assertEqual(timeout, 90)
                    self.assertEqual(environment["SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK"], "0")
                    for key in ("SHAREX_FRAME_GAP_TRACE_DIR", "SHAREX_FRAME_GAP_STARTUP_SINK", "SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"):
                        self.assertNotIn(key, environment)
                    STARTUP.GAP.save(output / "pixel-check.json", {"status": "passed", "png": str(output / "capture.png"),
                        "expectation": str(output / "expected.json"), "sha256": content,
                        "installedBinarySHA256": "app", "fixtureBinarySHA256": "fixture"})
                    return {"exitCode": 0, "timedOut": False}

                comparison = {"status": "failed" if outcome == "edge_mismatch" else "passed",
                              "mismatchedPixels": int(outcome == "edge_mismatch"),
                              "referenceSHA256": "constant", "sha256": "changed" if outcome == "changed_hash" else "rectangle"}
                with mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), \
                     mock.patch.object(STARTUP.subprocess, "run", return_value=SimpleNamespace(
                         returncode=int(outcome == "edge_mismatch"), stdout=json.dumps(comparison), stderr="")), \
                     mock.patch.dict(STARTUP.os.environ, {"SHAREX_FRAME_GAP_TRACE_DIR": "must-remove",
                         "SHAREX_FRAME_GAP_STARTUP_SINK": "metadata", "SHAREX_FRAME_GAP_STARTUP_REQUEST_ID": "target"}):
                    result = STARTUP.compare_black_pixels(args, "app", "fixture")
                self.assertEqual(captures, ["constant", "rectangle"])
                self.assertEqual(result["status"], "passed" if outcome == "equal" else "failed")
                self.assertEqual(STARTUP.GAP.read_json(root / "pixel-equivalence/result.json"), result)

    def test_readiness_allows_proven_static_redraws_and_enforces_pixels_and_deadline(self):
        mutations = {
            "mode_changed": lambda before, after, draws: after.update(mode="animated"),
            "pid_changed": lambda before, after, draws: after.update(pid=after["pid"] + 1),
            "window_changed": lambda before, after, draws: after.update(windowID=after["windowID"] + 1),
            "tick_changed": lambda before, after, draws: after.update(tick=16),
            "stage_changed": lambda before, after, draws: after.update(stage=1),
            "draw_count_decreased": lambda before, after, draws: after.update(draws=15),
            "missing_draw": lambda before, after, draws: draws.pop(0),
            "missing_bitmap": lambda before, after, draws: draws[-1].pop("bitmap"),
            "trace_stage_changed": lambda before, after, draws: draws[-1].update(stage=1),
            "trace_tick_changed": lambda before, after, draws: (before.update(tick=14), after.update(tick=14)),
            "trace_clock_mismatch": lambda before, after, draws: after.update(uptime=before["uptime"]),
        }
        cases = [("ready", "passed"), ("never_ready", "failed"), ("decoder_error", "failed"),
                 ("deadline_ready", "passed"), ("late_ready", "failed"), ("already_drawn", "passed")]
        cases.extend((name, "failed") for name in mutations)
        for outcome, expected_status in cases:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                native = json.loads((Path(__file__).parent / "fixtures/static-pixel-redraw.json").read_text())
                before, after, draws = native["before"], native["after"], native["draws"]
                if outcome in mutations:
                    mutations[outcome](before, after, draws)
                elif outcome == "already_drawn":
                    before = dict(after)
                args = SimpleNamespace(out=root / "pixel", bitmap_content="constant")
                run = mock.Mock()
                run.app.pid, run.fixture.pid = 21, before["pid"]
                run.binary = root / "ShareX"
                run.binary.write_bytes(b"app")
                run.control.side_effect = lambda action, **values: after if action == "observe" else before
                run.preflight.side_effect = lambda: (args.out / "agent-capture-fixture").write_bytes(b"fixture")
                clock = [0.0]
                captures = []
                sleeps = []

                def capture(*values):
                    session = {"id": f"session-{len(captures)}", "state": "completed",
                               "artifacts": [{"kind": "screenshot", "id": "image"}]}
                    (args.out / f"{session['id']}-image.png").write_bytes(b"retained PNG")
                    captures.append(session)
                    return session

                def decode(*values, **kwargs):
                    clock[0] += 0.2
                    if outcome in ("deadline_ready", "late_ready"):
                        clock[0] = 5.0 if outcome == "deadline_ready" else 6.0
                        return {"exitCode": 0, "stdout": json.dumps({"status": "passed"})}
                    if outcome == "decoder_error":
                        return {"exitCode": 1, "stdout": json.dumps({"status": "failed", "reason": "bad PNG"})}
                    pending = outcome == "never_ready" or (outcome == "ready" and len(captures) < 5)
                    status = "pending_presentation" if pending else "passed"
                    return {"exitCode": 0 if status == "passed" else 3, "stdout": json.dumps({"status": status})}

                def cleanup(**kwargs):
                    fixture = args.out / "fixture"
                    fixture.mkdir()
                    STARTUP.GAP.save(fixture / "draw-trace.json", draws)
                    for name in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
                        (fixture / name).write_text("0")
                    return []

                def sleep(seconds):
                    sleeps.append(seconds)
                    clock[0] += seconds

                run.cli.side_effect = capture
                run.command.side_effect = decode
                run.validate_media.return_value = {"status": "passed"}
                run.cleanup.side_effect = cleanup
                with mock.patch.object(STARTUP.NATIVE, "Run", return_value=run), \
                     mock.patch.object(STARTUP.NATIVE, "media_expectation", return_value={"width": 640, "height": 480}), \
                     mock.patch.object(STARTUP.time, "monotonic", side_effect=lambda: clock[0]), \
                     mock.patch.object(STARTUP.time, "sleep", side_effect=sleep):
                    exit_code = STARTUP.run_pixel_check(args)
                result = STARTUP.GAP.read_json(args.out / "pixel-check.json")
                self.assertEqual(result["status"], expected_status, result.get("reason", result.get("errors")))
                self.assertEqual(exit_code, int(expected_status != "passed"))
                self.assertEqual(result["before"], before)
                self.assertTrue(all(row["after"] == after for row in result["attempts"]))
                self.assertEqual(len(result["attempts"]), len(captures))
                self.assertTrue(all(Path(row["png"]).is_file() for row in result["attempts"]))
                self.assertFalse(result["productionE2EPassed"])
                run.cleanup.assert_called_once()
                if outcome == "ready":
                    self.assertEqual(len(captures), 5)
                    self.assertEqual(sleeps, [0.1] * 4)
                    self.assertEqual((result["before"]["draws"], result["attempts"][-1]["after"]["draws"]), (16, 17))
                elif outcome == "never_ready":
                    self.assertGreaterEqual(clock[0], result["readinessDeadlineUptime"])
                    self.assertLess(clock[0], result["readinessDeadlineUptime"] + 0.3)
                else:
                    self.assertEqual(len(captures), 1)
                    self.assertEqual(sleeps, [])
                if outcome in ("deadline_ready", "late_ready"):
                    attempt = result["attempts"][0]
                    self.assertEqual(result["readinessDeadlineUptime"], 5.0)
                    self.assertEqual(attempt["completedUptime"], 5.0 if outcome == "deadline_ready" else 6.0)
                    self.assertEqual(attempt["pixels"]["status"], "passed")
                    if outcome == "late_ready":
                        self.assertIn("completed after the readiness deadline", result["reason"])


if __name__ == "__main__":
    unittest.main()
