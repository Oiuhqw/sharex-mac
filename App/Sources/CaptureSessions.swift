import Foundation
import CryptoKit
import Darwin
import ImageIO
import ShareXAgent

actor CaptureSessions {
    struct RequestRecord: Codable, Sendable {
        let request: AgentRequest
        var response: AgentResponse?
    }
    nonisolated let root: URL
    private let fileManager = FileManager.default
    private let maximumRequests = 20_000
    private var unreadable: Set<UUID> = []
    private var requestCount = 0

    init() {
        root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ShareX/AgentSessions", isDirectory: true)
    }

    func initialize() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.checkPrivateDirectory(root)
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        if !fileManager.fileExists(atPath: requests.path) {
            try fileManager.createDirectory(at: requests, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try Self.checkPrivateDirectory(requests)
        try recover()
    }

    func storage() -> AgentStorageStatus {
        let ids = (try? sessionIDs()) ?? []
        return AgentStorageStatus(sessionCount: ids.count, unreadableSessions: unreadable.intersection(ids).count)
    }

    func create(_ session: CaptureSession) throws {
        guard !storage().sessionLimitReached else { throw AgentFailure(.limitReached, "The session limit is reached. Delete old captures in ShareX Settings > Agents.") }
        try checkReserve()
        let directory = directory(session.id)
        guard mkdir(directory.path, 0o700) == 0 else { throw storageError("Cannot create the session directory") }
        try Self.syncDirectory(root)
        try save(session)
    }

    func load(_ id: UUID) throws -> CaptureSession {
        let folder = directory(id)
        guard fileManager.fileExists(atPath: folder.path) else {
            unreadable.remove(id)
            throw AgentFailure(.sessionNotFound, "No session exists with that ID.")
        }
        do {
            try Self.checkPrivateDirectory(folder)
            let manifest = folder.appendingPathComponent("manifest.json")
            var status = stat()
            guard lstat(manifest.path, &status) == 0 || errno != ENOENT else { throw AgentFailure(.sessionNotFound, "No session exists with that ID.") }
            let session = try read(CaptureSession.self, at: manifest)
            unreadable.remove(id)
            return session
        } catch {
            unreadable.insert(id)
            if let failure = error as? AgentFailure, failure.code == .sessionNotFound { throw failure }
            throw AgentFailure(.storageFailed, "The session folder \(folder.path) is unreadable. \(error.localizedDescription)")
        }
    }

    func save(_ session: CaptureSession) throws {
        try Self.checkPrivateDirectory(directory(session.id))
        try atomicJSON(session, to: directory(session.id).appendingPathComponent("manifest.json"))
    }

    func update(_ id: UUID, _ change: @Sendable (inout CaptureSession) throws -> Void) throws -> CaptureSession {
        var session = try load(id)
        try change(&session)
        try save(session)
        return session
    }

    func request(_ id: UUID) throws -> RequestRecord? {
        let url = requestURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try read(RequestRecord.self, at: url)
    }

    func accept(_ request: AgentRequest) throws {
        // A session folder has the ID of the request that created it, and it stays after that request record expires.
        var status = stat()
        guard lstat(directory(request.id).path, &status) != 0 else {
            throw AgentFailure(.requestConflict, "This request ID already created a session. Use a new request ID.")
        }
        guard requestCount < maximumRequests else { throw AgentFailure(.limitReached, "The stored request limit is reached. Restart ShareX to remove request records older than 7 days.") }
        try checkReserve()
        let bytes = try encoder().encode(RequestRecord(request: request, response: nil))
        try AtomicFile.create(bytes, at: requestURL(request.id))
        requestCount += 1
    }

    func settle(_ request: AgentRequest, command: AgentCommand, response: AgentResponse) throws {
        var status = stat()
        let keeps = RequestReplayPolicy.keepsResponse(response, to: command,
            requestSessionExists: lstat(directory(request.id).path, &status) == 0,
            targetSession: RequestReplayPolicy.targetSession(of: command).flatMap { try? load($0) })
        if keeps {
            try atomicJSON(RequestRecord(request: request, response: response), to: requestURL(request.id))
        } else {
            guard unlink(requestURL(request.id).path) == 0 || errno == ENOENT else { throw storageError("Cannot discard the request record") }
            requestCount -= 1
        }
    }

    func artifactURL(sessionID: UUID, artifactID: UUID, extension suffix: String) throws -> URL {
        let folder = directory(sessionID).appendingPathComponent(artifactID.uuidString, isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw storageError("Cannot reserve the artifact directory") }
        return folder.appendingPathComponent("capture.partial.\(suffix)")
    }

    func checkReserve(additionalBytes: Int64 = 0) throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= CaptureLimits().diskReserveBytes + additionalBytes else {
            throw AgentFailure(.diskFull, "Capture requires at least 256 MiB of free disk reserve.")
        }
    }

    func byteCount(at url: URL) throws -> Int64 {
        (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func oldCaptures() -> [UUID] {
        ((try? sessionIDs()) ?? []).filter { isOldCapture($0) }
    }

    func deleteOldCaptures(_ ids: [UUID]) {
        for id in ids where isOldCapture(id) { try? fileManager.removeItem(at: directory(id)) }
    }

    nonisolated static func publishPNG(_ png: Data, at partial: URL, width: Int, height: Int) throws -> (URL, Int64, String) {
        try AtomicFile.create(png, at: partial)
        guard let source = CGImageSourceCreateWithURL(partial as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height else {
            throw AgentFailure(.captureFailed, "The written PNG could not be decoded at the expected dimensions.")
        }
        return try publish(partial)
    }

    nonisolated static func publish(_ partial: URL) throws -> (URL, Int64, String) {
        let descriptor = open(partial.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot open the completed artifact for synchronization.") }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
            throw AgentFailure(.storageFailed, "Cannot synchronize the completed artifact data.")
        }
        let handle = try FileHandle(forReadingFrom: partial)
        defer { try? handle.close() }
        var digest = SHA256()
        var size: Int64 = 0
        let started = ProcessInfo.processInfo.systemUptime
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            guard ProcessInfo.processInfo.systemUptime - started < 120 else {
                throw AgentFailure(.storageFailed, "Artifact hashing exceeded 120 seconds. The file was not published.")
            }
            digest.update(data: chunk); size += Int64(chunk.count)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let final = partial.deletingLastPathComponent().appendingPathComponent("capture.\(partial.pathExtension)")
        // link is an exclusive publish. A pre-existing destination is never replaced.
        guard link(partial.path, final.path) == 0 else { throw AgentFailure(.storageFailed, "Cannot publish the completed artifact.") }
        guard unlink(partial.path) == 0 else { throw AgentFailure(.storageFailed, "Cannot retire the partial artifact name.") }
        try syncDirectory(final.deletingLastPathComponent())
        return (final, size, hash)
    }

    private func recover() throws {
        for id in try sessionIDs() {
            guard var session = try? load(id) else { continue }
            if session.recoverAfterRestart() {
                do { try save(session) } catch { unreadable.insert(id) }
            }
        }
        let requests = try fileManager.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }
        requestCount = 0
        for url in requests {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, RequestReplayPolicy.recordExpired(modifiedAt: modified), unlink(url.path) == 0 { continue }
            requestCount += 1
            guard var record = try? read(RequestRecord.self, at: url), record.response == nil else { continue }
            record.response = .failure(record.request.id, AgentFailure(.interrupted, "This request was accepted before ShareX restarted. Inspect the session manifests; this request will not run again."))
            try? atomicJSON(record, to: url)
        }
    }

    private func sessionIDs() throws -> [UUID] {
        do { return try fileManager.contentsOfDirectory(atPath: root.path).compactMap { UUID(uuidString: $0) } }
        catch { throw AgentFailure(.storageFailed, "Cannot list the session folder \(root.path): \(error.localizedDescription)") }
    }

    private func isOldCapture(_ id: UUID) -> Bool { (try? load(id))?.isOldCapture() ?? false }

    private func requestURL(_ id: UUID) -> URL { root.appendingPathComponent("requests/\(id.uuidString).json") }
    private func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]; return value
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw storageError("Cannot read agent metadata") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw AgentFailure(.storageFailed, "Agent metadata exceeds its size limit.") }
        return try JSONDecoder().decode(type, from: data)
    }
    private func atomicJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        guard data.count <= 2_097_152 else { throw AgentFailure(.limitReached, "The session metadata limit is reached.") }
        try AtomicFile.replace(data, at: url)
    }
    nonisolated private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot open the capture directory.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AgentFailure(.storageFailed, "Cannot synchronize the capture directory.") }
    }
    nonisolated private static func checkPrivateDirectory(_ directory: URL) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
            throw AgentFailure(.storageFailed, "Agent storage must be a private directory owned by the current user.")
        }
    }
    private func storageError(_ message: String) -> AgentFailure { AgentFailure(.storageFailed, "\(message): \(String(cString: strerror(errno)))") }
}
