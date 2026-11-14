import Foundation
import Testing
@testable import ShareXAgent

struct ReplayPolicyTests {
    private let display = CaptureTarget(token: "display", kind: .display, name: "Test", widthPoints: 1920, heightPoints: 1080, pixelScale: 2)
    private let selection = CaptureSelection(target: "display")

    private func refusal(_ id: UUID, _ code: AgentErrorCode) -> AgentResponse {
        .failure(id, AgentFailure(code, "Refused."))
    }

    @Test func refusalThatLeftNoSessionRunsAgainOnRetry() {
        let id = UUID()
        let commands: [AgentCommand] = [.recordingStart(selection, RecordingOptions()), .screenshot(selection, sessionID: nil)]
        let codes: [AgentErrorCode] = [.busy, .permissionDenied, .diskFull, .limitReached, .targetNotFound]
        for command in commands {
            for code in codes {
                #expect(!RequestReplayPolicy.keepsResponse(refusal(id, code), to: command, requestSessionExists: false, targetSession: nil))
            }
        }
    }

    @Test func failureAfterTheSessionFolderExistsIsReplayed() {
        let id = UUID()
        let commands: [AgentCommand] = [.recordingStart(selection, RecordingOptions()), .screenshot(selection, sessionID: nil)]
        let codes: [AgentErrorCode] = [.startupTimeout, .captureFailed, .permissionDenied, .storageFailed]
        for command in commands {
            for code in codes {
                #expect(RequestReplayPolicy.keepsResponse(refusal(id, code), to: command, requestSessionExists: true, targetSession: nil))
            }
        }
    }

    @Test func successIsReplayedForEveryMutation() {
        let id = UUID(), session = UUID()
        let commands: [AgentCommand] = [
            .recordingStart(selection, RecordingOptions()), .screenshot(selection, sessionID: nil), .screenshot(selection, sessionID: session),
            .recordingStop(session), .sessionMark(session, label: "step", outcome: nil)
        ]
        for command in commands {
            #expect(RequestReplayPolicy.keepsResponse(.success(id, .object([:])), to: command, requestSessionExists: false, targetSession: nil))
        }
    }

    @Test func checkpointFailureIsReplayedOnlyWhenItsArtifactWasRecorded() {
        let id = UUID()
        var session = CaptureSession(source: display, selection: selection)
        let command = AgentCommand.screenshot(selection, sessionID: session.id)
        session.artifacts = [CaptureArtifact(kind: .recording, state: .completed), CaptureArtifact(kind: .screenshot, state: .completed)]
        #expect(!RequestReplayPolicy.keepsResponse(refusal(id, .limitReached), to: command, requestSessionExists: false, targetSession: session))
        #expect(!RequestReplayPolicy.keepsResponse(refusal(id, .storageFailed), to: command, requestSessionExists: false, targetSession: nil))
        session.artifacts.append(CaptureArtifact(id: id, kind: .screenshot, state: .failed))
        #expect(RequestReplayPolicy.keepsResponse(refusal(id, .captureFailed), to: command, requestSessionExists: false, targetSession: session))
    }

    @Test func markerFailureIsReplayedOnlyWhenItsMarkerWasRecorded() {
        let id = UUID()
        var session = CaptureSession(source: display, selection: selection)
        let command = AgentCommand.sessionMark(session.id, label: "login", outcome: .passed)
        session.markers = [SessionMarker(label: "earlier step")]
        #expect(!RequestReplayPolicy.keepsResponse(refusal(id, .limitReached), to: command, requestSessionExists: false, targetSession: session))
        #expect(!RequestReplayPolicy.keepsResponse(refusal(id, .sessionNotFound), to: command, requestSessionExists: false, targetSession: nil))
        session.markers.append(SessionMarker(id: id, label: "login", outcome: .passed))
        #expect(RequestReplayPolicy.keepsResponse(refusal(id, .storageFailed), to: command, requestSessionExists: false, targetSession: session))
    }

    @Test func failedStopIsNeverReplayed() {
        let id = UUID()
        var session = CaptureSession(source: display, selection: selection, options: RecordingOptions())
        session.state = .finalizing
        let command = AgentCommand.recordingStop(session.id)
        #expect(!RequestReplayPolicy.keepsResponse(refusal(id, .storageFailed), to: command, requestSessionExists: false, targetSession: session))
        #expect(!RequestReplayPolicy.keepsResponse(refusal(id, .sessionNotFound), to: command, requestSessionExists: false, targetSession: nil))
    }

    @Test func onlyCheckpointAndMarkerCommandsNameATargetSession() {
        let session = UUID()
        #expect(RequestReplayPolicy.targetSession(of: .screenshot(selection, sessionID: session)) == session)
        #expect(RequestReplayPolicy.targetSession(of: .sessionMark(session, label: "step", outcome: nil)) == session)
        #expect(RequestReplayPolicy.targetSession(of: .screenshot(selection, sessionID: nil)) == nil)
        #expect(RequestReplayPolicy.targetSession(of: .recordingStart(selection, RecordingOptions())) == nil)
        #expect(RequestReplayPolicy.targetSession(of: .recordingStop(session)) == nil)
    }

    @Test func requestRecordsExpireAfterSevenDays() {
        let now = Date()
        let day: TimeInterval = 86_400
        #expect(!RequestReplayPolicy.recordExpired(modifiedAt: now, now: now))
        #expect(!RequestReplayPolicy.recordExpired(modifiedAt: now.addingTimeInterval(-7 * day + 1), now: now))
        #expect(RequestReplayPolicy.recordExpired(modifiedAt: now.addingTimeInterval(-7 * day - 1), now: now))
        #expect(RequestReplayPolicy.recordExpired(modifiedAt: now.addingTimeInterval(-30 * day), now: now))
    }
}
