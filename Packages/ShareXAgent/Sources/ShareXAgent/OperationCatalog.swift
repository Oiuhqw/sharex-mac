import Foundation

public struct OperationDefinition: Codable, Sendable {
    public let operation: AgentOperation
    public let description: String
    public let inputSchema: JSONValue
}

public enum OperationCatalog {
    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func number(_ minimum: Double, _ maximum: Double, integer: Bool = false) -> JSONValue {
        .object(["type": .string(integer ? "integer" : "number"), "minimum": .number(minimum), "maximum": .number(maximum)])
    }
    private static let selectionProperties: [String: JSONValue] = [
        "target": string("Opaque target token from targets.list."),
        "includeCursor": .object(["type": .string("boolean"), "default": .bool(false)]),
        "region": .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "description": .string("Rectangle in top-left display-local logical points. Display targets only."),
            "required": .array(["x", "y", "width", "height"].map(JSONValue.string)),
            "properties": .object(["x": number(0, 100_000), "y": number(0, 100_000),
                                    "width": number(1, 100_000), "height": number(1, 100_000)])
        ])
    ]
    private static let sessionProperties = ["sessionID": string("Session UUID returned by screenshot or recording.start.")]

    public static let definitions: [OperationDefinition] = AgentOperation.allCases.map { operation in
        let description: String
        var properties: [String: JSONValue] = [:]
        let required: [String]
        switch operation {
        case .capabilities:
            description = "Read agent access, capture permission, operations, and resource limits without prompting."
            required = []
        case .targetsList:
            description = "List current display and window target tokens. Tokens expire when the app restarts or the target changes."
            required = []
        case .screenshot:
            description = "Save a PNG of a display, window, or display region. Optional sessionID adds a checkpoint to a session."
            properties = selectionProperties.merging(sessionProperties) { first, _ in first }; required = ["target"]
        case .recordingStart:
            description = "Start silent H.264 MP4 recording. Returns after the writer accepts the first complete frame."
            properties = selectionProperties.merging([
                "fps": number(1, 60, integer: true), "maxDurationSeconds": number(1, 7200),
                "maxBytes": number(1_048_576, 2_147_483_648, integer: true)
            ]) { first, _ in first }; required = ["target"]
        case .recordingStatus:
            description = "Read recording state, accepted and dropped frames, artifacts, and failure details."
            properties = sessionProperties; required = ["sessionID"]
        case .recordingStop:
            description = "Stop and finalize a recording. Completion requires a readable video and a committed manifest."
            properties = sessionProperties; required = ["sessionID"]
        case .sessionMark:
            description = "Append a named step or reported test outcome. Test outcome does not change capture completion."
            properties = sessionProperties.merging([
                "label": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(512)]),
                "outcome": .object(["type": .string("string"), "enum": .array(["passed", "failed", "unknown"].map(JSONValue.string))])
            ]) { first, _ in first }; required = ["sessionID", "label"]
        case .artifactsList:
            description = "Read the session manifest and completed artifact paths, dimensions, sizes, and SHA-256 hashes."
            properties = sessionProperties; required = ["sessionID"]
        }
        return OperationDefinition(operation: operation, description: description, inputSchema: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(properties), "required": .array(required.map(JSONValue.string))
        ]))
    }

    public static func definition(for operation: AgentOperation) -> OperationDefinition {
        definitions.first { $0.operation == operation }!
    }

    public static func validate(_ request: AgentRequest) throws -> AgentCommand {
        guard request.version == 1 else { throw AgentFailure(.unsupportedVersion, "Use protocol version 1.") }
        guard try request.canonicalData().count <= CaptureLimits().maxRequestBytes else {
            throw AgentFailure(.invalidRequest, "The request exceeds 65536 bytes.")
        }
        try validateValue(.object(request.arguments), schema: definition(for: request.operation).inputSchema, path: "arguments")
        let args = request.arguments
        func text(_ key: String) throws -> String {
            guard case .string(let value) = args[key], !value.isEmpty, value.utf8.count <= 512 else {
                throw AgentFailure(.invalidRequest, "\(key) must be a nonempty string of at most 512 bytes.")
            }
            return value
        }
        func sessionID() throws -> UUID {
            guard let id = UUID(uuidString: try text("sessionID")) else {
                throw AgentFailure(.invalidRequest, "sessionID must be a UUID.")
            }
            return id
        }
        func selection() throws -> CaptureSelection {
            var region: CaptureRegion?
            if let value = args["region"] { region = try value.decode(CaptureRegion.self) }
            let cursor = args["includeCursor"] == .bool(true)
            return CaptureSelection(target: try text("target"), region: region, includeCursor: cursor)
        }
        func numeric(_ key: String, default fallback: Double) -> Double {
            if case .number(let value) = args[key] { value } else { fallback }
        }
        switch request.operation {
        case .capabilities: return .capabilities
        case .targetsList: return .targetsList
        case .screenshot: return .screenshot(try selection(), sessionID: args["sessionID"] == nil ? nil : try sessionID())
        case .recordingStart:
            return .recordingStart(try selection(), RecordingOptions(fps: Int(numeric("fps", default: 30)),
                maxDurationSeconds: numeric("maxDurationSeconds", default: 1800), maxBytes: Int64(numeric("maxBytes", default: 2_147_483_648))))
        case .recordingStatus: return .recordingStatus(try sessionID())
        case .recordingStop: return .recordingStop(try sessionID())
        case .sessionMark:
            let outcome = try args["outcome"].map { _ in TestOutcome(rawValue: try text("outcome"))! }
            return .sessionMark(try sessionID(), label: try text("label"), outcome: outcome)
        case .artifactsList: return .artifactsList(try sessionID())
        }
    }

    private static func validateValue(_ value: JSONValue, schema: JSONValue, path: String) throws {
        guard case .object(let rules) = schema, case .string(let type) = rules["type"] else { return }
        func invalid(_ reason: String) -> AgentFailure { AgentFailure(.invalidRequest, "\(path) \(reason).") }
        switch (type, value) {
        case ("object", .object(let object)):
            guard case .object(let properties) = rules["properties"] else { return }
            if case .array(let required) = rules["required"] {
                for case .string(let key) in required where object[key] == nil { throw invalid("requires \(key)") }
            }
            for (key, child) in object {
                guard let childSchema = properties[key] else { throw invalid("contains unknown field \(key)") }
                try validateValue(child, schema: childSchema, path: "\(path).\(key)")
            }
        case ("number", .number(let number)), ("integer", .number(let number)):
            guard number.isFinite else { throw invalid("must be finite") }
            if type == "integer", number.rounded() != number { throw invalid("must be an integer") }
            if case .number(let minimum) = rules["minimum"], number < minimum { throw invalid("must be at least \(minimum)") }
            if case .number(let maximum) = rules["maximum"], number > maximum { throw invalid("must be at most \(maximum)") }
        case ("string", .string(let text)):
            if case .array(let values) = rules["enum"], !values.contains(value) { throw invalid("has an unsupported value") }
            if case .number(let minimum) = rules["minLength"], Double(text.count) < minimum { throw invalid("is too short") }
            if case .number(let maximum) = rules["maxLength"], Double(text.count) > maximum { throw invalid("is too long") }
        case ("boolean", .bool): break
        default: throw invalid("must have type \(type)")
        }
    }
}
