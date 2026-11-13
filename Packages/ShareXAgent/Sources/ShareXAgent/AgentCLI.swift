import Foundation

public enum AgentInvocation: Equatable, Sendable {
    case request(AgentRequest), mcp, help
}

public enum AgentCLI {
    public static let help = """
    ShareX local capture
      sharex capabilities
      sharex targets list
      sharex screenshot --target TOKEN [--region X,Y,WIDTH,HEIGHT] [--session UUID]
      sharex recording start --target TOKEN [--duration SECONDS] [--fps N] [--max-bytes N]
      sharex recording status --session UUID
      sharex recording stop --session UUID
      sharex session mark --session UUID --label TEXT [--outcome passed|failed|unknown]
      sharex artifacts list --session UUID
      sharex mcp
    Capture commands accept --include-cursor. Every operation accepts --request-id UUID.
    stdout contains JSON. Enable local agent access in ShareX Settings > Agents first.
    """

    public static func parse(_ arguments: [String]) throws -> AgentInvocation {
        if arguments == ["--help"] || arguments == ["help"] || arguments.isEmpty { return .help }
        if arguments == ["mcp"] { return .mcp }
        var words = arguments
        let first = words.removeFirst()
        let operation: AgentOperation
        if ["targets", "recording", "session", "artifacts"].contains(first) {
            guard !words.isEmpty, let value = AgentOperation(rawValue: first + "." + words.removeFirst()) else {
                throw AgentFailure(.invalidRequest, "Unknown command. Run sharex --help.")
            }
            operation = value
        } else if let value = AgentOperation(rawValue: first), !first.contains(".") {
            operation = value
        } else { throw AgentFailure(.invalidRequest, "Unknown command. Run sharex --help.") }
        let names = ["--target": "target", "--region": "region", "--session": "sessionID", "--duration": "maxDurationSeconds",
                     "--fps": "fps", "--max-bytes": "maxBytes", "--label": "label", "--outcome": "outcome", "--include-cursor": "includeCursor"]
        var fields: [String: JSONValue] = [:]
        var requestID = UUID()
        var seen = Set<String>()
        while !words.isEmpty {
            let flag = words.removeFirst()
            guard seen.insert(flag).inserted else { throw AgentFailure(.invalidRequest, "Duplicate option \(flag).") }
            if flag == "--include-cursor" { fields["includeCursor"] = .bool(true); continue }
            guard flag == "--request-id" || names[flag] != nil else { throw AgentFailure(.invalidRequest, "Unknown option \(flag).") }
            guard !words.isEmpty else { throw AgentFailure(.invalidRequest, "\(flag) requires a value.") }
            let value = words.removeFirst()
            if flag == "--request-id" {
                guard let id = UUID(uuidString: value) else { throw AgentFailure(.invalidRequest, "--request-id must be a UUID.") }
                requestID = id
            } else if flag == "--region" {
                let components = value.split(separator: ",", omittingEmptySubsequences: false)
                let parts = components.compactMap { Double($0) }
                guard components.count == 4, parts.count == 4, parts.allSatisfy(\.isFinite) else {
                    throw AgentFailure(.invalidRequest, "--region must contain four finite numbers, X,Y,WIDTH,HEIGHT.")
                }
                fields["region"] = .object(Dictionary(uniqueKeysWithValues: zip(["x", "y", "width", "height"], parts.map(JSONValue.number))))
            } else if ["--duration", "--fps", "--max-bytes"].contains(flag) {
                guard let number = Double(value), number.isFinite else { throw AgentFailure(.invalidRequest, "\(flag) must be a finite number.") }
                fields[names[flag]!] = .number(number)
            } else { fields[names[flag]!] = .string(value) }
        }
        return .request(AgentRequest(id: requestID, operation: operation, arguments: fields))
    }

    public static func exitCode(for failure: AgentFailure?) -> Int32 {
        guard let failure else { return 0 }
        switch failure.code {
        case .invalidRequest, .unsupportedVersion: return 2
        case .disabled, .permissionDenied: return 3
        case .busy: return 4
        case .startupTimeout: return 5
        default: return 1
        }
    }
}
