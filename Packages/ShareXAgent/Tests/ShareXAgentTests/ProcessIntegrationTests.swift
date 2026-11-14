import Foundation
import Testing
@testable import ShareXAgent
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func mcpRespondsWhileItsInputRemainsOpen() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = try testHostExecutable()
    process.arguments = ["--agent", "mcp"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.environment = ProcessInfo.processInfo.environment.merging(["SHAREX_TEST_ENDPOINT": root.path]) { _, new in new }
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"interactive-test","version":"1"}}}"#
    try input.fileHandleForWriting.write(contentsOf: Data((initialize + "\n").utf8))
    let first = try readMessage(output.fileHandleForReading)
    guard case .object(let response) = first else { Issue.record("Expected initialize response"); return }
    #expect(response["id"] == .number(1))
    #expect(response["result"] != nil)
    #expect(process.isRunning)
    try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8) + Data([10]))
    guard case .object(let second) = try readMessage(output.fileHandleForReading) else { Issue.record("Expected ping response"); return }
    #expect(second["id"] == .number(2))
    #expect(process.isRunning)
}

private func readMessage(_ handle: FileHandle) throws -> JSONValue {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var data = Data()
    while ContinuousClock.now < deadline, data.count < 65_536 {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0, errno == EINTR { continue }
        guard ready >= 0 else { throw AgentFailure(.internalError, "Cannot read MCP test response.") }
        if ready == 0 { continue }
        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { break }
        if byte[0] == 10 { return try JSONDecoder().decode(JSONValue.self, from: data) }
        data.append(byte)
    }
    throw AgentFailure(.startupTimeout, "MCP did not reply while stdin remained open.")
}

@Test func atomicFileCreatePreservesAcceptedBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("\(UUID().uuidString).json")
    let accepted = try AgentRequest(operation: .screenshot, arguments: ["target": .string("accepted")]).canonicalData()
    try AtomicFile.create(accepted, at: destination)
    #expect(try Data(contentsOf: destination) == accepted)
    var info = stat()
    #expect(lstat(destination.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(info.st_nlink == 1)
    #expect(throws: AgentFailure.self) { try AtomicFile.create(Data("different request".utf8), at: destination) }
    #expect(try Data(contentsOf: destination) == accepted)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [destination.lastPathComponent])
}

@Test func atomicFileReplaceKeepsTheOldFileIntactForExistingReaders() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("manifest.json")
    let original = Data("original record".utf8), replacement = Data(repeating: 0x62, count: 4096)
    try AtomicFile.create(original, at: destination)
    let reader = try FileHandle(forReadingFrom: destination)
    defer { try? reader.close() }
    try AtomicFile.replace(replacement, at: destination)
    #expect(try Data(contentsOf: destination) == replacement)
    #expect(try reader.readToEnd() == original)
    var info = stat()
    #expect(lstat(destination.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [destination.lastPathComponent])
}

@Test(arguments: [false, true], [false, true])
func atomicFileWriteFailureDoesNotPublish(replacing: Bool, interrupted: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("\(UUID().uuidString).json")
    let original = Data("accepted request".utf8)
    if replacing { try AtomicFile.create(original, at: destination) }
    let result = try runProcess(testHostExecutable(), arguments: ["--atomic-write-failure", replacing ? "replace" : "create",
        destination.path, interrupted ? "interrupt" : "error"], environment: ProcessInfo.processInfo.environment)
    #expect(result.status == (interrupted ? SIGKILL : 0))
    #expect(result.output.isEmpty)
    if replacing { #expect(try Data(contentsOf: destination) == original) }
    else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
    let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent != destination.lastPathComponent }
    if interrupted {
        let partial = try #require(remaining.count == 1 ? remaining.first : nil)
        #expect(partial.pathExtension == "tmp")
        #expect(try Data(contentsOf: partial).count == 512)
        var info = stat()
        #expect(lstat(partial.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    } else {
        #expect(!result.errors.isEmpty)
        #expect(remaining.isEmpty)
    }
}

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

@Test func defaultEndpointIgnoresTheClientTemporaryDirectory() throws {
    let executable = try testHostExecutable()
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = "/tmp/agent-client"
    environment["XDG_RUNTIME_DIR"] = nil
    func helperDirectory() throws -> String {
        let result = try runProcess(executable, arguments: ["--default-endpoint"], environment: environment)
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    #if canImport(Darwin)
    let system = try runProcess(URL(fileURLWithPath: "/usr/bin/getconf"), arguments: ["DARWIN_USER_TEMP_DIR"], environment: environment)
    var userTemporary = String(decoding: system.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    if userTemporary.hasSuffix("/") { userTemporary.removeLast() }
    #expect(userTemporary.hasPrefix("/") && !userTemporary.hasPrefix("/tmp") && !userTemporary.hasPrefix("/private/tmp"))
    #expect(try helperDirectory() == userTemporary + "/sharex-agent")
    #expect(AgentEndpoint().directory == userTemporary + "/sharex-agent")
    #else
    #expect(try helperDirectory() == "/tmp/sharex-agent-\(getuid())")
    environment["XDG_RUNTIME_DIR"] = "/run/user/agent-test"
    #expect(try helperDirectory() == "/run/user/agent-test/sharex-agent")
    #endif
}

private final class TestBundleAnchor: NSObject {}

private func testHostExecutable() throws -> URL {
    var directory = Bundle(for: TestBundleAnchor.self).bundleURL
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
