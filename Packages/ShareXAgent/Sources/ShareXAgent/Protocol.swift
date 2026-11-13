import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public enum AgentOperation: String, Codable, CaseIterable, Sendable {
    case capabilities, targetsList = "targets.list", screenshot
    case recordingStart = "recording.start", recordingStatus = "recording.status", recordingStop = "recording.stop"
    case sessionMark = "session.mark", artifactsList = "artifacts.list"

    public var mutates: Bool {
        switch self {
        case .screenshot, .recordingStart, .recordingStop, .sessionMark: true
        default: false
        }
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let operation: AgentOperation
    public let arguments: [String: JSONValue]

    public init(version: Int = 1, id: UUID = UUID(), operation: AgentOperation, arguments: [String: JSONValue] = [:]) {
        self.version = version; self.id = id; self.operation = operation; self.arguments = arguments
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum AgentErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request", unsupportedVersion = "unsupported_version"
    case disabled, permissionDenied = "permission_denied", busy
    case targetNotFound = "target_not_found", targetChanged = "target_changed"
    case sessionNotFound = "session_not_found", requestConflict = "request_conflict"
    case interrupted, diskFull = "disk_full", limitReached = "limit_reached"
    case captureFailed = "capture_failed", recordingFailed = "recording_failed"
    case startupTimeout = "startup_timeout", storageFailed = "storage_failed", internalError = "internal_error"
}

public struct AgentFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public let code: AgentErrorCode
    public let message: String
    public init(_ code: AgentErrorCode, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let ok: Bool
    public let result: JSONValue?
    public let error: AgentFailure?

    private init(id: UUID, result: JSONValue?, error: AgentFailure?) {
        version = 1; self.id = id; ok = error == nil; self.result = result; self.error = error
    }

    public static func success(_ id: UUID, _ result: JSONValue) -> AgentResponse {
        AgentResponse(id: id, result: result, error: nil)
    }
    public static func failure(_ id: UUID, _ error: AgentFailure) -> AgentResponse {
        AgentResponse(id: id, result: nil, error: error)
    }
}
