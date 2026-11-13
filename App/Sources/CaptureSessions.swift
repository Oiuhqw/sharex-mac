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
    private let maximumSessions = 2048
    private let maximumRequests = 20_000
    private var sessionCount = 0
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

    func create(_ session: CaptureSession) throws {
        guard sessionCount < maximumSessions else { throw AgentFailure(.limitReached, "The session limit is reached. Archive old session directories before continuing.") }
        try checkReserve()
        let directory = directory(session.id)
        guard mkdir(directory.path, 0o700) == 0 else { throw storageError("Cannot create the session directory") }
        try Self.syncDirectory(root)
        sessionCount += 1
        try save(session)
    }

    func load(_ id: UUID) throws -> CaptureSession {
        let url = directory(id).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { throw AgentFailure(.sessionNotFound, "No session exists with that ID.") }
        try Self.checkPrivateDirectory(directory(id))
        return try read(CaptureSession.self, at: url)
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
        guard requestCount < maximumRequests else { throw AgentFailure(.limitReached, "The durable request limit is reached. Archive old agent data before continuing.") }
        try checkReserve()
        let bytes = try encoder().encode(RequestRecord(request: request, response: nil))
        try AtomicFile.create(bytes, at: requestURL(request.id))
        requestCount += 1
    }

    func complete(_ request: AgentRequest, response: AgentResponse) throws {
        try atomicJSON(RequestRecord(request: request, response: response), to: requestURL(request.id))
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
        let children = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let ids = children.compactMap { UUID(uuidString: $0.lastPathComponent) }
        guard ids.count <= maximumSessions else { throw AgentFailure(.limitReached, "Too many stored agent sessions. Archive old sessions before restarting ShareX.") }
        sessionCount = ids.count
        for id in ids {
            if !fileManager.fileExists(atPath: directory(id).appendingPathComponent("manifest.json").path) { continue }
            var session = try load(id)
            if session.recoverAfterRestart() {
                try save(session)
            }
        }
        let requests = try fileManager.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }
        guard requests.count <= maximumRequests else { throw AgentFailure(.limitReached, "Too many stored agent requests. Archive old agent data before restarting ShareX.") }
        requestCount = requests.count
        for url in requests {
            var record = try read(RequestRecord.self, at: url)
            if record.response == nil {
                record.response = .failure(record.request.id, AgentFailure(.interrupted, "This request was accepted before ShareX restarted. Inspect the session manifests; this request will not run again."))
                try atomicJSON(record, to: url)
            }
        }
    }

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
