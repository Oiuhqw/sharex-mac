import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


SPEC = importlib.util.spec_from_file_location("frame_gap_replay", Path(__file__).resolve().parents[1] / "frame-gap-replay.py")
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)


class Clock:
    def __init__(self):
        self.value = 100.0

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


class ReplaySchedulingTests(unittest.TestCase):
    def test_fixed_slots_skip_slow_requests_without_catchup_and_continue_after_terminal(self):
        clock = Clock()
        calls = []
        session = str(uuid.uuid4())

        def request(request_id):
            calls.append((clock.now(), request_id))
            clock.sleep(0.6 if len(calls) == 1 else 0.02)
            return {"id": session, "state": "completed"}

        slots = REPLAY.status_slots(100, request, clock.now, clock.sleep)
        self.assertEqual(len(slots), 16)
        self.assertEqual([row["index"] for row in slots if row["skipped"]], [1, 2])
        self.assertEqual([time for time, _ in calls], [100] + [100 + i * 0.25 for i in range(3, 16)])
        self.assertEqual(len({request_id for _, request_id in calls}), 14)
        self.assertEqual(clock.now(), 104)

    def test_failed_status_is_retained_and_does_not_cancel_remaining_slots(self):
        clock = Clock()
        calls = []

        def request(request_id):
            calls.append(request_id)
            if len(calls) == 1:
                raise OSError("connection lost")
            return {"id": "owned", "state": "recording"}

        rows = REPLAY.status_slots(100, request, clock.now, clock.sleep)
        self.assertEqual(len(calls), 16)
        self.assertEqual(rows[0]["error"], "connection lost")
        self.assertEqual(rows[-1]["actualMonotonicSeconds"], 103.75)

    def test_schedule_is_balanced_with_the_same_predecessors_for_all_32_arms(self):
        records = REPLAY.plan()
        measured = [row for row in records if row["role"] == "measured"]
        self.assertEqual(len(records), 128)
        self.assertEqual(len(measured), 32)
        self.assertEqual(sum(row["arm"] == "cli" and row["position"] == 1 for row in measured), 8)
        self.assertEqual(sum(row["arm"] == "direct" and row["position"] == 1 for row in measured), 8)
        for offset in range(0, 128, 4):
            self.assertEqual([row["recipe"]["name"] for row in records[offset:offset + 4]],
                             ["animated-display", "static-window", "duration-region", "noisy-window"])
            self.assertEqual(records[offset + 3]["recipe"]["startRoute"], "mcp")


class SocketTests(unittest.TestCase):
    def test_direct_transport_sends_only_status_and_validates_owned_peer(self):
        request = {"version": 1, "id": str(uuid.uuid4()), "operation": "recording.status", "arguments": {"sessionID": "owned"}}
        response = {"version": 1, "id": request["id"], "ok": True, "result": {"id": "owned", "state": "completed"}}
        body = json.dumps(response).encode()
        connection = mock.Mock()
        connection.getsockopt.return_value = 123
        connection.makefile.return_value = io.BytesIO(struct.pack(">I", len(body)) + body)
        self.assertEqual(REPLAY.socket_response(connection, request, 123), response)
        sent = connection.sendall.call_args.args[0]
        self.assertEqual(int.from_bytes(sent[:4], "big"), len(sent[4:]))
        self.assertEqual(json.loads(sent[4:]), request)
        connection.reset_mock()
        connection.getsockopt.return_value = 456
        with self.assertRaisesRegex(REPLAY.NATIVE.Failure, "another process"):
            REPLAY.socket_response(connection, request, 123)
        connection.sendall.assert_not_called()

    def test_invalid_response_lengths_are_rejected(self):
        for payload in (b"\0\0", struct.pack(">I", 1_048_577), struct.pack(">I", 4) + b"{}"):
            connection = mock.Mock()
            connection.getsockopt.return_value = 123
            connection.makefile.return_value = io.BytesIO(payload)
            with self.assertRaises(REPLAY.NATIVE.Failure):
                REPLAY.socket_response(connection, {"id": "request"}, 123)


class ReplayOwnershipTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        evidence = REPLAY.NATIVE.Evidence(Path(temporary.name))
        self.addCleanup(evidence.events.close)
        self.run = REPLAY.ReplayRun(SimpleNamespace(), evidence)
        self.run.binary = Path("/Applications/ShareX.app/Contents/MacOS/ShareX")
        self.run.app = mock.Mock(pid=6837)
        self.run.app.poll.return_value = None
        self.mcp = mock.Mock(pid=7379)
        self.mcp.poll.return_value = None
        self.run.clients = [SimpleNamespace(process=self.mcp)]
        self.run.children = [self.run.app, self.mcp]
        self.run.command = mock.Mock(return_value={"exitCode": 0, "stdout": "7379\n6837\n"})

    def test_owned_persistent_mcp_is_accepted_alongside_its_app(self):
        self.run.require_owned_app()
        self.run.command.assert_called_once_with(["/usr/bin/pgrep", "-x", "ShareX"], timeout=5, check=False)

    def test_startup_before_mcp_connect_still_accepts_only_the_app(self):
        self.run.clients = []
        self.run.command.return_value["stdout"] = "6837\n"
        self.run.require_owned_app()

    def test_foreign_missing_replaced_or_duplicate_processes_are_rejected(self):
        for output in ("6837\n7379\n9000\n", "6837\n", "7379\n", "9000\n7379\n", "6837\n7379\n7379\n"):
            with self.subTest(output=output):
                self.run.command.return_value["stdout"] = output
                with self.assertRaises(REPLAY.NATIVE.Failure):
                    self.run.require_owned_app()
        self.run.command.return_value = {"exitCode": 2, "stdout": "6837\n7379\n"}
        with self.assertRaises(REPLAY.NATIVE.Failure):
            self.run.require_owned_app()

    def test_client_not_registered_as_an_owned_child_is_rejected(self):
        self.run.children = [self.run.app]
        with self.assertRaisesRegex(REPLAY.NATIVE.Failure, "owned child"):
            self.run.require_owned_app()
        self.run.command.assert_not_called()

    def test_exited_app_or_reused_exited_mcp_pid_cannot_pass(self):
        self.run.app.poll.return_value = 0
        with self.assertRaisesRegex(REPLAY.NATIVE.Failure, "exited"):
            self.run.require_owned_app()
        self.run.command.assert_not_called()
        self.run.app.poll.return_value = None
        self.mcp.poll.return_value = 0
        with self.assertRaises(REPLAY.NATIVE.Failure):
            self.run.require_owned_app()

    def test_direct_request_rejects_the_owned_mcp_as_socket_peer(self):
        self.run.require_owned_app()
        session_id = str(uuid.uuid4())
        self.run.owned_session_ids.add(session_id)
        self.run.endpoint = Path("/tmp/sharex-agent/agent.sock")
        connection = mock.Mock()
        connection.getsockopt.return_value = self.mcp.pid
        socket_context = mock.MagicMock()
        socket_context.__enter__.return_value = connection
        with mock.patch.object(REPLAY.socket, "AF_UNIX", 1, create=True), \
                mock.patch.object(REPLAY.socket, "socket", return_value=socket_context), \
                self.assertRaisesRegex(REPLAY.NATIVE.Failure, "another process"):
            self.run.direct("recording.status", session_id)
        connection.sendall.assert_not_called()


