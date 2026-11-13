import Foundation
import Testing
@testable import ShareXAgent

@Test func cliPreservesSelectionAndRetryID() throws {
    let id = UUID(), session = UUID()
    let invocation = try AgentCLI.parse(["screenshot", "--target", "window token", "--region", "1,2,30,40", "--session", session.uuidString,
                                         "--include-cursor", "--request-id", id.uuidString])
    guard case .request(let request) = invocation else { Issue.record("Expected a request"); return }
    #expect(request.id == id)
    #expect(try OperationCatalog.validate(request) == .screenshot(CaptureSelection(target: "window token", region: CaptureRegion(x: 1, y: 2, width: 30, height: 40), includeCursor: true), sessionID: session))
}

@Test func cliUsesCatalogForAllOperations() throws {
    let session = UUID().uuidString
    let commands: [(AgentOperation, [String])] = [(.capabilities, ["capabilities"]), (.targetsList, ["targets", "list"]),
        (.screenshot, ["screenshot", "--target", "display"]), (.recordingStart, ["recording", "start", "--target", "display", "--duration", "3.5", "--fps", "12", "--max-bytes", "1048576"]),
        (.recordingStatus, ["recording", "status", "--session", session]), (.recordingStop, ["recording", "stop", "--session", session]),
        (.sessionMark, ["session", "mark", "--session", session, "--label", "Step passed", "--outcome", "passed"]),
        (.artifactsList, ["artifacts", "list", "--session", session])]
    for (operation, arguments) in commands {
        let id = UUID()
        guard case .request(let request) = try AgentCLI.parse(arguments + ["--request-id", id.uuidString]) else { Issue.record("Expected request"); continue }
        #expect(request.operation == operation)
        #expect(request.id == id)
    }
}

@Test func cliRejectsIgnoredDuplicateAndInvalidArguments() {
    let cases = [["capabilities", "--target", "a"], ["mcp", "ignored"], ["targets", "list", "extra"],
        ["screenshot", "--target", "a", "--target", "b"], ["screenshot", "--target"],
        ["screenshot", "--target", "a", "--include-cursor", "false"], ["screenshot", "--target", "a", "--region", "0,0,1,NaN"],
        ["screenshot", "--target", "a", "--region", "0,0,1,2,garbage"],
        ["recording", "start", "--target", "a", "--fps", "2.5"], ["recording", "start", "--target", "a", "--duration", "inf"],
        ["recording", "stop", "--session", "invalid"], ["capabilities", "--request-id", "invalid"], ["unknown"]]
    for arguments in cases {
        #expect(throws: AgentFailure.self) {
            if case .request(let request) = try AgentCLI.parse(arguments) {
                _ = try OperationCatalog.validate(request)
            }
        }
    }
}

@Test func cliExitCodesIdentifySetupAndUsage() {
    #expect(AgentCLI.exitCode(for: nil) == 0)
    for (code, exit): (AgentErrorCode, Int32) in [(.captureFailed, 1), (.invalidRequest, 2), (.disabled, 3), (.permissionDenied, 3), (.busy, 4), (.startupTimeout, 5)] {
        #expect(AgentCLI.exitCode(for: AgentFailure(code, "test")) == exit)
    }
}

func rpc(_ server: MCPServer, _ text: String) throws -> [String: JSONValue] {
    let value = try #require(server.handle(Data(text.utf8)))
    guard case .object(let response) = value else { throw AgentFailure(.internalError, "Expected object") }
    return response
}

func initializedServer(request: @escaping MCPServer.Requester = { .success($0.id, .object([:])) }) throws -> MCPServer {
    let server = MCPServer(request: request)
    let response = try rpc(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
    guard case .object(let result) = response["result"] else { throw AgentFailure(.internalError, "Initialization failed") }
    #expect(result["protocolVersion"] == .string("2025-11-25"))
    #expect(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
    return server
}

@Test func mcpListsSharedCatalogAndExplicitRetryArgument() throws {
    let server = try initializedServer()
    let response = try rpc(server, #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#)
    guard case .object(let result) = response["result"], case .array(let tools) = result["tools"] else { Issue.record("Missing tools"); return }
    #expect(tools.count == 8)
    for (tool, definition) in zip(tools, OperationCatalog.definitions) {
        guard case .object(let fields) = tool, case .object(let schema) = fields["inputSchema"], case .object(let properties) = schema["properties"] else { Issue.record("Missing schema"); continue }
        #expect(fields["name"] == .string(definition.operation.rawValue))
        #expect(properties["requestID"] != nil)
    }
}

@Test func mcpReturnsStructuredEnvelopeAndRoutesRetryID() throws {
    let id = UUID()
    var received: AgentRequest?
    let server = try initializedServer { request in
        received = request
        return .failure(request.id, AgentFailure(.disabled, "Enable local agent access."))
    }
    let response = try rpc(server, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{\"target\":\"display\",\"requestID\":\"\(id.uuidString)\"}}}")
    #expect(received?.id == id)
    #expect(received?.arguments == ["target": .string("display")])
    guard case .object(let result) = response["result"], let structured = result["structuredContent"], case .array(let content) = result["content"],
          case .object(let block) = content.first, case .string(let text) = block["text"] else { Issue.record("Missing result envelope"); return }
    #expect(result["isError"] == .bool(true))
    #expect(try structured.decode(AgentResponse.self).id == id)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == structured)
}

@Test func mcpRejectsMalformedInputAndKeepsSessionUsable() throws {
    let server = try initializedServer { _ in Issue.record("Invalid command reached service"); throw AgentFailure(.internalError, "unexpected") }
    for line in ["{", "[]", #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#,
                 #"{"jsonrpc":"2.0","id":2.5,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":[]}}"#,
                 #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{"requestID":7}}}"#] {
        #expect(try rpc(server, line)["error"] != nil)
    }
    let invalid = try rpc(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}"#)
    guard case .object(let result) = invalid["result"] else { Issue.record("Expected tool error"); return }
    #expect(result["isError"] == .bool(true))
    #expect(try rpc(server, #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)["result"] == .object([:]))
}

@Test func mcpRequiresInitializationButAlwaysRespondsToPing() throws {
    let server = MCPServer { .success($0.id, .null) }
    #expect(try rpc(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["error"] != nil)
    #expect(try rpc(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)["result"] == .object([:]))
}

@Test func mcpDrainsOversizedLinesWithoutLosingNextMessage() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputURL = directory.appendingPathComponent("input"), outputURL = directory.appendingPathComponent("output")
    try Data((String(repeating: "x", count: 70_000) + "\n" + #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n").utf8).write(to: inputURL)
    try Data().write(to: outputURL)
    let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
    defer { try? input.close(); try? output.close() }
    try MCPServer { .success($0.id, .null) }.run(input: input, output: output)
    let lines = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let last = try JSONDecoder().decode(JSONValue.self, from: Data(lines[1].utf8))
    #expect(last == .object(["jsonrpc": .string("2.0"), "id": .number(7), "result": .object([:])]))
}

func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("sharex-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}
