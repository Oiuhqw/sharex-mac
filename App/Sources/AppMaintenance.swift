import AppKit
import Darwin
import Observation
import ShareXAgent
import SwiftUI

@MainActor
@Observable
final class AppMaintenance {
    static let bundleIdentifier = "com.sharexmac.ShareX"
    enum Action {
        case resetScreenRecording, uninstall
        var title: String { self == .uninstall ? "Uninstall ShareX" : "Reset Screen Recording Permission & Quit" }
    }
    struct Review {
        let action: Action
        let application: ManagedApplication?
        let executable: URL
        let cli: ManagedCLIStatus
        let details: [String]
    }
    enum State {
        case idle
        case reviewing(Review)
        case working(String)
        case failed(Action, String)
    }

    private(set) var state: State = .idle
    private(set) var completed: [String] = []
    private(set) var frozen = false
    @ObservationIgnored private let agent: AgentCaptureService
    @ObservationIgnored private let login: LaunchAtLogin
    @ObservationIgnored private let checkOwnership: () throws -> Void
    @ObservationIgnored private let freeze: () throws -> Void
    @ObservationIgnored private let quit: () -> Void
    @ObservationIgnored private var priorFailure: String?

    init(agent: AgentCaptureService, login: LaunchAtLogin, checkOwnership: @escaping () throws -> Void,
         freeze: @escaping () throws -> Void, quit: @escaping () -> Void) {
        self.agent = agent; self.login = login; self.checkOwnership = checkOwnership
        self.freeze = freeze; self.quit = quit
    }

    func review(_ action: Action) {
        do {
            try checkOwnership()
            guard Bundle.main.bundleIdentifier == Self.bundleIdentifier, let executable = Bundle.main.executableURL else {
                throw AgentFailure(.storageFailed, "The running app does not have the ShareX bundle identity.")
            }
            let application: ManagedApplication?
            let cli: ManagedCLIStatus
            var details: [String]
            if action == .uninstall {
                application = try ManagedApplication.inspect(bundleURL: Bundle.main.bundleURL, executableURL: executable,
                                                              bundleIdentifier: Self.bundleIdentifier)
                cli = try AgentInstallation.inspectCLI(executable: executable)
                details = ["Stop capture and save any active recording before cleanup.",
                           "Unregister ShareX from launch at login.",
                           cliDetail(cli),
                           "Clear preferences for \(Self.bundleIdentifier).",
                           "Reset all ShareX permissions for this macOS account.",
                           "Move this app to Trash: \(Bundle.main.bundleURL.path)"]
            } else {
                application = nil; cli = .absent
                details = ["Stop capture and save any active recording.",
                           "Reset Screen Recording permission only for \(Self.bundleIdentifier), then quit.",
                           "On the next launch, grant Screen Recording permission again. macOS may require another restart.",
                           "Keep the app, CLI, preferences, and launch-at-login setting."]
            }
            details += ["Keep all screenshots and all session folders at \(agent.capabilities.sessionRoot).",
                        "Keep all agent client configuration files. To remove a registration you created, run codex mcp remove sharex or claude mcp remove --scope user sharex in that client.",
                        "Permissions and preferences use this bundle ID across all installed ShareX copies. Close other running copies first."]
            if let priorFailure {
                details.insert("The previous attempt stopped: \(priorFailure) Review the completed actions below. Incomplete recording evidence is preserved. Confirm again to continue the remaining cleanup.", at: 0)
            }
            state = .reviewing(Review(action: action, application: application, executable: executable, cli: cli, details: details))
        } catch { state = .failed(action, error.localizedDescription) }
    }

    func cancel() {
        if frozen, let priorFailure {
            if case .reviewing(let review) = state { state = .failed(review.action, priorFailure) }
        } else { state = .idle }
    }

