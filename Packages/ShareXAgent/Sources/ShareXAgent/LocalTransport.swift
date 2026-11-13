import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct AgentEndpoint: Sendable {
    public let directory: String
    public var socketPath: String { directory + "/agent.sock" }
    public init(directory: String = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path + "/sharex-agent-\(getuid())") {
        self.directory = directory
    }

    func validateDirectory(create: Bool) throws {
        if create, mkdir(directory, 0o700) != 0, errno != EEXIST { throw socketFailure("Cannot create private agent directory") }
        var info = stat()
        guard lstat(directory, &info) == 0 else { throw socketFailure("Agent directory is unavailable") }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else {
            throw AgentFailure(.storageFailed, "The agent directory must be a real directory owned by this user with mode 0700: \(directory)")
        }
    }

    func socketInfo() throws -> stat {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { throw socketFailure("Agent socket is unavailable") }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600 else {
            throw AgentFailure(.storageFailed, "The agent endpoint must be a socket owned by this user with mode 0600.")
        }
        return info
    }
}

public struct LocalAgentClient: Sendable {
    public let endpoint: AgentEndpoint
    public let timeout: TimeInterval
    public init(endpoint: AgentEndpoint = AgentEndpoint(), timeout: TimeInterval = 65) {
        self.endpoint = endpoint; self.timeout = timeout
    }

    public func send(_ request: AgentRequest) throws -> AgentResponse {
        _ = try OperationCatalog.validate(request)
        try endpoint.validateDirectory(create: false)
        _ = try endpoint.socketInfo()
        let descriptor = try makeSocket()
        defer { close(descriptor) }
        let deadline = Deadline(seconds: timeout)
        let result = try withSocketAddress(endpoint.socketPath) { connect(descriptor, $0, $1) }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw socketFailure("Cannot connect to ShareX") }
            try waitFor(descriptor, event: Int16(POLLOUT), deadline: deadline)
            var code: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else {
                throw AgentFailure(.startupTimeout, "Cannot connect to ShareX. Open the app and check Settings > Agents.")
            }
        }
        try verifyPeer(descriptor)
        try writeFrame(try request.canonicalData(), descriptor, deadline: deadline)
        let data = try readFrame(descriptor, maximum: 8 * 1024 * 1024, deadline: deadline)
        let response = try JSONDecoder().decode(AgentResponse.self, from: data)
        guard response.version == 1, response.id == request.id, response.ok == (response.error == nil),
              response.ok == (response.result != nil) else {
            throw AgentFailure(.invalidRequest, "ShareX returned an invalid response envelope.")
        }
        return response
    }
}

public final class LocalAgentServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentRequest) async -> AgentResponse
    private let queue = DispatchQueue(label: "com.sharexmac.agent.listener")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let slots = DispatchSemaphore(value: 8)
    private var source: DispatchSourceRead?
    private let endpoint: AgentEndpoint
    private let handler: Handler
    private var lockDescriptor: Int32 = -1
    private var ownsLock = false
    private var boundInode: ino_t?

    public init(endpoint: AgentEndpoint = AgentEndpoint(), handler: @escaping Handler) throws {
        self.endpoint = endpoint; self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
        try endpoint.validateDirectory(create: true)
        let lockPath = endpoint.directory + "/owner.lock"
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockDescriptor >= 0 else { throw socketFailure("Cannot open agent ownership lock") }
        do {
            var info = stat()
            guard fstat(lockDescriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
                throw AgentFailure(.storageFailed, "Unsafe agent ownership lock.")
            }
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw AgentFailure(.busy, "Another ShareX app owns local agent access.")
            }
            ownsLock = true
            var stale = stat()
            if lstat(endpoint.socketPath, &stale) == 0 {
                _ = try endpoint.socketInfo()
                guard unlink(endpoint.socketPath) == 0 else { throw socketFailure("Cannot remove stale agent socket") }
            } else if errno != ENOENT { throw socketFailure("Cannot inspect agent socket") }
            let descriptor = try makeSocket()
            do {
                guard try withSocketAddress(endpoint.socketPath, { bind(descriptor, $0, $1) }) == 0 else { throw socketFailure("Cannot bind agent socket") }
                guard chmod(endpoint.socketPath, 0o600) == 0 else { throw socketFailure("Cannot secure agent socket") }
                boundInode = try endpoint.socketInfo().st_ino
                guard listen(descriptor, 8) == 0 else { throw socketFailure("Cannot listen for agents") }
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptClients(descriptor) }
                source.setCancelHandler { close(descriptor) }
                self.source = source
                source.resume()
            } catch { close(descriptor); throw error }
        } catch {
            cleanupEndpoint()
            releaseOwnership()
            throw error
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    deinit { stop() }

    private func stopOnQueue() {
        source?.cancel()
        source = nil
        cleanupEndpoint()
        releaseOwnership()
    }

    private func releaseOwnership() {
        if ownsLock { _ = flock(lockDescriptor, LOCK_UN); ownsLock = false }
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    private func cleanupEndpoint() {
        if let boundInode, let info = try? endpoint.socketInfo(), info.st_ino == boundInode { _ = unlink(endpoint.socketPath) }
        boundInode = nil
    }

    private func acceptClients(_ descriptor: Int32) {
        for _ in 0..<64 {
            let client = accept(descriptor, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            let slots = slots, handler = handler
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(client); slots.signal() }
                do {
                    try configureSocket(client)
                    try verifyPeer(client)
                    let data = try readFrame(client, maximum: CaptureLimits().maxRequestBytes, deadline: Deadline(seconds: 5))
                    let request = try JSONDecoder().decode(AgentRequest.self, from: data)
                    let response: AgentResponse
                    do {
                        _ = try OperationCatalog.validate(request)
                        let completion = ResponseBox()
                        Task { completion.finish(await handler(request)) }
                        guard completion.ready.wait(timeout: .now() + 60) == .success, let value = completion.get() else {
                            throw AgentFailure(.startupTimeout, "The operation is still pending. Retry with the same request ID.")
                        }
                        response = value
                    } catch let failure as AgentFailure { response = .failure(request.id, failure) }
                    catch { response = .failure(request.id, AgentFailure(.internalError, error.localizedDescription)) }
                    let encoded = try JSONEncoder().encode(response)
                    guard encoded.count <= 8 * 1024 * 1024 else { throw AgentFailure(.limitReached, "Response exceeds transport limit.") }
                    try writeFrame(encoded, client, deadline: Deadline(seconds: 5))
                } catch {}
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: AgentResponse?
    func finish(_ response: AgentResponse) { lock.withLock { self.response = response }; ready.signal() }
    func get() -> AgentResponse? { lock.withLock { response } }
}

private struct Deadline {
    let end: UInt64
    init(seconds: TimeInterval) { end = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000) }
    var milliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        return end > now ? Int32(min((end - now) / 1_000_000 + 1, UInt64(Int32.max))) : 0
    }
}

private func socketFailure(_ action: String) -> AgentFailure {
    AgentFailure(.startupTimeout, "\(action): \(String(cString: strerror(errno))). Open ShareX and check Settings > Agents.")
}

private func makeSocket() throws -> Int32 {
    #if canImport(Darwin)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw socketFailure("Cannot create agent socket") }
    do { try configureSocket(descriptor); return descriptor }
    catch { close(descriptor); throw error }
}

private func configureSocket(_ descriptor: Int32) throws {
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw socketFailure("Cannot configure agent socket")
    }
    #if canImport(Darwin)
    var enabled: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw socketFailure("Cannot configure socket signals")
    }
    #endif
}

