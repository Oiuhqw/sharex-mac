import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct InstallationFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let links: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode); owner = UInt32(value.st_uid)
        links = UInt64(value.st_nlink); size = Int64(value.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(value.st_mtim.tv_sec); modifiedNanoseconds = Int64(value.st_mtim.tv_nsec)
        changedSeconds = Int64(value.st_ctim.tv_sec); changedNanoseconds = Int64(value.st_ctim.tv_nsec)
        #endif
    }
}

public enum ManagedCLIStatus: Equatable, Sendable {
    case absent
    case owned(InstallationFileIdentity)
    case preserved(String)
}

public struct ManagedApplication: Equatable, Sendable {
    public let bundleURL: URL
    public let executableURL: URL
    private let bundleIdentity: InstallationFileIdentity
    private let executableIdentity: InstallationFileIdentity
    private let parentIdentity: InstallationFileIdentity
    private let bundleIdentifier: String

    public static func inspect(bundleURL: URL, executableURL: URL, bundleIdentifier: String) throws -> Self {
        let app = bundleURL.standardizedFileURL, executable = executableURL.standardizedFileURL
        guard app.pathExtension == "app", app == bundleURL, executable == executableURL,
              !app.path.hasPrefix("/Volumes/"),
              executable.path.hasPrefix(app.path + "/Contents/MacOS/"),
              let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier,
              bundle.executableURL?.standardizedFileURL == executable else {
            throw AgentFailure(.storageFailed, "The running app is not a removable ShareX installation. Move a real ShareX.app to Applications and reopen it.")
        }
        let parent = try InstallationPaths.openDirectory(app.deletingLastPathComponent())
        defer { close(parent) }
        var parentInfo = stat(), appInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_mode & 0o002 == 0,
              fstatat(parent, app.lastPathComponent, &appInfo, AT_SYMLINK_NOFOLLOW) == 0,
              appInfo.st_mode & S_IFMT == S_IFDIR, appInfo.st_uid == getuid(),
              appInfo.st_mode & 0o022 == 0,
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw AgentFailure(.storageFailed, "The app must be a real directory owned by you in a trusted, writable folder.")
        }
        let executableParent = try InstallationPaths.openDirectory(executable.deletingLastPathComponent())
        defer { close(executableParent) }
        var executableInfo = stat()
        guard fstatat(executableParent, executable.lastPathComponent, &executableInfo, AT_SYMLINK_NOFOLLOW) == 0,
              executableInfo.st_mode & S_IFMT == S_IFREG, executableInfo.st_uid == getuid(),
              executableInfo.st_mode & 0o022 == 0, executableInfo.st_nlink == 1,
              executableInfo.st_mode & 0o111 != 0 else {
            throw AgentFailure(.storageFailed, "The running executable has an unsafe owner, link, or file mode.")
        }
        let volume = try app.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard volume.volumeIsReadOnly != true else { throw AgentFailure(.storageFailed, "Copy ShareX off the disk image before uninstalling.") }
        return Self(bundleURL: app, executableURL: executable, bundleIdentity: InstallationFileIdentity(appInfo),
                    executableIdentity: InstallationFileIdentity(executableInfo), parentIdentity: InstallationFileIdentity(parentInfo),
                    bundleIdentifier: bundleIdentifier)
    }

    public func revalidate() throws {
        let current = try Self.inspect(bundleURL: bundleURL, executableURL: executableURL, bundleIdentifier: bundleIdentifier)
        guard current.bundleIdentity == bundleIdentity, current.executableIdentity == executableIdentity,
              current.parentIdentity.device == parentIdentity.device, current.parentIdentity.inode == parentIdentity.inode else {
            throw AgentFailure(.storageFailed, "The app changed after review. Review the current installation before retrying.")
        }
    }
}

enum InstallationPaths {
    static func isPrivateUserDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o022 == 0
    }

    static func isSafeCommandFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1
            && info.st_mode & 0o022 == 0 && info.st_size <= 16_384
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw AgentFailure(.storageFailed, "Installation paths must be absolute local paths.")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot inspect the filesystem root.") }
        do {
            for component in url.pathComponents.dropFirst() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AgentFailure(.storageFailed, "A directory is missing, is a symbolic link, or cannot be opened at \(url.path).") }
                close(descriptor); descriptor = next
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      (info.st_uid == getuid() && info.st_mode & 0o022 == 0)
                        || (info.st_uid == 0 && (info.st_mode & 0o002 == 0 || info.st_mode & S_ISVTX != 0)) else {
                    throw AgentFailure(.storageFailed, "An installation folder is writable by other users or has an unexpected owner at \(url.path).")
                }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
}

extension AgentInstallation {
    public static func inspectCLI(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ManagedCLIStatus {
        try withCLIDirectory(home: home) { descriptor in
            guard let descriptor else { return .absent }
            return try inspectCLI(in: descriptor, executable: executable)
        }
    }

    public static func removeCLI(executable: URL, approved: ManagedCLIStatus,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try withCLIDirectory(home: home) { descriptor in
            guard let descriptor else { return }
            let current = try inspectCLI(in: descriptor, executable: executable)
            if current == .absent { return }
            guard current == approved else { throw AgentFailure(.storageFailed, "The CLI changed after review. Review it again before removal.") }
            guard case .owned(let identity) = current else { return }
            var immediate = stat()
            guard fstatat(descriptor, "sharex", &immediate, AT_SYMLINK_NOFOLLOW) == 0,
                  InstallationFileIdentity(immediate) == identity else {
                throw AgentFailure(.storageFailed, "The CLI changed during removal. No file was removed.")
            }
            guard unlinkat(descriptor, "sharex", 0) == 0 || errno == ENOENT else {
                throw AgentFailure(.storageFailed, "Cannot remove the owned ShareX CLI wrapper.")
            }
            guard fsync(descriptor) == 0 else { throw AgentFailure(.storageFailed, "Cannot synchronize the CLI folder after removal.") }
        }
    }

    private static func withCLIDirectory<T>(home: URL, body: (Int32?) throws -> T) throws -> T {
        var descriptor = try InstallationPaths.openDirectory(home)
        defer { close(descriptor) }
        for name in [".local", "bin"] {
            let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT { return try body(nil) }
            guard next >= 0 else { throw AgentFailure(.storageFailed, "CLI folders must be real directories. No CLI file was removed.") }
            close(descriptor); descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0, InstallationPaths.isPrivateUserDirectory(info) else {
                throw AgentFailure(.storageFailed, "CLI folders must be owned by you and not writable by other users.")
            }
        }
        return try body(descriptor)
    }

    private static func inspectCLI(in directory: Int32, executable: URL) throws -> ManagedCLIStatus {
        var original = stat()
        guard fstatat(directory, "sharex", &original, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .absent }
            throw AgentFailure(.storageFailed, "Cannot inspect the CLI wrapper.")
        }
        guard InstallationPaths.isSafeCommandFile(original) else {
            return .preserved("The command is not a single safe file owned by you.")
        }
        let descriptor = openat(directory, "sharex", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentFailure(.storageFailed, "Cannot open the CLI wrapper for review.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, InstallationFileIdentity(opened) == InstallationFileIdentity(original) else {
            throw AgentFailure(.storageFailed, "The CLI changed during review. Retry the review.")
        }
        let data = try handle.read(upToCount: 16_385) ?? Data()
        guard data == Data(wrapper(executable: executable).utf8) else {
            return .preserved("The command belongs to another installation or contains different content.")
        }
        return .owned(InstallationFileIdentity(opened))
    }
}