class CaptureFailureTests(unittest.TestCase):
    def fake_run(self):
        run = mock.Mock()
        run.trace_files_seen = set()
        run.geometry = {"windowBounds": {"X": 0, "Y": 0, "Width": 640, "Height": 480},
                        "displayBounds": {"x": 0, "y": 0}}
        run.window_target = run.display_target = {"pixelScale": 1, "widthPoints": 640, "heightPoints": 480}
        run.selection.return_value = {"target": "window-token"}
        run.fixture_state.return_value = {"mode": "animated", "stage": 0}
        return run

    def test_transport_failure_stops_the_owned_capture_before_continuing(self):
        record = REPLAY.plan()[3]
        run, client = self.fake_run(), mock.Mock()
        client.call.side_effect = OSError("MCP reply lost")
        run.direct.side_effect = lambda operation, session_id: {"id": session_id, "state": "completed",
                                                               "stopReason": "user_stop", "artifacts": []}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(REPLAY.os.environ, {"SHAREX_FRAME_GAP_TRACE_DIR": temporary}), \
                mock.patch.object(REPLAY, "wait_for_trace", return_value={"complete": True, "seconds": 0, "files": []}):
            self.assertTrue(REPLAY.capture(run, client, record, Path(temporary)))
            run.direct.assert_called_once_with("recording.stop", record["sessionID"])
            self.assertIn("MCP reply lost", record["infrastructureErrors"])
            self.assertEqual(record["status"], "failed")
            self.assertEqual(REPLAY.GAP.read_json(Path(temporary) / record["path"] / "terminal.json")["id"], record["sessionID"])

    def test_unresolved_capture_ownership_prevents_the_next_arm(self):
        record = REPLAY.plan()[3]
        run, client = self.fake_run(), mock.Mock()
        client.call.side_effect = OSError("MCP reply lost")
        run.direct.side_effect = OSError("stop reply lost")
        with tempfile.TemporaryDirectory() as temporary:
            self.assertFalse(REPLAY.capture(run, client, record, Path(temporary)))
        self.assertEqual(record["terminal"], None)
        self.assertTrue(any("cleanup failed" in error for error in record["infrastructureErrors"]))

    def test_all_predecessor_and_measured_captures_use_same_process_and_client(self):
        clock = Clock()
        run, client = self.fake_run(), mock.Mock()
        stage = {"mode": "animated", "stage": 0}
        sessions, calls = {}, []

        def control(action, **values):
            stage.update(values)
            return {"mode": stage["mode"], "stage": 0, "pid": 123, "windowID": 456,
                    "draws": 10, "tick": 2, "uptime": clock.now()}

        def operation(route, name, args=None, request_id=None):
            calls.append((route, name))
            if name == "recording.start":
                sessions[request_id] = {"id": request_id, "state": "recording", "acceptedFrames": 1, "artifacts": []}
                return sessions[request_id]
            value = sessions[args["sessionID"]]
            if name == "recording.stop":
                value = {**value, "state": "completed", "stopReason": "user_stop"}
            return value

        run.control.side_effect = control
        run.cli.side_effect = lambda *args: operation("cli", *args)
        client.call.side_effect = lambda *args: operation("mcp", *args)
        run.terminal.side_effect = lambda sid: {**sessions[sid], "state": "completed", "stopReason": "duration_limit"}
        run.direct_terminal.side_effect = lambda sid, deadline: {**sessions[sid], "state": "completed", "stopReason": "byte_limit"}
        run.direct.side_effect = lambda op, sid, rid: operation("direct", op, {"sessionID": sid}, rid)
        scheduler = REPLAY.status_slots
        records = REPLAY.plan()
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(REPLAY.os.environ, {"SHAREX_FRAME_GAP_TRACE_DIR": temporary}), \
                mock.patch.object(REPLAY.time, "monotonic", clock.now), mock.patch.object(REPLAY.time, "sleep", clock.sleep), \
                mock.patch.object(REPLAY, "status_slots", side_effect=lambda anchor, request: scheduler(anchor, request, clock.now, clock.sleep)), \
                mock.patch.object(REPLAY, "wait_for_trace", return_value={"complete": True, "seconds": 0, "files": []}):
            for record in records:
                self.assertTrue(REPLAY.capture(run, client, record, Path(temporary)))
                self.assertEqual(record["infrastructureErrors"], [])
            self.assertEqual(len(list(Path(temporary).glob("captures/*/*/capture.json"))), 128)
        measured = [row for row in records if row["role"] == "measured"]
        self.assertTrue(all(row["options"]["maxBytes"] == 1048576 and len(row["slots"]) == 16 for row in measured))
        self.assertEqual(calls.count(("mcp", "recording.start")), 64)
        self.assertEqual(calls.count(("cli", "recording.status")), 256)
        self.assertEqual(calls.count(("direct", "recording.status")), 256)
        self.assertTrue(all(row["expectation"]["motion"] == "static" for row in records if row["recipe"]["name"] == "static-window"))

    def test_orchestrator_drains_quits_and_flushes_fixture_before_media_verification(self):
        clock, order = Clock(), []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "ShareX"
            binary.write_bytes(b"installed binary")
            run = mock.Mock(binary=binary, metrics=[], app=mock.Mock(pid=123), fixture=mock.Mock())
            run.app.poll.return_value = run.fixture.poll.return_value = None
            run.connect.return_value = mock.Mock(process=mock.Mock(pid=456))
            run.quit_app.side_effect = lambda: order.append(("quit", clock.now()))
            run.cleanup.side_effect = lambda **kwargs: order.append(("cleanup", clock.now())) or []

            def capture(native, client, record, output):
                order.append(("capture", clock.now()))
                record["status"] = "collected"
                return True

            def verify(native, records, output):
                order.append(("verify", clock.now()))
                self.assertEqual(len(records), 128)

            args = SimpleNamespace(app=root, build_settings=root / "build.json", out=root / "output", display_name=None)
            with mock.patch.object(REPLAY.sys, "platform", "darwin"), \
                    mock.patch.dict(REPLAY.os.environ, {"GITHUB_ACTIONS": "true", "SHAREX_FRAME_GAP_TRACE_DIR": str(root / "traces")}), \
                    mock.patch.object(REPLAY, "ReplayRun", return_value=run), \
                    mock.patch.object(REPLAY, "capture", side_effect=capture), \
                    mock.patch.object(REPLAY, "verify_captures", side_effect=verify), \
                    mock.patch.object(REPLAY, "analyze", side_effect=lambda out, source: {**source, "status": "collected", "counts": {}}), \
                    mock.patch.object(REPLAY.time, "monotonic", clock.now), \
                    mock.patch.object(REPLAY.time, "sleep", clock.sleep), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(REPLAY.run_experiment(args), 0)
            self.assertEqual([event for event, _ in order], ["capture"] * 128 + ["quit", "cleanup", "verify"])
            self.assertEqual(order[-3][1] - order[-4][1], 21)
            run.connect.assert_called_once()
            run.preflight.assert_called_once()


