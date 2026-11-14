import AppKit
import Observation
import ShareXAgent

@MainActor
@Observable
final class AgentCaptureService {
    static let enabledDefaultsKey = "agentCaptureEnabled"
    private(set) var recordingSnapshot: CaptureSession?
    private(set) var storage = AgentStorageStatus()
    private(set) var enabled: Bool
    @ObservationIgnored private let targets = CaptureTargets()
    @ObservationIgnored private let sessions: CaptureSessions
    @ObservationIgnored private var storageReady: Task<Void, Error>?
    @ObservationIgnored private var active: ActiveRecording?
    @ObservationIgnored private var requests: [UUID: PendingRequest] = [:]
    @ObservationIgnored private var screenshotBusy = false
    @ObservationIgnored private var shuttingDown = false

    private struct PendingRequest { let request: AgentRequest; let task: Task<AgentResponse, Never> }
    @MainActor private final class ActiveRecording {
        let id: UUID
        let selection: CaptureSelection
        let options: RecordingOptions
        var recorder: ScreenRecorder?
        var partialURL: URL?
        var startup: Task<CaptureSession, Error>?
        var finalization: Task<CaptureSession, Error>?
        var monitor: Task<Void, Never>?
        var stopReason: String?
        var failure: AgentFailure?
        init(id: UUID, selection: CaptureSelection, options: RecordingOptions) {
            self.id = id; self.selection = selection; self.options = options
        }
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        let store = CaptureSessions()
        sessions = store
    }

    var accessState: AgentAccessState { AgentAccessState(enabled: enabled, screenRecordingGranted: CGPreflightScreenCaptureAccess()) }
    var capabilities: AgentCapabilities {
        AgentCapabilities(access: accessState, sessionRoot: sessions.root.path, activeSessionID: active?.id, storage: storage)
    }

    func refreshStorage() async {
        let current = await sessions.storage()
        if current != storage { storage = current }
    }

    func oldCaptureCount() async -> Int {
        do { try await startStorage() } catch { return 0 }
        await refreshStorage()
        return await sessions.oldCaptureCount()
    }

