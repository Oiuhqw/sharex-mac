import Foundation

public final class MCPServer {
    public typealias Requester = (AgentRequest) throws -> AgentResponse
    private enum Phase { case new, initialized, ready }
    private var phase = Phase.new
    private let request: Requester
    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public init(request: @escaping Requester) { self.request = request }

    public static var tools: [JSONValue] {
        OperationCatalog.definitions.map { definition in
            var schema = definition.inputSchema
            if case .object(var object) = schema, case .object(var properties) = object["properties"] {
                properties["requestID"] = .object(["type": .string("string"), "format": .string("uuid"),
                    "description": .string("Optional retry UUID. Reuse this value with identical arguments after a timeout. Save it before capture starts.")])
                object["properties"] = .object(properties)
                schema = .object(object)
            }
            return .object(["name": .string(definition.operation.rawValue), "description": .string(definition.description),
                "inputSchema": schema, "annotations": .object(["readOnlyHint": .bool(!definition.operation.mutates),
                    "destructiveHint": .bool(false), "idempotentHint": .bool(!definition.operation.mutates), "openWorldHint": .bool(false)])])
        }
    }

    public func handle(_ data: Data) -> JSONValue? {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { return rpcError(.null, -32700, "Invalid JSON.") }
        guard case .object(let object) = value, object["jsonrpc"] == .string("2.0"), case .string(let method) = object["method"] else {
            return rpcError(.null, -32600, "Expected a JSON-RPC 2.0 request.")
        }
        let id = object["id"]
        if let id, !validID(id) { return rpcError(.null, -32600, "Request id must be a string or integer.") }
        if id == nil {
            if method == "notifications/initialized", phase == .initialized { phase = .ready }
            return nil
        }
        let requestID = id!
        let params: [String: JSONValue]
        if let value = object["params"] {
            guard case .object(let fields) = value else { return rpcError(requestID, -32602, "params must be an object.") }
            params = fields
        } else { params = [:] }
        switch method {
        case "initialize":
            guard phase == .new else { return rpcError(requestID, -32600, "Already initialized.") }
            guard case .string(let version) = params["protocolVersion"], case .object = params["capabilities"],
                  case .object(let clientInfo) = params["clientInfo"], case .string = clientInfo["name"], case .string = clientInfo["version"] else {
                return rpcError(requestID, -32602, "initialize requires protocolVersion, capabilities, and clientInfo.")
            }
            phase = .initialized
            return result(requestID, .object(["protocolVersion": .string(Self.versions.contains(version) ? version : Self.versions[0]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("sharex"), "version": .string("1.0.0")]),
                "instructions": .string("Discover targets before capture. Keep session IDs and requestID values. Recording continues after this connection closes. Call recording_stop to finalize evidence. PNG and MP4 paths are local files.")]))
        case "ping": return result(requestID, .object([:]))
        case "tools/list":
            guard phase == .ready else { return rpcError(requestID, -32000, "Complete initialization first.") }
            guard params["cursor"] == nil else { return rpcError(requestID, -32602, "This tool list has no cursor.") }
            return result(requestID, .object(["tools": .array(Self.tools)]))
        case "tools/call":
            guard phase == .ready else { return rpcError(requestID, -32000, "Complete initialization first.") }
            guard case .string(let name) = params["name"], let operation = AgentOperation(rawValue: name) else {
                return rpcError(requestID, -32602, "Unknown tool name.")
            }
            var arguments: [String: JSONValue] = [:]
            if let value = params["arguments"] {
                guard case .object(let fields) = value else { return rpcError(requestID, -32602, "arguments must be an object.") }
                arguments = fields
            }
            var retryID = UUID()
            if let value = arguments.removeValue(forKey: "requestID") {
                guard case .string(let text) = value, let id = UUID(uuidString: text) else { return rpcError(requestID, -32602, "requestID must be a UUID.") }
                retryID = id
            }
            let command = AgentRequest(id: retryID, operation: operation, arguments: arguments)
            let response: AgentResponse
            do { _ = try OperationCatalog.validate(command); response = try request(command) }
            catch let error as AgentFailure { response = .failure(retryID, error) }
            catch { response = .failure(retryID, AgentFailure(.internalError, error.localizedDescription)) }
            do {
                let structured = try JSONValue.encode(response)
                let text = String(decoding: try JSONEncoder().encode(structured), as: UTF8.self)
                return result(requestID, .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "structuredContent": structured, "isError": .bool(!response.ok)]))
            } catch { return rpcError(requestID, -32603, "Cannot encode capture response.") }
        default: return rpcError(requestID, -32601, "Unknown method.")
        }
    }

    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) throws {
        var line = Data()
        var oversized = false
        while let chunk = try input.read(upToCount: 4096), !chunk.isEmpty {
            for byte in chunk {
                if byte == 10 {
                    let response = oversized ? rpcError(.null, -32600, "Message exceeds 65536 bytes.") : handle(line)
                    if let response { try output.write(contentsOf: JSONEncoder().encode(response) + Data([10])) }
                    line.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    if line.count == CaptureLimits().maxRequestBytes { oversized = true; line.removeAll(keepingCapacity: true) }
                    else { line.append(byte) }
                }
            }
        }
        if oversized || !line.isEmpty {
            try output.write(contentsOf: JSONEncoder().encode(rpcError(.null, -32700, "Input ended before the newline delimiter.")) + Data([10]))
        }
    }

    private func validID(_ value: JSONValue) -> Bool {
        switch value {
        case .string: true
        case .number(let number): number.isFinite && number.rounded() == number && abs(number) <= 9_007_199_254_740_991
        default: false
        }
    }
    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
    private func rpcError(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
