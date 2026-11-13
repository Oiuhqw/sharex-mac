import Foundation
import Testing
@testable import ShareXAgent

@Test func cliAndMCPProcessesUseTheSameSocketService() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try testHostExecutable()
    let endpoint = root.appendingPathComponent("endpoint")
    let host = Process(), ready = Pipe(), hostErrors = Pipe()
    host.executableURL = executable
    host.arguments = ["--serve"]
    host.environment = ProcessInfo.processInfo.environment.merging(["SHAREX_TEST_ENDPOINT": endpoint.path]) { _, new in new }
    host.standardOutput = ready
    host.standardError = hostErrors
    try host.run()
    defer { if host.isRunning { host.terminate() }; host.waitUntilExit() }
    #expect(try ready.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
    let wrapper = try AgentInstallation.install(executable: executable, home: root)
    let retryID = UUID()
    let cli = try runProcess(wrapper, arguments: ["screenshot", "--target", "Window With Spaces", "--request-id", retryID.uuidString], environment: host.environment!)
    #expect(cli.status == 0)
    #expect(cli.errors.isEmpty)
    let response = try JSONDecoder().decode(AgentResponse.self, from: cli.output)
    #expect(response.id == retryID)
    #expect(response.result == .object(["operation": .string("screenshot"), "arguments": .object(["target": .string("Window With Spaces")])]))
    let lines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"process-test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{\"target\":\"Window With Spaces\",\"requestID\":\"\(retryID.uuidString)\"}}}"]
    let mcp = try runProcess(wrapper, arguments: ["mcp"], environment: host.environment!, input: Data((lines.joined(separator: "\n") + "\n").utf8))
    #expect(mcp.status == 0)
    #expect(mcp.errors.isEmpty)
    let messages = try String(decoding: mcp.output, as: UTF8.self).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(messages.count == 3)
    guard case .object(let call) = messages.last, case .object(let result) = call["result"], let structured = result["structuredContent"] else {
        Issue.record("Missing MCP result"); return
    }
    #expect(try structured.decode(AgentResponse.self) == response)
    let again = try runProcess(wrapper, arguments: ["targets", "list"], environment: host.environment!)
    #expect(again.status == 0)
    #expect(try JSONDecoder().decode(AgentResponse.self, from: again.output).ok)
    host.terminate()
    host.waitUntilExit()
    let replacement = try LocalAgentServer(endpoint: AgentEndpoint(directory: endpoint.path)) { .success($0.id, .object([:])) }
    defer { replacement.stop() }
    #expect(try LocalAgentClient(endpoint: AgentEndpoint(directory: endpoint.path)).send(AgentRequest(operation: .capabilities)).ok)
}

private func testHostExecutable() throws -> URL {
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<5 {
        let executable = directory.appendingPathComponent("ShareXAgentTestHost")
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        directory.deleteLastPathComponent()
    }
    throw AgentFailure(.internalError, "Build the ShareXAgentTestHost test dependency before running process integration tests.")
}

private func runProcess(_ executable: URL, arguments: [String], environment: [String: String], input: Data = Data()) throws -> (status: Int32, output: Data, errors: Data) {
    let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output, errors)
}