    func deleteOldCaptures() async {
        do { try await startStorage() } catch { return }
        await sessions.deleteOldCaptures()
        await refreshStorage()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledDefaultsKey)
        if !value { Task { await stopActive(reason: "access_revoked") } }
    }

    func stopActive() async { await stopActive(reason: "user_stop") }

    func shutdown() async {
        shuttingDown = true
        await stopActive(reason: "app_quit")
        for pending in Array(requests.values) { _ = await pending.task.value }
    }

    func execute(_ request: AgentRequest) async -> AgentResponse {
        do {
            let command = try OperationCatalog.validate(request)
            if case .capabilities = command {
                await refreshStorage()
                return .success(request.id, try JSONValue.encode(capabilities))
            }
            guard enabled else { throw AgentFailure(.disabled, "Enable agent capture in ShareX Settings before using capture tools.") }
            guard !shuttingDown else { throw AgentFailure(.interrupted, "ShareX is shutting down.") }
            try await startStorage()
            guard enabled, !shuttingDown else { throw AgentFailure(.disabled, "Agent capture is disabled.") }
            if let pending = requests[request.id] {
                guard pending.request == request else { throw AgentFailure(.requestConflict, "This request ID was already used with different command content.") }
                return await pending.task.value
            }
            guard request.operation.mutates else { return .success(request.id, try await run(command, requestID: request.id)) }
            guard requests.count < 64 else { throw AgentFailure(.busy, "Too many agent requests are in progress. Retry later with the same request ID.") }
            let task = Task<AgentResponse, Never> { @MainActor in
                do {
                    if let saved = try await sessions.request(request.id) {
                        guard saved.request == request else { return .failure(request.id, AgentFailure(.requestConflict, "This request ID was already used with different command content.")) }
                        return saved.response ?? .failure(request.id, AgentFailure(.interrupted, "This request was accepted but has no committed result. It will not run again."))
                    }
                    try await sessions.accept(request)
                } catch { return .failure(request.id, Self.failure(error, defaultCode: .storageFailed)) }
                let response: AgentResponse
                do { response = .success(request.id, try await run(command, requestID: request.id)) }
                catch { response = .failure(request.id, Self.failure(error)) }
                do {
                    try await sessions.settle(request, command: command, response: response)
                    return response
                } catch {
                    return .failure(request.id, Self.failure(error, defaultCode: .storageFailed))
                }
            }
            requests[request.id] = PendingRequest(request: request, task: task)
            let response = await task.value
            requests[request.id] = nil
            await refreshStorage()
            return response
        } catch { return .failure(request.id, Self.failure(error)) }
    }

    private func startStorage() async throws {
        if let storageReady { try await storageReady.value; return }
        let task = Task { try await sessions.initialize() }
        storageReady = task
        // Only the caller that started the task clears it, so a waiter on a failed start cannot drop a newer start.
        do { try await task.value } catch { storageReady = nil; throw error }
    }

    private func run(_ command: AgentCommand, requestID: UUID) async throws -> JSONValue {
        switch command {
        case .capabilities: return try JSONValue.encode(capabilities)
        case .targetsList: return .object(["targets": try JSONValue.encode(await targets.list())])
        case .screenshot(let selection, let sessionID):
            return try JSONValue.encode(await screenshot(selection, sessionID: sessionID, requestID: requestID))
        case .recordingStart(let selection, let options):
            return try JSONValue.encode(await start(selection, options: options, id: requestID))
        case .recordingStatus(let id), .artifactsList(let id):
            return try JSONValue.encode(await status(id))
        case .recordingStop(let id):
            guard let active, active.id == id else { return try JSONValue.encode(await sessions.load(id)) }
            return try JSONValue.encode(await finish(active, reason: "user_stop"))
        case .sessionMark(let id, let label, let outcome):
            let session = try await sessions.update(id) { session in
                guard !session.markers.contains(where: { $0.id == requestID }) else { throw AgentFailure(.requestConflict, "This request ID already wrote a marker in this session.") }
                guard session.markers.count < CaptureLimits().maxMarkers else { throw AgentFailure(.limitReached, "The session marker limit is reached.") }
                session.markers.append(SessionMarker(id: requestID, label: label, outcome: outcome))
            }
            updateSnapshot(session)
            return try JSONValue.encode(session)
        }
    }

    private func screenshot(_ selection: CaptureSelection, sessionID: UUID?, requestID: UUID) async throws -> CaptureSession {
        guard !screenshotBusy else { throw AgentFailure(.busy, "A screenshot is already in progress.") }
        screenshotBusy = true
        defer { screenshotBusy = false }
        try await sessions.checkReserve()
        let resolved = try await targets.resolve(selection)
        try requireCaptureAccess()
        let id = sessionID ?? requestID
        if sessionID == nil {
            try await sessions.create(CaptureSession(id: id, source: resolved.target, selection: selection))
        }
        var artifact = CaptureArtifact(id: requestID, kind: .screenshot)
        artifact.source = resolved.target; artifact.selection = selection
        let pendingArtifact = artifact
        _ = try await sessions.update(id) { session in
            guard !session.artifacts.contains(where: { $0.id == pendingArtifact.id }) else { throw AgentFailure(.requestConflict, "This request ID already wrote an artifact in this session.") }
            guard session.artifacts.count < CaptureLimits().maxArtifactsPerSession else { throw AgentFailure(.limitReached, "The session artifact limit is reached.") }
            session.artifacts.append(pendingArtifact)
        }
        do {
            let image = try await ScreenCapture.captureAgent(filter: resolved.filter, configuration: resolved.configuration)
            try requireCaptureAccess()
            _ = try await targets.resolve(selection)
            guard let png = await Export.encodePNGOffMain(image, scale: resolved.scale) else {
                throw AgentFailure(.captureFailed, "The screenshot could not be encoded as PNG.")
            }
            try requireCaptureAccess()
            try await sessions.checkReserve(additionalBytes: Int64(png.count))
            let url = try await sessions.artifactURL(sessionID: id, artifactID: artifact.id, extension: "png")
            let width = image.width, height = image.height
            let completed = try await Task.detached(priority: .utility) {
                try CaptureSessions.publishPNG(png, at: url, width: width, height: height)
            }.value
            artifact.state = .completed; artifact.path = completed.0.path; artifact.byteCount = completed.1; artifact.sha256 = completed.2
            artifact.widthPixels = width; artifact.heightPixels = height
            let completedArtifact = artifact
            let session = try await sessions.update(id) { session in
                if let index = session.artifacts.firstIndex(where: { $0.id == completedArtifact.id }) { session.artifacts[index] = completedArtifact }
                if sessionID == nil { session.state = .completed; session.startedAt = completedArtifact.createdAt; session.endedAt = Date() }
            }
            updateSnapshot(session)
            return session
        } catch {
            artifact.state = .failed; artifact.failure = Self.failure(error)
            let failedArtifact = artifact
            _ = try await sessions.update(id) { session in
                if let index = session.artifacts.firstIndex(where: { $0.id == failedArtifact.id }) { session.artifacts[index] = failedArtifact }
                if sessionID == nil { session.state = .failed; session.failure = failedArtifact.failure; session.endedAt = Date() }
            }
            throw error
        }
    }

    private func start(_ selection: CaptureSelection, options: RecordingOptions, id: UUID) async throws -> CaptureSession {
        if let active { throw AgentFailure(.busy, "Recording \(active.id.uuidString) owns the capture slot. Stop it before starting another.") }
        try requireCaptureAccess()
        let recording = ActiveRecording(id: id, selection: selection, options: options)
        active = recording
        let startup = Task { @MainActor in try await prepare(recording) }
        recording.startup = startup
        return try await startup.value
    }

    private func prepare(_ recording: ActiveRecording) async throws -> CaptureSession {
        do {
            try await sessions.checkReserve()
            let target = try await targets.resolve(recording.selection, recording: true)
            try requireCaptureAccess()
            guard recording.stopReason == nil else { throw AgentFailure(.interrupted, "Recording stopped during target resolution.") }
            var session = CaptureSession(id: recording.id, source: target.target, selection: recording.selection, options: recording.options)
            var artifact = CaptureArtifact(kind: .recording)
            artifact.source = target.target; artifact.selection = recording.selection
            session.artifacts.append(artifact)
            try await sessions.create(session)
            recordingSnapshot = session
            let url = try await sessions.artifactURL(sessionID: session.id, artifactID: artifact.id, extension: "mp4")
            recording.partialURL = url
            try requireCaptureAccess()
            guard recording.stopReason == nil else { throw AgentFailure(.interrupted, "Recording stopped before stream startup.") }
            let recorder = try ScreenRecorder(target: target, options: recording.options, url: url, onFailure: { [weak self, weak recording] error in
                Task { @MainActor in
                    guard let self, let recording, self.active === recording else { return }
                    recording.failure = error
                    _ = try? await self.finish(recording, reason: error.code == .startupTimeout ? "startup_timeout" : "stream_error")
                }
            }, onLimit: { [weak self, weak recording] reason in
                Task { @MainActor in
                    guard let self, let recording, self.active === recording else { return }
                    _ = try? await self.finish(recording, reason: reason)
                }
            })
            recording.recorder = recorder
            let stats = try await recorder.start()
            session = try await sessions.update(recording.id) { session in
                session.state = .recording; session.startedAt = stats.startedAt
                session.acceptedFrames = stats.acceptedFrames; session.droppedFrames = stats.droppedFrames
            }
            recordingSnapshot = session
            recording.monitor = Task { @MainActor in await monitor(recording) }
            return session
        } catch {
            recording.failure = Self.failure(error)
            if let recorder = recording.recorder { _ = try? await recorder.finish() }
            let failure = Self.failure(error), reason = recording.stopReason ?? "startup_failed"
            if let session = try? await sessions.update(recording.id, { $0.failRecording(failure, reason: reason) }) {
                recordingSnapshot = session
            }
            if active === recording, recording.finalization == nil { active = nil }
            throw error
        }
    }

    private func finish(_ recording: ActiveRecording, reason: String) async throws -> CaptureSession {
        if let task = recording.finalization { return try await task.value }
        recording.stopReason = reason
        recording.monitor?.cancel()
        recording.recorder?.cancelStartup()
        let task = Task { @MainActor in
            do {
                _ = try await recording.startup?.value
                guard let recorder = recording.recorder, let partial = recording.partialURL else {
                    throw AgentFailure(.recordingFailed, "The recording did not start.")
                }
                var session = try await sessions.update(recording.id) { session in
                    session.state = .finalizing; session.stopReason = reason
                }
                recordingSnapshot = session
                let video = try await recorder.finish()
                if let failure = recording.failure { throw failure }
                let size = try await sessions.byteCount(at: partial)
                guard size <= recording.options.maxBytes else { throw AgentFailure(.limitReached, "The finalized recording exceeds its byte limit. The partial file is incomplete evidence.") }
                let published = try await Task.detached(priority: .utility) { try CaptureSessions.publish(partial) }.value
                session = try await sessions.update(recording.id) { session in
                    guard let index = session.artifacts.firstIndex(where: { $0.kind == .recording }) else {
                        throw AgentFailure(.storageFailed, "The recording artifact is missing from the manifest.")
                    }
                    session.artifacts[index].state = .completed; session.artifacts[index].path = published.0.path
                    session.artifacts[index].byteCount = published.1; session.artifacts[index].sha256 = published.2
                    session.artifacts[index].widthPixels = video.width; session.artifacts[index].heightPixels = video.height
                    session.artifacts[index].durationSeconds = video.duration
                    session.acceptedFrames = video.statistics.acceptedFrames; session.droppedFrames = video.statistics.droppedFrames
                    session.state = .completed; session.endedAt = Date(); session.stopReason = reason
                }
                recordingSnapshot = session
                if active === recording { active = nil }
                return session
            } catch {
                if let recorder = recording.recorder { _ = try? await recorder.finish() }
                let failure = Self.failure(error)
                if let session = try? await sessions.update(recording.id, { $0.failRecording(failure, reason: reason) }) {
                    recordingSnapshot = session
                    if active === recording { active = nil }
                    return session
                }
                if active === recording { active = nil }
                throw error
            }
        }
        recording.finalization = task
        return try await task.value
    }

    private func monitor(_ recording: ActiveRecording) async {
        var ticks = 0
        while !Task.isCancelled, active === recording, recording.finalization == nil {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, active === recording, recording.finalization == nil else { return }
            ticks += 1
            do {
                guard enabled else { _ = try await finish(recording, reason: "access_revoked"); return }
                guard CGPreflightScreenCaptureAccess() else { _ = try await finish(recording, reason: "permission_revoked"); return }
                let stats = await recording.recorder?.statistics()
                if ticks % 4 == 0 {
                    _ = try await targets.resolve(recording.selection, recording: true)
                    if let stats, var session = try? await sessions.load(recording.id) {
                        session.acceptedFrames = stats.acceptedFrames; session.droppedFrames = stats.droppedFrames
                        recordingSnapshot = session
                    }
                }
            } catch {
                let failure = Self.failure(error)
                if failure.code == .diskFull { _ = try? await finish(recording, reason: "disk_reserve"); return }
                recording.failure = failure
                _ = try? await finish(recording, reason: failure.code == .targetChanged ? "target_changed" : "target_lost")
                return
            }
        }
    }

    private func status(_ id: UUID) async throws -> CaptureSession {
        var session = try await sessions.load(id)
        if let active, active.id == id, let stats = await active.recorder?.statistics() {
            session.acceptedFrames = stats.acceptedFrames; session.droppedFrames = stats.droppedFrames
        }
        return session
    }
    private func stopActive(reason: String) async {
        if let active { _ = try? await finish(active, reason: reason) }
    }
    private func requireCaptureAccess() throws {
        guard enabled, !shuttingDown else { throw AgentFailure(.disabled, "Agent capture is disabled.") }
        guard CGPreflightScreenCaptureAccess() else { throw AgentFailure(.permissionDenied, "Grant ShareX Screen Recording permission in System Settings.") }
    }
    private func updateSnapshot(_ session: CaptureSession) {
        if recordingSnapshot?.id == session.id { recordingSnapshot = session }
    }
    private static func failure(_ error: Error, defaultCode: AgentErrorCode = .captureFailed) -> AgentFailure {
        error as? AgentFailure ?? AgentFailure(defaultCode, error.localizedDescription)
    }
}
