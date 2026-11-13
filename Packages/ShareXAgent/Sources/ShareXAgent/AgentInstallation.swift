import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AgentInstallation {
    private static let marker = "# ShareX managed CLI v1"

    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public static func registrationCommand(client: String, executable: URL) -> String {
        let command = shellQuote(executable.resolvingSymlinksInPath().path) + " --agent mcp"
        return client == "claude" ? "claude mcp add --transport stdio --scope user sharex -- " + command : "codex mcp add sharex -- " + command
    }

    public static func wrapper(executable: URL) -> String {
        "#!/bin/sh\n\(marker)\nexec \(shellQuote(executable.resolvingSymlinksInPath().path)) --agent \"$@\"\n"
    }

    @discardableResult
    public static func install(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentFailure(.storageFailed, "The ShareX app executable is unavailable. Move ShareX to Applications and reopen it.")
        }
        let local = home.appendingPathComponent(".local", isDirectory: true)
        let bin = local.appendingPathComponent("bin", isDirectory: true)
        for directory in [local, bin] {
            if mkdir(directory.path, 0o755) != 0, errno != EEXIST {
                throw AgentFailure(.storageFailed, "Cannot create \(directory.path).")
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw AgentFailure(.storageFailed, "CLI folders must be real directories owned by this user and not writable by other users: \(directory.path)")
            }
        }
        let destination = bin.appendingPathComponent("sharex")
        var original = stat()
        let exists = lstat(destination.path, &original) == 0
        if !exists, errno != ENOENT { throw AgentFailure(.storageFailed, "Cannot inspect \(destination.path).") }
        if exists {
            guard original.st_mode & S_IFMT == S_IFREG, original.st_uid == getuid(), original.st_nlink == 1,
                  original.st_mode & 0o022 == 0, original.st_size <= 16_384 else {
                throw AgentFailure(.storageFailed, "A different file exists at \(destination.path). Move it before installing ShareX CLI.")
            }
            let descriptor = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot inspect existing CLI.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_ino == original.st_ino, opened.st_dev == original.st_dev else {
                throw AgentFailure(.storageFailed, "The existing command changed during setup. Run setup again.")
            }
            guard let data = try handle.read(upToCount: 16_385), String(decoding: data, as: UTF8.self).hasPrefix("#!/bin/sh\n\(marker)\n") else {
                throw AgentFailure(.storageFailed, "A different command exists at \(destination.path). Move it before installing ShareX CLI.")
            }
        }
        let temporary = bin.appendingPathComponent(".sharex-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o755)
        guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot write the CLI wrapper.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { _ = unlink(temporary.path) }
        try handle.write(contentsOf: Data(wrapper(executable: executable).utf8))
        guard fchmod(descriptor, 0o755) == 0, fsync(descriptor) == 0 else { throw AgentFailure(.storageFailed, "Cannot save the CLI wrapper.") }
        if exists {
            var current = stat()
            guard lstat(destination.path, &current) == 0, current.st_ino == original.st_ino, current.st_dev == original.st_dev else {
                throw AgentFailure(.storageFailed, "The existing command changed during setup. Run setup again.")
            }
            guard rename(temporary.path, destination.path) == 0 else { throw AgentFailure(.storageFailed, "Cannot update the CLI wrapper.") }
        } else {
            guard link(temporary.path, destination.path) == 0 else {
                throw AgentFailure(.storageFailed, "A command already exists at \(destination.path). No file was replaced.")
            }
        }
        return destination
    }
}
