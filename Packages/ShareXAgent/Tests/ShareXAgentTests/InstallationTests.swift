import Foundation
import Testing
@testable import ShareXAgent
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func installedWrapperPreservesAppPathAndArguments() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = home.appendingPathComponent("ShareX ' test $ app")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: executable)
    #expect(chmod(executable.path, 0o755) == 0)
    let wrapper = try AgentInstallation.install(executable: executable, home: home)
    let process = Process(), output = Pipe()
    process.executableURL = wrapper
    process.arguments = ["screenshot", "--target", "opaque token $(echo fail)"]
    process.standardOutput = output
    try process.run()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: result, as: UTF8.self) == "--agent\nscreenshot\n--target\nopaque token $(echo fail)\n")
    #expect(try AgentInstallation.install(executable: executable, home: home) == wrapper)
}

@Test func installationUpdatesOnlyManagedWrapper() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let first = URL(fileURLWithPath: "/bin/sh"), second = URL(fileURLWithPath: "/bin/echo")
    let wrapper = try AgentInstallation.install(executable: first, home: home)
    try AgentInstallation.install(executable: second, home: home)
    #expect(try String(contentsOf: wrapper, encoding: .utf8) == AgentInstallation.wrapper(executable: second))
    try Data("unrelated command".utf8).write(to: wrapper)
    #expect(throws: AgentFailure.self) { try AgentInstallation.install(executable: first, home: home) }
    #expect(try String(contentsOf: wrapper, encoding: .utf8) == "unrelated command")
}

@Test func installationRejectsSymlinkAndUnsafeDirectory() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let wrapper = try AgentInstallation.install(executable: executable, home: home)
    try FileManager.default.removeItem(at: wrapper)
    try FileManager.default.createSymbolicLink(at: wrapper, withDestinationURL: executable)
    #expect(throws: AgentFailure.self) { try AgentInstallation.install(executable: executable, home: home) }
    try FileManager.default.removeItem(at: wrapper)
    #expect(chmod(wrapper.deletingLastPathComponent().path, 0o777) == 0)
    #expect(throws: AgentFailure.self) { try AgentInstallation.install(executable: executable, home: home) }
}

@Test func registrationCommandsUseResolvedExecutableAndShellQuoting() {
    let executable = URL(fileURLWithPath: "/Applications/ShareX user's app.app/Contents/MacOS/ShareX")
    let quoted = "'/Applications/ShareX user'\"'\"'s app.app/Contents/MacOS/ShareX'"
    #expect(AgentInstallation.registrationCommand(client: "claude", executable: executable) == "claude mcp add --transport stdio --scope user sharex -- \(quoted) --agent mcp")
    #expect(AgentInstallation.registrationCommand(client: "codex", executable: executable) == "codex mcp add sharex -- \(quoted) --agent mcp")
}

@Test func removalDeletesOnlyExactOwnedWrapperAndIsRepeatable() throws {
    let home = try temporaryDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let wrapper = try AgentInstallation.install(executable: executable, home: home)
    let neighbor = wrapper.deletingLastPathComponent().appendingPathComponent("unrelated")
    try Data("keep this".utf8).write(to: neighbor)
    let approved = try AgentInstallation.inspectCLI(executable: executable, home: home)
    guard case .owned = approved else { Issue.record("Installed wrapper was not recognized"); return }
    try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home)
    try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home)
    #expect(!FileManager.default.fileExists(atPath: wrapper.path))
    #expect(try String(contentsOf: neighbor, encoding: .utf8) == "keep this")
    #expect(FileManager.default.fileExists(atPath: neighbor.deletingLastPathComponent().path))
}

@Test func removalPreservesForeignAndModifiedManagedCommands() throws {
    let home = try temporaryDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let wrapper = try AgentInstallation.install(executable: URL(fileURLWithPath: "/bin/echo"), home: home)
    for content in [try Data(contentsOf: wrapper), Data((AgentInstallation.wrapper(executable: executable) + "echo foreign\n").utf8)] {
        try content.write(to: wrapper)
        let approved = try AgentInstallation.inspectCLI(executable: executable, home: home)
        guard case .preserved = approved else { Issue.record("Foreign command was not preserved"); return }
        try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home)
        #expect(try Data(contentsOf: wrapper) == content)
    }
}

