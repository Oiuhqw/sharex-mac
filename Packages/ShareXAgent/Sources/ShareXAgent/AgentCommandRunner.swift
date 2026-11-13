import Foundation

public enum AgentCommandRunner {
    public static func run(_ arguments: [String], launch: @escaping () throws -> Void,
                           endpoint: AgentEndpoint = AgentEndpoint(),
                           input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
                           errors: FileHandle = .standardError) -> Int32 {
        var requestID = UUID()
        do {
            let invocation = try AgentCLI.parse(arguments)
            if invocation == .help {
                try output.write(contentsOf: JSONEncoder().encode(JSONValue.object(["usage": .string(AgentCLI.help)])) + Data([10]))
                return 0
            }
            let client = LocalAgentClient(endpoint: endpoint)
            let requester: MCPServer.Requester = { request in
                try ensureApp(endpoint: endpoint, launch: launch)
                return try client.send(request)
            }
            if case .mcp = invocation {
                try MCPServer(request: requester).run(input: input, output: output)
                return 0
            }
            guard case .request(let request) = invocation else { return 2 }
            requestID = request.id
            _ = try OperationCatalog.validate(request)
            let response = try requester(request)
            try output.write(contentsOf: JSONEncoder().encode(response) + Data([10]))
            return AgentCLI.exitCode(for: response.error)
        } catch {
            let failure = error as? AgentFailure ?? AgentFailure(.internalError, error.localizedDescription)
            try? errors.write(contentsOf: Data((failure.message + "\n").utf8))
            if arguments != ["mcp"] {
                try? output.write(contentsOf: JSONEncoder().encode(AgentResponse.failure(requestID, failure)) + Data([10]))
            }
            return AgentCLI.exitCode(for: failure)
        }
    }

    private static func ensureApp(endpoint: AgentEndpoint, launch: () throws -> Void) throws {
        let client = LocalAgentClient(endpoint: endpoint, timeout: 1)
        func available() throws -> Bool {
            do { _ = try client.send(AgentRequest(operation: .capabilities)); return true }
            catch let failure as AgentFailure where [.storageFailed, .permissionDenied, .invalidRequest].contains(failure.code) { throw failure }
            catch { return false }
        }
        if try available() { return }
        try launch()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            if try available() { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while ContinuousClock.now < deadline
        throw AgentFailure(.startupTimeout, "ShareX did not become available. Open ShareX and check Settings > Agents.")
    }
}
