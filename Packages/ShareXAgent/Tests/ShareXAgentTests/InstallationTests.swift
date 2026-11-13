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
