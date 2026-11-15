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
        for _, timing in STARTUP.COMPARISONS["noise-timing"]:
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
                ack = mock.call.emit("metadata_start_acknowledged", requestID=REQUEST, sessionID=REQUEST, noiseTiming=timing)
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
                      ["--arm", "metadata", "--noise-timing", "after"]):
            with self.subTest(arguments=extra), mock.patch.object(STARTUP.sys, "argv", base + extra), \
                 mock.patch.object(STARTUP.sys, "stderr"), self.assertRaises(SystemExit) as raised:
                STARTUP.main()
            self.assertEqual(raised.exception.code, 2)


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

            def analysis(directory, arm, request_id, noise_timing=None):
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
        startup = workflow.split("- name: Compare first noisy startup after original native prefixes", 1)[1].split("- name:", 1)[0]
        self.assertIn("steps.setup-ui.outcome == 'success'", startup)
        self.assertLess(startup.index("agentCaptureEnabled -bool true"), startup.index("python3 scripts/frame-gap-startup.py"))
        self.assertIn("--comparison noise-timing", startup)
        dispatch = workflow.split("  workflow_dispatch:", 1)[1].split("permissions:", 1)[0]
        self.assertEqual(sum(line.startswith("      ") and not line.startswith("       ")
                             and line.endswith(":") for line in dispatch.splitlines()), 10)
        maintenance = workflow.split("- name: Validate manual recording, permission reset, and real uninstall", 1)[1].split("- name:", 1)[0]
        self.assertIn("!inputs.frame_gap_replay", maintenance)

    def test_noise_comparison_passes_all_four_actual_arguments_and_retains_a_failed_arm(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ShareX.app"
            binary = app / "Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixed diagnostic build")
            setup = root / "setup.json"
            STARTUP.GAP.save(setup, {"status": "passed"})
            args = SimpleNamespace(out=root / "comparison", app=app, build_settings=root / "settings.json",
                                   setup_result=setup, commit="diagnostic-revision", comparison="noise-timing")
            calls = []

            def harness(arguments, log, environment, timeout):
                with mock.patch.object(STARTUP.sys, "argv", [str(part) for part in arguments[1:]]), \
                     mock.patch.object(STARTUP, "run_arm", side_effect=lambda parsed: calls.append((parsed, environment)) or 0):
                    self.assertEqual(STARTUP.main(), 0)
                self.assertEqual(timeout, 480)
                return {"exitCode": 1 if len(calls) == 1 else 0, "timedOut": False}

            def analysis(directory, arm, request_id, noise_timing):
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
            self.assertEqual([parsed.noise_timing for parsed, _ in calls], ["before", "after", "after", "before"])
            self.assertEqual(len({env["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"] for _, env in calls}), 4)
            self.assertEqual(len({parsed.out for parsed, _ in calls}), 4)
            for parsed, environment in calls:
                self.assertEqual(parsed.arm, "metadata")
                self.assertEqual(parsed.comparison, "noise-timing")
                self.assertEqual(parsed.app, app)
                self.assertEqual(parsed.build_settings, args.build_settings)
                self.assertIsNone(parsed.display_name)
                self.assertEqual(environment["SHAREX_FRAME_GAP_STARTUP_SINK"], "metadata")
                self.assertEqual(environment["SHAREX_FRAME_GAP_HEARTBEAT"], "1")
                self.assertEqual(environment["SHAREX_FRAME_GAP_FIXTURE_TRACE"], "1")
                for key in ("SHAREX_FRAME_GAP_OWNED_BUFFERS", "SHAREX_FRAME_GAP_NV12", "SHAREX_FRAME_GAP_DEEPER_QUEUE"):
                    self.assertEqual(environment[key], "0")
            summary = STARTUP.GAP.read_json(args.out / "comparison.json")
            self.assertEqual(summary["order"], ["before", "after", "after", "before"])
            self.assertEqual(summary["incompleteArms"], 1)
            self.assertEqual(summary["status"], "diagnostic_incomplete")
            self.assertEqual(summary["runs"][0]["result"]["status"], "failed")
            self.assertFalse(summary["productionE2EPassed"])
            self.assertIn("noise control response", summary["acknowledgementCaveat"])


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


if __name__ == "__main__":
    unittest.main()