    func confirm(_ approved: Review) async {
        guard case .reviewing = state else { return }
        do {
            try checkOwnership()
            try approved.application?.revalidate()
            if approved.action == .uninstall {
                guard try AgentInstallation.inspectCLI(executable: approved.executable) == approved.cli else {
                    throw AgentFailure(.storageFailed, "The CLI changed after review. Retry to review the current command.")
                }
            }
            try freeze()
            frozen = true
            state = .working("Saving active work…")
            try await agent.quiesce()
            record("Capture stopped. Completed recordings are saved. Existing incomplete evidence is preserved.")
            if approved.action == .uninstall {
                state = .working("Removing launch-at-login registration…")
                try checkOwnership()
                try login.unregisterForRemoval()
                record("Launch at login is unregistered.")
                state = .working("Removing the managed CLI…")
                try AgentInstallation.removeCLI(executable: approved.executable, approved: approved.cli)
                if case .owned = approved.cli { record("Removed the exact ShareX CLI wrapper at ~/.local/bin/sharex.") }
                else { record(cliDetail(approved.cli)) }
                state = .working("Clearing ShareX preferences…")
                UserDefaults.standard.removePersistentDomain(forName: Self.bundleIdentifier)
                guard UserDefaults.standard.synchronize() else {
                    throw AgentFailure(.storageFailed, "ShareX preferences could not be synchronized. Retry before removing the app.")
                }
                record("ShareX preferences are cleared.")
            }
            state = .working("Resetting ShareX permissions…")
            try checkOwnership()
            let service = approved.action == .uninstall ? "All" : "ScreenCapture"
            try await Task.detached(priority: .utility) { try PermissionReset.run(service: service) }.value
            record("ShareX \(service == "All" ? "permissions are" : "Screen Recording permission is") reset.")
            if let application = approved.application {
                state = .working("Moving ShareX to Trash…")
                try checkOwnership()
                try application.revalidate()
                var destination: NSURL?
                try FileManager.default.trashItem(at: application.bundleURL, resultingItemURL: &destination)
                if let path = destination?.path { record("Moved the app to Trash: \(path)") }
                else { record("Moved the app to Trash.") }
            }
            quit()
        } catch {
            priorFailure = error.localizedDescription
            state = .failed(approved.action, error.localizedDescription)
        }
    }

    func quitAfterFailure() { quit() }

    private func record(_ message: String) {
        if !completed.contains(message) { completed.append(message) }
    }

    private func cliDetail(_ status: ManagedCLIStatus) -> String {
        switch status {
        case .absent: return "No CLI wrapper exists at ~/.local/bin/sharex."
        case .owned: return "Remove the exact ShareX CLI wrapper at ~/.local/bin/sharex."
        case .preserved(let reason): return "Keep ~/.local/bin/sharex. \(reason)"
        }
    }
}

private enum PermissionReset {
    static func run(service: String) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, "com.sharexmac.ShareX"]
        process.standardOutput = output; process.standardError = output
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw AgentFailure(.storageFailed, "Cannot prepare permission-reset output.")
        }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        func drain() {
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                if bytes.count < 8192 { bytes.append(contentsOf: buffer.prefix(min(count, 8192 - bytes.count))) }
            }
        }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            drain(); usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { drain(); usleep(20_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            throw AgentFailure(.storageFailed, "Permission reset exceeded 15 seconds. Retry the operation.")
        }
        drain()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentFailure(.storageFailed, "Permission reset failed (exit \(process.terminationStatus)). \(detail)")
        }
    }
}

@MainActor
struct MaintenanceView: View {
    let maintenance: AppMaintenance

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !maintenance.completed.isEmpty {
                SettingsSection("Completed actions") {
                    ForEach(maintenance.completed, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
            switch maintenance.state {
            case .idle:
                SettingsSection("Screen Recording permission") {
                    Text("Use this after an update if macOS no longer accepts your Screen Recording grant.")
                    Button("Reset Screen Recording Permission & Quit") { maintenance.review(.resetScreenRecording) }
                        .accessibilityIdentifier("maintenance.reset")
                }
                SettingsSection("Remove ShareX") {
                    Text("Review the exact app, command, preferences, and permissions to remove. Capture files stay on this Mac.")
                    Button("Uninstall ShareX…") { maintenance.review(.uninstall) }
                        .accessibilityIdentifier("maintenance.uninstall")
                }
            case .reviewing(let review):
                SettingsSection(review.action.title) {
                    ForEach(review.details, id: \.self) { Text($0).textSelection(.enabled) }
                    HStack {
                        Button("Cancel", role: .cancel) { maintenance.cancel() }
                            .accessibilityIdentifier("maintenance.cancel")
                        Spacer()
                        Button(review.action.title, role: .destructive) { Task { await maintenance.confirm(review) } }
                            .accessibilityIdentifier("maintenance.confirm")
                    }
                }
            case .working(let message):
                ProgressView(message)
                    .accessibilityIdentifier("maintenance.status")
            case .failed(let action, let message):
                SettingsSection("Maintenance stopped") {
                    Text(message).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("maintenance.error")
                    Text("Review completed actions before retrying. Captures and incomplete evidence stay on this Mac.")
                    HStack {
                        Button("Retry") { maintenance.review(action) }
                            .accessibilityIdentifier("maintenance.retry")
                        Button("Quit") { maintenance.quitAfterFailure() }
                            .accessibilityIdentifier("maintenance.quit")
                    }
                }
            }
        }
    }
}