private func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentFailure(.storageFailed, "Agent socket path is too long.") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func verifyPeer(_ descriptor: Int32) throws {
    #if canImport(Darwin)
    var user: uid_t = 0, group: gid_t = 0
    guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else {
        throw AgentFailure(.permissionDenied, "The socket peer must run as the current user.")
    }
    #else
    struct Credentials { var pid: Int32 = 0; var uid: uid_t = 0; var gid: gid_t = 0 }
    var credentials = Credentials()
    var size = socklen_t(MemoryLayout<Credentials>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0, credentials.uid == getuid() else {
        throw AgentFailure(.permissionDenied, "The socket peer must run as the current user.")
    }
    #endif
}

private func waitFor(_ descriptor: Int32, event: Int16, deadline: Deadline) throws {
    while true {
        let remaining = deadline.milliseconds
        guard remaining > 0 else { throw AgentFailure(.startupTimeout, "Local capture timed out. Retry with the same request ID.") }
        var item = pollfd(fd: descriptor, events: event, revents: 0)
        let result = poll(&item, 1, remaining)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { throw AgentFailure(.startupTimeout, "Local capture timed out. Retry with the same request ID.") }
        if item.revents & event != 0 { return }
        throw AgentFailure(.interrupted, "The local agent connection closed. Retry with the same request ID.")
    }
}

private func readBytes(_ count: Int, _ descriptor: Int32, deadline: Deadline) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < count {
            try waitFor(descriptor, event: Int16(POLLIN), deadline: deadline)
            let received = recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
            if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard received > 0 else { throw AgentFailure(.interrupted, "The local agent connection ended before the response completed.") }
            offset += received
        }
    }
    return data
}

private func readFrame(_ descriptor: Int32, maximum: Int, deadline: Deadline) throws -> Data {
    let header = try readBytes(4, descriptor, deadline: deadline)
    let count = header.reduce(0) { ($0 << 8) | Int($1) }
    guard count > 0, count <= maximum else { throw AgentFailure(.invalidRequest, "Invalid agent frame size.") }
    return try readBytes(count, descriptor, deadline: deadline)
}

private func writeFrame(_ data: Data, _ descriptor: Int32, deadline: Deadline) throws {
    let count = UInt32(data.count)
    let frame = Data([UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)]) + data
    try frame.withUnsafeBytes { buffer in
        var offset = 0
        while offset < frame.count {
            try waitFor(descriptor, event: Int16(POLLOUT), deadline: deadline)
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let sent = send(descriptor, buffer.baseAddress!.advanced(by: offset), frame.count - offset, flags)
            if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard sent > 0 else { throw socketFailure("Cannot write agent response") }
            offset += sent
        }
    }
}
