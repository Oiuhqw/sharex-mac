import Foundation
import Testing
@testable import ShareXAgent
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized)
struct TransportTests {
    @Test func socketRoundTripAndExclusiveOwnership() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { request in .success(request.id, .object(["operation": .string(request.operation.rawValue)])) }
        defer { server.stop() }
        let request = AgentRequest(operation: .capabilities)
        #expect(try LocalAgentClient(endpoint: endpoint).send(request) == .success(request.id, .object(["operation": .string("capabilities")])))
        #expect(throws: AgentFailure.self) { try LocalAgentServer(endpoint: endpoint) { .success($0.id, .null) } }
        #expect(try LocalAgentClient(endpoint: endpoint).send(request).ok)
        let info = try endpoint.socketInfo()
        #expect(info.st_mode & 0o777 == 0o600)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: endpoint.socketPath))
        let replacement = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { replacement.stop() }
        #expect(try LocalAgentClient(endpoint: endpoint).send(request).ok)
    }

    @Test func socketRejectsUnsafeDirectorySymlinkAndEndpoint() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: root)
        #expect(throws: AgentFailure.self) { try LocalAgentServer(endpoint: AgentEndpoint(directory: bad.path)) { .success($0.id, .null) } }
        #expect(chmod(root.path, 0o755) == 0)
        #expect(throws: AgentFailure.self) { try LocalAgentServer(endpoint: AgentEndpoint(directory: root.path)) { .success($0.id, .null) } }
        #expect(chmod(root.path, 0o700) == 0)
        let endpoint = AgentEndpoint(directory: root.path)
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: endpoint.socketPath))
        #expect(throws: AgentFailure.self) { try LocalAgentServer(endpoint: endpoint) { .success($0.id, .null) } }
        #expect(try String(contentsOfFile: endpoint.socketPath, encoding: .utf8) == "keep me")
    }

    #if os(Linux)
    @Test func inheritedDescriptorDoesNotRetainStoppedServerOwnership() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
        let owner = try #require(descriptors.first {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + $0)) == root.appendingPathComponent("owner.lock").path
        }.flatMap(Int32.init))
        let inherited = dup(owner)
        #expect(inherited >= 0)
        defer { close(inherited) }
        server.stop()
        let replacement = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { replacement.stop() }
        #expect(try LocalAgentClient(endpoint: endpoint).send(AgentRequest(operation: .capabilities)).ok)
    }
    #endif

    @Test func socketRejectsSymlinkOwnershipLock() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("preserve")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("owner.lock"), withDestinationURL: target)
        #expect(throws: AgentFailure.self) { try LocalAgentServer(endpoint: AgentEndpoint(directory: root.path)) { .success($0.id, .null) } }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
    }

    @Test func clientDeadlineDoesNotCancelAppOwnedWork() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let completed = DispatchSemaphore(value: 0)
        let server = try LocalAgentServer(endpoint: endpoint) { request in
            try? await Task.sleep(for: .milliseconds(150))
            completed.signal()
            return .success(request.id, .object([:]))
        }
        defer { server.stop() }
        #expect(throws: AgentFailure.self) { try LocalAgentClient(endpoint: endpoint, timeout: 0.03).send(AgentRequest(operation: .capabilities)) }
        #expect(completed.wait(timeout: .now() + 2) == .success)
    }

    @Test(arguments: [["screenshot"], ["recording", "start", "--target", "window", "--duration", "7201"],
                      ["recording", "start", "--target", "window", "--fps", "2.5"],
                      ["capabilities", "--target", "window"], ["recording", "stop", "--session", "invalid"]])
    func runnerReturnsCorrelatedJSONFailureAndDoesNotLaunchForInvalidUsage(arguments: [String]) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("stdout"), errorURL = root.appendingPathComponent("stderr")
        try Data().write(to: outputURL); try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let requestID = UUID()
        let code = AgentCommandRunner.run(arguments + ["--request-id", requestID.uuidString],
                                          launch: { Issue.record("Invalid CLI started app") }, output: output, errors: errors)
        #expect(code == 2)
        let response = try JSONDecoder().decode(AgentResponse.self, from: Data(contentsOf: outputURL))
        #expect(response.error?.code == .invalidRequest)
        #expect(response.id == requestID)
        #expect(!(try Data(contentsOf: errorURL)).isEmpty)
    }

    @Test func malformedFramesCloseWithoutDamagingTheListener() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        for bytes: [UInt8] in [[0, 0, 0, 0], [255, 255, 255, 255], [0, 0, 0, 1, 123]] {
            let descriptor = try rawConnection(endpoint)
            defer { close(descriptor) }
            #expect(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count)
            var byte: UInt8 = 0
            #expect(read(descriptor, &byte, 1) == 0)
        }
        #expect(try LocalAgentClient(endpoint: endpoint).send(AgentRequest(operation: .capabilities)).ok)
    }

    @Test func framesNestedBeyondLimitCloseWithoutReplyAndTheListenerKeepsServing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        let utf16 = try #require(nestedRequest(key: #"a\""#, depth: 400).data(using: .utf16LittleEndian))
        for body in [Data(nestedRequest(depth: 33).utf8), Data(nestedRequest(depth: 400).utf8), utf16] {
            try expectClosedWithoutReply(body, endpoint)
        }
    }

    @Test func framesWithMalformedObjectKeysCloseWithoutReplyAndTheListenerKeepsServing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        try expectClosedWithoutReply(Data(#"{"\q":1}"#.utf8), endpoint)
        for key in malformedKeys {
            try expectClosedWithoutReply(Data(#"{"version":1,"id":"\#(UUID().uuidString)","operation":"capabilities","arguments":{""#.utf8) + key + Data(#"":1}}"#.utf8), endpoint)
        }
    }

    @Test func frameNestedToLimitGetsAReply() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        let descriptor = try rawConnection(endpoint)
        defer { close(descriptor) }
        let bytes = frame(Data(nestedRequest(depth: 32).utf8))
        #expect(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count)
        let reply = readToEnd(descriptor)
        let response = try JSONDecoder().decode(AgentResponse.self, from: Data(reply.dropFirst(4)))
        #expect(response.error?.code == .invalidRequest)
    }

    @Test func socketBoundsConcurrentIncompleteRequests() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for _ in 0..<8 { descriptors.append(try rawConnection(endpoint)) }
        #expect(throws: AgentFailure.self) { try LocalAgentClient(endpoint: endpoint, timeout: 1).send(AgentRequest(operation: .capabilities)) }
        descriptors.forEach { close($0) }
        descriptors = []
        var available = false
        for _ in 0..<20 {
            if (try? LocalAgentClient(endpoint: endpoint, timeout: 0.2).send(AgentRequest(operation: .capabilities))) != nil { available = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(available)
    }

    @Test func incompleteRequestHasFiniteReadDeadline() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AgentEndpoint(directory: root.path)
        let server = try LocalAgentServer(endpoint: endpoint) { .success($0.id, .object([:])) }
        defer { server.stop() }
        let descriptor = try rawConnection(endpoint, receiveTimeout: 7)
        defer { close(descriptor) }
        var byte: UInt8 = 0
        #expect(write(descriptor, &byte, 1) == 1)
        #expect(read(descriptor, &byte, 1) == 0)
        #expect(try LocalAgentClient(endpoint: endpoint).send(AgentRequest(operation: .capabilities)).ok)
    }
}

private func nestedRequest(key: String = "a", depth: Int) -> String {
    #"{"version":1,"id":"\#(UUID().uuidString)","operation":"capabilities","arguments":{"\#(key)":\#(nestedArrays(depth - 2))}}"#
}

private func frame(_ body: Data) -> [UInt8] {
    withUnsafeBytes(of: UInt32(body.count).bigEndian) { Array($0) } + body
}

private func expectClosedWithoutReply(_ body: Data, _ endpoint: AgentEndpoint) throws {
    let descriptor = try rawConnection(endpoint)
    defer { close(descriptor) }
    let bytes = frame(body)
    #expect(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count)
    var byte: UInt8 = 0
    #expect(read(descriptor, &byte, 1) == 0)
    #expect(try LocalAgentClient(endpoint: endpoint).send(AgentRequest(operation: .capabilities)).ok)
}

private func readToEnd(_ descriptor: Int32) -> [UInt8] {
    var reply: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return reply }
        reply.append(contentsOf: chunk[..<count])
    }
}

private func rawConnection(_ endpoint: AgentEndpoint, receiveTimeout: Int = 2) throws -> Int32 {
    #if canImport(Darwin)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw AgentFailure(.internalError, "Cannot create raw test socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let bytes = Array(endpoint.socketPath.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); throw AgentFailure(.internalError, "Test socket path is too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { close(descriptor); throw AgentFailure(.internalError, "Cannot connect raw test socket") }
    var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
    #expect(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
    return descriptor
}