class RetainedEvidenceTests(unittest.TestCase):
    def test_trace_flush_wait_joins_both_ids_and_waits_for_the_atomic_file(self):
        clock = Clock()
        session_id, artifact_id = (str(uuid.uuid4()).upper() for _ in range(2))
        session = {"id": session_id, "artifacts": [{"id": artifact_id, "kind": "recording"}]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            REPLAY.GAP.save(root / "wrong-trace.json", {"context": {"videoPath": f"/remote/{session_id}/{uuid.uuid4()}/capture.partial.mp4"}})

            def sleep(seconds):
                clock.sleep(seconds)
                REPLAY.GAP.save(root / "right-trace.json", {"context": {"videoPath": f"/remote/{session_id}/{artifact_id}/capture.partial.mp4"}})

            result = REPLAY.wait_for_trace(root, session, clock=clock.now, sleep=sleep)
            self.assertTrue(result["complete"])
            self.assertEqual(result["files"], ["right-trace.json"])
            self.assertGreater(result["seconds"], 0)

    def test_verifier_quality_failure_is_saved_and_later_capture_is_verified(self):
        records = REPLAY.plan()[3:5]
        run = mock.Mock()
        for record in records:
            record.update(sessionID=str(uuid.uuid4()), terminal={"id": str(uuid.uuid4()), "state": "completed", "artifacts": []}, expectation={})

        def verify(*args, **kwargs):
            run.validation_record["verifierProcess"] = {"exitCode": 1, "stdout": json.dumps({"status": "failed", "reason": "gap 0.6"})}
            raise REPLAY.NATIVE.Failure("Independent media decode failed")

        run.validate_media.side_effect = verify
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for record in records:
                (root / record["path"]).mkdir(parents=True)
            REPLAY.verify_captures(run, records, root)
            self.assertEqual(run.validate_media.call_count, 2)
            for record in records:
                self.assertEqual(REPLAY.GAP.read_json(root / record["path"] / "verifier-process.json")["exitCode"], 1)
                self.assertEqual(record["infrastructureErrors"], [])

    def test_offline_cli_preserves_raw_evidence_and_separates_quality_from_completeness(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output, traces = root / "out", root / "traces"
            (output / "fixture").mkdir(parents=True)
            traces.mkdir()
            for filename, data in (("draw-trace.json", [{"exitUptime": 1}]), ("operation-trace.json", [{"uptime": 1}])):
                REPLAY.GAP.save(output / "fixture" / filename, data)
            for filename in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
                (output / "fixture" / filename).write_text("0")
            records = []
            for index, record in enumerate((REPLAY.plan()[3], REPLAY.plan()[7])):
                session_id, artifact_id, writer_id = (str(uuid.uuid4()).upper() for _ in range(3))
                capture_dir = output / record["path"]
                capture_dir.mkdir(parents=True)
                snapshot = output / "session-snapshots" / session_id
                (snapshot / artifact_id).mkdir(parents=True)
                (snapshot / artifact_id / "capture.mp4").write_bytes(b"retained-media")
                manifest = {"id": session_id, "state": "completed", "stopReason": "byte_limit",
                            "artifacts": [{"id": artifact_id, "kind": "recording", "state": "completed"}]}
                REPLAY.GAP.save(snapshot / "manifest.json", manifest)
                record.update(sessionID=session_id, status="collected", terminal=manifest, startAcknowledgedMonotonicSeconds=1,
                              slots=[{"index": n, "state": "completed", "skipped": False} for n in range(16)])
                REPLAY.GAP.save(capture_dir / "capture.json", record)
                gap = 0.6 if index == 0 else 0.5
                callbacks = [{"screen": True, "valid": True, "image": True, "status": 0, "pts": pts,
                              "entryUptime": pts, "exitUptime": pts + 0.001} for pts in (1, 1 + gap)]
                REPLAY.GAP.save(traces / f"{writer_id}-capture.partial-trace.json", {"writerID": writer_id,
                    "context": {"videoPath": f"/do-not-open/{session_id}/{artifact_id}/capture.partial.mp4"},
                    "callbacks": callbacks, "limits": [], "heartbeats": [], "overflow": 0,
                    "history": {"events": [{"name": "writer.init", "writerID": writer_id, "uptime": 0.5}], "overflow": index}})
                REPLAY.GAP.save(capture_dir / "decode-process.json", {"exitCode": 0, "stdout": json.dumps({"status": "passed", "frames": [{"pts": 1}, {"pts": 1 + gap}]})})
                REPLAY.GAP.save(capture_dir / "verifier-process.json", {"exitCode": 1 if index == 0 else 0,
                    "stdout": json.dumps({"status": "failed" if index == 0 else "passed", "reason": "original verifier result"})})
                records.append(record)
            REPLAY.GAP.save(traces / "lifecycle-final.json", {"events": [{"name": "writer.deinit", "uptime": 25}], "overflow": 0})
            REPLAY.GAP.save(output / "replay.json", {"traceDirectory": "../traces", "captures": records})
            before = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            result = subprocess.run([sys.executable, str(REPLAY.ROOT / "frame-gap-replay.py"), "--reanalyze", str(output)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            report = REPLAY.GAP.read_json(output / "replay-analysis.json")
            self.assertEqual(report["counts"]["cli"]["qualityFailures"], 1)
            self.assertEqual(report["counts"]["cli"]["infrastructureFailures"], 0)
            self.assertEqual(report["counts"]["cli"]["incomplete"], 0)
            self.assertEqual(report["counts"]["direct"]["qualityFailures"], 0)
            self.assertEqual(report["counts"]["direct"]["incomplete"], 1)
            self.assertEqual(report["retainedEvidence"]["unmatchedTraces"], [])
            for path, content in before.items():
                self.assertEqual(path.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