@Test func removalRejectsReplacementAfterReview() throws {
    let home = try temporaryDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let wrapper = try AgentInstallation.install(executable: executable, home: home)
    let approved = try AgentInstallation.inspectCLI(executable: executable, home: home)
    let replacement = home.appendingPathComponent("replacement")
    try Data(AgentInstallation.wrapper(executable: executable).utf8).write(to: replacement)
    #expect(chmod(replacement.path, 0o755) == 0)
    #expect(rename(replacement.path, wrapper.path) == 0)
    #expect(throws: AgentFailure.self) { try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home) }
    #expect(FileManager.default.fileExists(atPath: wrapper.path))
}

@Test func removalPreservesSymbolicAndHardLinkedCommands() throws {
    let home = try temporaryDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let wrapper = try AgentInstallation.install(executable: executable, home: home)
    let target = home.appendingPathComponent("preserved")
    try FileManager.default.moveItem(at: wrapper, to: target)
    for symbolic in [true, false] {
        if symbolic { try FileManager.default.createSymbolicLink(at: wrapper, withDestinationURL: target) }
        else { try FileManager.default.linkItem(at: target, to: wrapper) }
        let approved = try AgentInstallation.inspectCLI(executable: executable, home: home)
        guard case .preserved = approved else { Issue.record("Linked command was not preserved"); return }
        try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home)
        #expect(try Data(contentsOf: target) == Data(AgentInstallation.wrapper(executable: executable).utf8))
        #expect(FileManager.default.fileExists(atPath: wrapper.path))
        try FileManager.default.removeItem(at: wrapper)
    }
}

@Test func removalRejectsSymlinkParentsAndUnsafeDirectory() throws {
    let home = try temporaryDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let wrapper = try AgentInstallation.install(executable: executable, home: home)
    let approved = try AgentInstallation.inspectCLI(executable: executable, home: home)
    let bin = wrapper.deletingLastPathComponent(), moved = home.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: bin, to: moved)
    try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: moved)
    #expect(throws: AgentFailure.self) { try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home) }
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("sharex").path))
    try FileManager.default.removeItem(at: bin)
    try FileManager.default.moveItem(at: moved, to: bin)
    #expect(chmod(bin.path, 0o777) == 0)
    #expect(throws: AgentFailure.self) { try AgentInstallation.removeCLI(executable: executable, approved: approved, home: home) }
    #expect(FileManager.default.fileExists(atPath: wrapper.path))
}

#if canImport(Darwin)
@Test func applicationReviewRejectsChangedAndLinkedInstallations() throws {
    let home = try temporaryDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let app = home.appendingPathComponent("ShareX.app", isDirectory: true)
    let executable = app.appendingPathComponent("Contents/MacOS/ShareX")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": "com.sharexmac.ShareX", "CFBundleExecutable": "ShareX", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    #expect(chmod(executable.path, 0o755) == 0)
    let reviewed = try ManagedApplication.inspect(bundleURL: app, executableURL: executable, bundleIdentifier: "com.sharexmac.ShareX")
    try reviewed.revalidate()
    let linkedApp = home.appendingPathComponent("Linked.app", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedApp, withDestinationURL: app)
    #expect(throws: AgentFailure.self) {
        try ManagedApplication.inspect(bundleURL: linkedApp, executableURL: linkedApp.appendingPathComponent("Contents/MacOS/ShareX"), bundleIdentifier: "com.sharexmac.ShareX")
    }
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable, options: .atomic)
    #expect(chmod(executable.path, 0o755) == 0)
    #expect(throws: AgentFailure.self) { try reviewed.revalidate() }
    #expect(FileManager.default.fileExists(atPath: app.path))
}
#endif
