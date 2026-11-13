import Foundation
import Testing
@testable import ShareXAgent

@Test func catalogContainsEveryOperationOnce() {
    #expect(Set(OperationCatalog.definitions.map(\.operation)) == Set(AgentOperation.allCases))
    #expect(OperationCatalog.definitions.count == 8)
}

@Test func commandRoundTripAndDefaults() throws {
    let request = AgentRequest(operation: .recordingStart, arguments: ["target": .string("opaque-token")])
    let decoded = try JSONDecoder().decode(AgentRequest.self, from: request.canonicalData())
    #expect(decoded == request)
    #expect(try OperationCatalog.validate(decoded) == .recordingStart(CaptureSelection(target: "opaque-token"), RecordingOptions()))
}

@Test func strictBoundaryRejectsUnknownAndWrongFields() {
    let cases: [[String: JSONValue]] = [
        [:], ["target": .number(2)], ["target": .string("a"), "path": .string("/tmp/overwrite")],
        ["target": .string("a"), "fps": .number(30.5)], ["target": .string("a"), "maxBytes": .number(2_147_483_649)],
        ["target": .string("a"), "region": .object(["x": .number(-1), "y": .number(0), "width": .number(20), "height": .number(20)])],
        ["target": .string("a"), "region": .object(["x": .number(0), "y": .number(0), "width": .number(0), "height": .number(20)])]
    ]
    for arguments in cases {
        #expect(throws: AgentFailure.self) { try OperationCatalog.validate(AgentRequest(operation: .recordingStart, arguments: arguments)) }
    }
}

@Test func markersKeepTestOutcomeSeparateFromCapture() throws {
    let id = UUID()
    let request = AgentRequest(operation: .sessionMark, arguments: ["sessionID": .string(id.uuidString), "label": .string("login"), "outcome": .string("failed")])
    #expect(try OperationCatalog.validate(request) == .sessionMark(id, label: "login", outcome: .failed))
    let bad = AgentRequest(operation: .sessionMark, arguments: ["sessionID": .string(id.uuidString), "label": .string("login"), "outcome": .string("complete")])
    #expect(throws: AgentFailure.self) { try OperationCatalog.validate(bad) }
}

@Test func equivalentObjectOrderHasSameRequestFingerprint() throws {
    let id = UUID()
    let a = AgentRequest(id: id, operation: .screenshot, arguments: ["target": .string("a"), "includeCursor": .bool(true)])
    let b = AgentRequest(id: id, operation: .screenshot, arguments: ["includeCursor": .bool(true), "target": .string("a")])
    #expect(try a.canonicalData() == b.canonicalData())
    let c = AgentRequest(id: id, operation: .screenshot, arguments: ["target": .string("b")])
    #expect(try a.canonicalData() != c.canonicalData())
}

@Test func responsePreservesActionableFailure() throws {
    let response = AgentResponse.failure(UUID(), AgentFailure(.permissionDenied, "Grant Screen Recording permission in Settings."))
    #expect(try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(response)) == response)
    #expect(response.result == nil)
    #expect(!response.ok)
}
