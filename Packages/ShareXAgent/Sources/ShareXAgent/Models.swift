import Foundation

public struct CaptureRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum TargetKind: String, Codable, Sendable { case display, window }

public struct CaptureTarget: Codable, Equatable, Sendable {
    public let token: String
    public let kind: TargetKind
    public let name: String
    public let application: String?
    public let widthPoints: Double
    public let heightPoints: Double
    public let pixelScale: Double
    public init(token: String, kind: TargetKind, name: String, application: String? = nil,
                widthPoints: Double, heightPoints: Double, pixelScale: Double) {
        self.token = token; self.kind = kind; self.name = name; self.application = application
        self.widthPoints = widthPoints; self.heightPoints = heightPoints; self.pixelScale = pixelScale
    }
}

public struct CaptureSelection: Codable, Equatable, Sendable {
    public let target: String
    public let region: CaptureRegion?
    public let includeCursor: Bool
    public init(target: String, region: CaptureRegion? = nil, includeCursor: Bool = false) {
        self.target = target; self.region = region; self.includeCursor = includeCursor
    }
}

public struct RecordingOptions: Codable, Equatable, Sendable {
    public let fps: Int
    public let maxDurationSeconds: Double
    public let maxBytes: Int64
    public init(fps: Int = 30, maxDurationSeconds: Double = 1800, maxBytes: Int64 = 2_147_483_648) {
        self.fps = fps; self.maxDurationSeconds = maxDurationSeconds; self.maxBytes = maxBytes
    }
}

public enum RecordingState: String, Codable, Sendable {
    case starting, recording, finalizing, completed, failed, interrupted
    public var isTerminal: Bool { self == .completed || self == .failed || self == .interrupted }
}

public enum ArtifactKind: String, Codable, Sendable { case screenshot, recording }
public enum ArtifactState: String, Codable, Sendable { case pending, completed, failed, interrupted }
public enum TestOutcome: String, Codable, Sendable { case passed, failed, unknown }

public struct CaptureArtifact: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: ArtifactKind
    public var state: ArtifactState
    public var path: String?
    public var widthPixels: Int?
    public var heightPixels: Int?
    public var byteCount: Int64?
    public var sha256: String?
    public var durationSeconds: Double?
    public var failure: AgentFailure?
    public var source: CaptureTarget?
    public var selection: CaptureSelection?
    public let createdAt: Date
    public init(id: UUID = UUID(), kind: ArtifactKind, state: ArtifactState = .pending, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.state = state; self.createdAt = createdAt
    }
}

public struct SessionMarker: Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let label: String
    public let outcome: TestOutcome?
    public init(id: UUID = UUID(), timestamp: Date = Date(), label: String, outcome: TestOutcome? = nil) {
        self.id = id; self.timestamp = timestamp; self.label = label; self.outcome = outcome
    }
}

public struct CaptureSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let source: CaptureTarget
    public let selection: CaptureSelection
    public let options: RecordingOptions?
    public var state: RecordingState
    public var startedAt: Date?
    public var endedAt: Date?
    public var stopReason: String?
    public var failure: AgentFailure?
    public var droppedFrames: Int
    public var acceptedFrames: Int
    public var artifacts: [CaptureArtifact]
    public var markers: [SessionMarker]
    public init(id: UUID = UUID(), source: CaptureTarget, selection: CaptureSelection, options: RecordingOptions? = nil) {
        self.id = id; createdAt = Date(); self.source = source; self.selection = selection; self.options = options
        state = .starting; droppedFrames = 0; acceptedFrames = 0; artifacts = []; markers = []
    }

    public mutating func failRecording(_ failure: AgentFailure, reason: String, at date: Date = Date()) {
        state = failure.code == .interrupted ? .interrupted : .failed
        self.failure = failure; stopReason = reason; endedAt = date
        for index in artifacts.indices where artifacts[index].kind == .recording && artifacts[index].state == .pending {
            artifacts[index].state = state == .interrupted ? .interrupted : .failed
            artifacts[index].failure = failure
        }
    }

    @discardableResult
    public mutating func recoverAfterRestart(at date: Date = Date()) -> Bool {
        guard !state.isTerminal || artifacts.contains(where: { $0.state == .pending }) else { return false }
        let interruption = AgentFailure(.interrupted, "ShareX ended before capture completion was committed.")
        if !state.isTerminal {
            state = .interrupted; endedAt = date; stopReason = "app_restart"; failure = interruption
        }
        for index in artifacts.indices where artifacts[index].state == .pending {
            artifacts[index].state = .interrupted; artifacts[index].failure = interruption
        }
        return true
    }
}

public struct AgentAccessState: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let screenRecordingGranted: Bool
    public init(enabled: Bool, screenRecordingGranted: Bool) { self.enabled = enabled; self.screenRecordingGranted = screenRecordingGranted }
}

public struct CaptureLimits: Codable, Equatable, Sendable {
    public let maxDurationSeconds: Int
    public let defaultDurationSeconds: Int
    public let maxRecordingBytes: Int64
    public let diskReserveBytes: Int64
    public let maxWidthPixels: Int
    public let maxHeightPixels: Int
    public let maxMarkers: Int
    public let maxArtifactsPerSession: Int
    public let maxRequestBytes: Int
    public init() {
        maxDurationSeconds = 7200; defaultDurationSeconds = 1800; maxRecordingBytes = 2_147_483_648
        diskReserveBytes = 268_435_456; maxWidthPixels = 3840; maxHeightPixels = 2160
        maxMarkers = 1000; maxArtifactsPerSession = 1000; maxRequestBytes = 65_536
    }
}

public struct AgentCapabilities: Codable, Sendable {
    public let protocolVersion: Int
    public let access: AgentAccessState
    public let operations: [AgentOperation]
    public let limits: CaptureLimits
    public let sessionRoot: String
    public let activeSessionID: UUID?
    public let coordinateSpace: String
    public let targetChangePolicy: String
    public init(access: AgentAccessState, sessionRoot: String, activeSessionID: UUID? = nil) {
        protocolVersion = 1; self.access = access; self.sessionRoot = sessionRoot
        self.activeSessionID = activeSessionID
        operations = AgentOperation.allCases; limits = CaptureLimits()
        coordinateSpace = "top-left display-local logical points"
        targetChangePolicy = "Stop on target loss, resize, scale change, or display geometry change. Never switch targets. Window movement is allowed."
    }
}

public enum AgentCommand: Equatable, Sendable {
    case capabilities, targetsList
    case screenshot(CaptureSelection, sessionID: UUID?)
    case recordingStart(CaptureSelection, RecordingOptions)
    case recordingStatus(UUID), recordingStop(UUID)
    case sessionMark(UUID, label: String, outcome: TestOutcome?)
    case artifactsList(UUID)
}
