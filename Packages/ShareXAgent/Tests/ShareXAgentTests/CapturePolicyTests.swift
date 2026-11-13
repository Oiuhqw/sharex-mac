import Foundation
import Testing
@testable import ShareXAgent

private let display = CaptureTarget(token: "display", kind: .display, name: "Test", widthPoints: 1920, heightPoints: 1080, pixelScale: 2)

@Test func displayRegionsUseLogicalPointsAndIncludeEdges() throws {
    try CaptureGeometry.validate(region: CaptureRegion(x: 960, y: 540, width: 960, height: 540), target: display)
    for region in [CaptureRegion(x: 1919, y: 0, width: 2, height: 1), CaptureRegion(x: 0, y: 1079, width: 1, height: 2),
                   CaptureRegion(x: -.infinity, y: 0, width: 1, height: 1), CaptureRegion(x: 0, y: 0, width: .nan, height: 1)] {
        #expect(throws: AgentFailure.self) { try CaptureGeometry.validate(region: region, target: display) }
    }
}

@Test func windowRegionsAreRejected() {
    let window = CaptureTarget(token: "window", kind: .window, name: "Test", widthPoints: 100, heightPoints: 100, pixelScale: 1)
    #expect(throws: AgentFailure.self) { try CaptureGeometry.validate(region: CaptureRegion(x: 0, y: 0, width: 10, height: 10), target: window) }
}

@Test func videoSizesPreserveAspectWithinEvenPixelRounding() throws {
    for width in [2, 320, 801, 1920, 3840, 5120, 7680] {
        for height in [240, 601, 1080, 2160, 4320] where width >= 4 || height <= 2160 {
            let output = try CaptureGeometry.recordingSize(widthPixels: width, heightPixels: height)
            #expect(output.width > 0 && output.width <= 3840 && output.width % 2 == 0)
            #expect(output.height > 0 && output.height <= 2160 && output.height % 2 == 0)
            let factor = min(1, min(3840 / Double(width), 2160 / Double(height)))
            #expect(abs(Double(output.width) - Double(width) * factor) < 2)
            #expect(abs(Double(output.height) - Double(height) * factor) < 2)
        }
    }
    #expect(try CaptureGeometry.recordingSize(widthPixels: 5120, heightPixels: 2880) == CapturePixelSize(width: 3840, height: 2160))
    #expect(throws: AgentFailure.self) { try CaptureGeometry.recordingSize(widthPixels: 1, heightPixels: 1000) }
    #expect(throws: AgentFailure.self) { try CaptureGeometry.recordingSize(widthPixels: 0, heightPixels: 1000) }
}

@Test func restartNeverPromotesAnUnfinishedRecording() {
    var session = CaptureSession(source: display, selection: CaptureSelection(target: display.token), options: RecordingOptions())
    session.state = .finalizing
    session.artifacts = [CaptureArtifact(kind: .recording), CaptureArtifact(kind: .screenshot, state: .completed)]
    session.markers = [SessionMarker(label: "test passed", outcome: .passed)]
    let recovered = session.recoverAfterRestart()
    #expect(recovered)
    #expect(session.state == .interrupted)
    #expect(session.artifacts[0].state == .interrupted)
    #expect(session.artifacts[1].state == .completed)
    #expect(session.markers[0].outcome == .passed)
    let recoveredAgain = session.recoverAfterRestart()
    #expect(!recoveredAgain)
}

@Test func interruptedCheckpointPreservesCompletedVideo() {
    var session = CaptureSession(source: display, selection: CaptureSelection(target: display.token), options: RecordingOptions())
    session.state = .completed
    session.artifacts = [CaptureArtifact(kind: .recording, state: .completed), CaptureArtifact(kind: .screenshot)]
    let recovered = session.recoverAfterRestart()
    #expect(recovered)
    #expect(session.state == .completed)
    #expect(session.artifacts[0].state == .completed)
    #expect(session.artifacts[1].state == .interrupted)
}

@Test func recordingFailurePreservesCheckpointEvidenceAndTestOutcomes() {
    var session = CaptureSession(source: display, selection: CaptureSelection(target: display.token))
    session.artifacts = [CaptureArtifact(kind: .recording), CaptureArtifact(kind: .screenshot, state: .completed)]
    session.markers = [SessionMarker(label: "test failed", outcome: .failed)]
    session.failRecording(AgentFailure(.targetNotFound, "Window closed."), reason: "target_lost")
    #expect(session.state == .failed)
    #expect(session.artifacts[0].state == .failed)
    #expect(session.artifacts[1].state == .completed)
    #expect(session.markers[0].outcome == .failed)
}
