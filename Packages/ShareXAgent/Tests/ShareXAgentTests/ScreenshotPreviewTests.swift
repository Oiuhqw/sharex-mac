import Foundation
import Testing
@testable import ShareXAgent

private let smallPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mMwTpv5HwAENAIyhHMY8AAAAABJRU5ErkJggg==")!

/// 3136 by 16 pixels.
private let widePNG = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAADEAAAAAQCAYAAACs/evuAAAA/UlEQVR42u3bMQ0AAAjAMDzhCU+oBRUkHD1qYP8iqwcAAAAAAAAAAAAAAOCzEAEAAAAA\
    AAAAAAAAADBAAAAAAAAAAAAAAAAAGCAAAAAAAAAAAAAAAAADBAAAAAAAAAAAAAAAgAECAAAAAAAAAAAAAADAAAEAAAAAAAAAAAAAABggAAAAAAAAAAAA\
    AAAADBAAAAAAAAAAAAAAAIABQgQAAAAAAAAAAAAAAMAAAQAAAAAAAAAAAAAAYIAAAAAAAAAAAAAAAAAMEAAAAAAAAAAAAAAAAAYIAAAAAAAAAAAAAAAA\
    AwQAAAAAAAAAAAAAAGCAAAAAAAAAAAAAAAAAuLTOw50k/e4TXAAAAABJRU5ErkJggg==
    """)!

/// Calls `tool` on a server whose app returns a session that holds one completed screenshot artifact at `path`.
/// The artifact ID equals the request ID, as it does for a new screenshot.
private func toolResult(_ tool: String, artifactAt path: String) throws -> [String: JSONValue] {
    let display = CaptureTarget(token: "display", kind: .display, name: "Test", widthPoints: 100, heightPoints: 100, pixelScale: 1)
    var session = CaptureSession(source: display, selection: CaptureSelection(target: display.token))
    let requestID = UUID()
    var artifact = CaptureArtifact(id: requestID, kind: .screenshot, state: .completed)
    artifact.path = path
    session.artifacts = [artifact]
    let captured = try JSONValue.encode(session)
    let server = try initializedServer { .success($0.id, captured) }
    let selector = tool == "screenshot" ? #""target":"display""# : #""sessionID":"\#(session.id.uuidString)""#
    let response = try rpc(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(tool)","arguments":{\#(selector),"requestID":"\#(requestID.uuidString)"}}}"#)
    guard case .object(let result) = response["result"] else { throw AgentFailure(.internalError, "Missing tool result") }
    #expect(result["isError"] == .bool(false))
    return result
}

private func blocks(_ result: [String: JSONValue]) -> [[String: JSONValue]] {
    guard case .array(let content) = result["content"] else { return [] }
    return content.compactMap { if case .object(let block) = $0 { block } else { nil } }
}

private func pixelSize(_ png: Data) -> [Int] {
    let bytes = [UInt8](png)
    guard bytes.count >= 24 else { return [] }
    return [16, 20].map { offset in bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
}

@Test func screenshotResultCarriesTextThenImage() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("capture.png")
    try smallPNG.write(to: file)
    let result = try toolResult("screenshot", artifactAt: file.path)
    let content = blocks(result)
    guard content.count == 2, case .string(let text) = content[0]["text"] else { Issue.record("Expected a text block and an image block"); return }
    #expect(content[0]["type"] == .string("text"))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == result["structuredContent"])
    #expect(content[1] == ["type": .string("image"), "data": .string(smallPNG.base64EncodedString()), "mimeType": .string("image/png")])
}

@Test(arguments: [false, true])
func screenshotResultWithoutReadablePNGCarriesTextOnly(fileExists: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("capture.png")
    if fileExists { try Data("not a PNG".utf8).write(to: file) }
    let content = blocks(try toolResult("screenshot", artifactAt: file.path))
    #expect(content.map { $0["type"] } == [.string("text")])
}

@Test func otherToolResultCarriesTextOnly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("capture.png")
    try smallPNG.write(to: file)
    let content = blocks(try toolResult("artifacts_list", artifactAt: file.path))
    #expect(content.map { $0["type"] } == [.string("text")])
}

@Test func largeScreenshotIsScaledInTheImageBlockOnly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("capture.png")
    try widePNG.write(to: file)
    let content = blocks(try toolResult("screenshot", artifactAt: file.path))
    guard content.count == 2, case .string(let encoded) = content[1]["data"], let image = Data(base64Encoded: encoded) else {
        Issue.record("Expected an image block"); return
    }
    #if canImport(ImageIO)
    #expect(pixelSize(image) == [1568, 8])
    #else
    #expect(image == widePNG)
    #endif
    #expect(try Data(contentsOf: file) == widePNG)
}
