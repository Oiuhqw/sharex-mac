import Foundation
import Testing
@testable import ShareXAgent

struct StorageTests {
    private let display = CaptureTarget(token: "display", kind: .display, name: "Test", widthPoints: 1920, heightPoints: 1080, pixelScale: 2)
    private let selection = CaptureSelection(target: "display")
    private let day: TimeInterval = 86_400

    @Test func capabilitiesCarryStorageBesideTheExistingFields() throws {
        let capabilities = AgentCapabilities(access: AgentAccessState(enabled: false, screenRecordingGranted: true),
                                             sessionRoot: "/tmp/sessions", storage: AgentStorageStatus(sessionCount: 3, unreadableSessions: 2))
        let encoded = try JSONValue.encode(capabilities)
        guard case .object(let fields) = encoded else {
            Issue.record("Capabilities must encode as a JSON object.")
            return
        }
        #expect(fields["storage"] == JSONValue.object(["sessionCount": .number(3), "sessionLimit": .number(2048), "unreadableSessions": .number(2)]))
        let expectedKeys: Set<String> = ["protocolVersion", "access", "operations", "limits", "sessionRoot", "coordinateSpace", "targetChangePolicy", "storage"]
        #expect(Set(fields.keys) == expectedKeys)
        #expect(fields["access"] == JSONValue.object(["enabled": .bool(false), "screenRecordingGranted": .bool(true)]))
        #expect(fields["sessionRoot"] == JSONValue.string("/tmp/sessions"))
        #expect(fields["operations"] == JSONValue.array(AgentOperation.allCases.map { JSONValue.string($0.rawValue) }))
        let decoded = try encoded.decode(AgentCapabilities.self)
        #expect(decoded.storage == AgentStorageStatus(sessionCount: 3, unreadableSessions: 2))
        #expect(try JSONValue.encode(decoded) == encoded)
    }

    @Test func capabilitiesReportEmptyStorageByDefault() {
        let capabilities = AgentCapabilities(access: AgentAccessState(enabled: true, screenRecordingGranted: true), sessionRoot: "/tmp/sessions")
        #expect(capabilities.storage == AgentStorageStatus(sessionCount: 0, unreadableSessions: 0))
    }

    @Test func sessionLimitIsReachedAtTheLimit() {
        let limit = AgentStorageStatus().sessionLimit
        #expect(limit == 2048)
        #expect(!AgentStorageStatus(sessionCount: limit - 1).sessionLimitReached)
        #expect(AgentStorageStatus(sessionCount: limit).sessionLimitReached)
        #expect(AgentStorageStatus(sessionCount: limit + 1).sessionLimitReached)
    }

    @Test func finishedSessionIsOldAfterThirtyDays() {
        var session = CaptureSession(source: display, selection: selection)
        let created = session.createdAt
        let finalStates: [RecordingState] = [.completed, .failed, .interrupted]
        for state in finalStates {
            session.state = state
            #expect(!session.isOldCapture(at: created.addingTimeInterval(30 * day - 1)))
            #expect(session.isOldCapture(at: created.addingTimeInterval(30 * day + 1)))
        }
    }

    @Test func endTimeDecidesTheAgeWhenItIsPresent() {
        var session = CaptureSession(source: display, selection: selection, options: RecordingOptions())
        session.state = .completed
        session.endedAt = session.createdAt.addingTimeInterval(20 * day)
        #expect(!session.isOldCapture(at: session.createdAt.addingTimeInterval(45 * day)))
        #expect(session.isOldCapture(at: session.createdAt.addingTimeInterval(51 * day)))
    }

    @Test func unfinishedSessionIsNeverOld() {
        var session = CaptureSession(source: display, selection: selection, options: RecordingOptions())
        let later = session.createdAt.addingTimeInterval(365 * day)
        let liveStates: [RecordingState] = [.starting, .recording, .finalizing]
        for state in liveStates {
            session.state = state
            #expect(!session.isOldCapture(at: later))
        }
    }

    @Test func sessionWithAScreenshotInProgressIsNotOld() {
        var session = CaptureSession(source: display, selection: selection, options: RecordingOptions())
        let later = session.createdAt.addingTimeInterval(365 * day)
        session.state = .completed
        session.artifacts = [CaptureArtifact(kind: .recording, state: .completed), CaptureArtifact(kind: .screenshot)]
        #expect(!session.isOldCapture(at: later))
        session.artifacts[1].state = .completed
        #expect(session.isOldCapture(at: later))
    }
}
