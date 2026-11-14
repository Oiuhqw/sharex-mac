import Foundation

public enum RequestReplayPolicy {
    public static let recordLifetime: TimeInterval = 7 * 86_400

    /// The existing session in which a command writes an artifact or a marker under its request ID.
    public static func targetSession(of command: AgentCommand) -> UUID? {
        switch command {
        case .screenshot(_, let sessionID): return sessionID
        case .sessionMark(let sessionID, _, _): return sessionID
        case .capabilities, .targetsList, .recordingStart, .recordingStatus, .recordingStop, .artifactsList: return nil
        }
    }

    /// A success is always replayed. A failure is replayed only when the request left durable state under its own ID.
    /// - Parameters:
    ///   - requestSessionExists: A session folder with the request ID as its name is on disk.
    ///   - targetSession: The manifest of `targetSession(of:)`, when it loads.
    public static func keepsResponse(_ response: AgentResponse, to command: AgentCommand,
                                     requestSessionExists: Bool, targetSession: CaptureSession?) -> Bool {
        if response.ok { return true }
        switch command {
        case .recordingStart: return requestSessionExists
        case .screenshot(_, let sessionID):
            guard sessionID != nil else { return requestSessionExists }
            return targetSession?.artifacts.contains(where: { $0.id == response.id }) ?? false
        case .sessionMark:
            return targetSession?.markers.contains(where: { $0.id == response.id }) ?? false
        // A stop writes nothing under its own ID. A repeated stop only reads the session.
        case .recordingStop: return false
        case .capabilities, .targetsList, .recordingStatus, .artifactsList: return false
        }
    }

    public static func recordExpired(modifiedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(modifiedAt) > recordLifetime
    }
}
