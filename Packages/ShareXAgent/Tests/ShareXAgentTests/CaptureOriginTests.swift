import Foundation
import Testing
@testable import ShareXAgent

private func originSession(_ origin: CaptureOrigin) -> CaptureSession {
    CaptureSession(source: CaptureTarget(token: "display", kind: .display, name: "Display", widthPoints: 1920,
                                         heightPoints: 1080, pixelScale: 1),
                   selection: CaptureSelection(target: "display"), options: RecordingOptions(), origin: origin)
}

@Test func oldManifestsRemainAgentOwned() throws {
    let encoder = JSONEncoder()
    var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(originSession(.agent))) as? [String: Any])
    json.removeValue(forKey: "origin")
    let restored = try JSONDecoder().decode(CaptureSession.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.origin == .agent)
    try restored.requireAgentOwnership()
}

@Test(arguments: [CaptureOrigin.agent, .human])
func recordingOwnershipSurvivesPersistenceAndRecovery(origin: CaptureOrigin) throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    var original = originSession(origin)
    original.artifacts = [CaptureArtifact(kind: .recording)]
    let manifest = folder.appendingPathComponent("manifest.json")
    try AtomicFile.create(JSONEncoder().encode(original), at: manifest)
    var recovered = try JSONDecoder().decode(CaptureSession.self, from: Data(contentsOf: manifest))
    #expect(recovered == original)
    #expect(recovered.recoverAfterRestart())
    try AtomicFile.replace(JSONEncoder().encode(recovered), at: manifest)
    let restored = try JSONDecoder().decode(CaptureSession.self, from: Data(contentsOf: manifest))
    #expect(restored.origin == origin)
    if origin == .human {
        #expect(throws: AgentFailure(.permissionDenied, "This recording belongs to a person. Stop or change it in ShareX.")) {
            try restored.requireAgentOwnership()
        }
    } else { try restored.requireAgentOwnership() }
}

@Test func invalidOriginsCannotBecomeAgentOwned() throws {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(originSession(.human))) as? [String: Any])
    for invalid: Any in ["unknown", NSNull()] {
        json["origin"] = invalid
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CaptureSession.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
