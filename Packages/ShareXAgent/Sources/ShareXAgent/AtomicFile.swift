import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AtomicFile {
    public static func create(_ data: Data, at url: URL) throws {
        try commit(data, to: url, replacing: false)
    }

    public static func replace(_ data: Data, at url: URL) throws {
        try commit(data, to: url, replacing: true)
    }

    private static func commit(_ data: Data, to url: URL, replacing: Bool) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot reserve the output file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { _ = unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if replacing {
            guard rename(temporary.path, url.path) == 0 else { throw AgentFailure(.storageFailed, "Cannot replace the output file.") }
        } else {
            guard link(temporary.path, url.path) == 0 else { throw AgentFailure(.storageFailed, "Cannot publish the output file without replacing an existing file.") }
            guard unlink(temporary.path) == 0 else { throw AgentFailure(.storageFailed, "Cannot retire the temporary output file.") }
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot open the output directory.") }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw AgentFailure(.storageFailed, "Cannot synchronize the output directory.") }
    }
}
