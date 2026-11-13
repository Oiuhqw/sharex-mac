import AppKit
import ShareXAgent
import SwiftUI

@MainActor
struct AgentSetupView: View {
    let service: AgentCaptureService
    let serverError: String?
    @State private var permissionGranted = Permissions.hasScreenRecording
    @State private var setupMessage: String?
    @State private var setupFailed = false
    @State private var installing = false

    private var executable: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Local access") {
                Toggle("Enable local agent access", isOn: Binding(get: { service.enabled }, set: { service.setEnabled($0) }))
                    .disabled(serverError != nil)
                    .accessibilityIdentifier("settings.agents.enabled")
                Text("This lets programs running as your macOS user capture a selected screen, window, or region. Captures stay on this Mac. Audio is off.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Turning access off stops the active recording and saves its final state.")
                    .font(.caption).foregroundStyle(.secondary)
                if let serverError {
                    Label(serverError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("settings.agents.serverError")
                }
                if let session = service.recordingSnapshot, !session.state.isTerminal {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(session.state.agentStatusTitle, systemImage: "record.circle").foregroundStyle(.red)
                                .accessibilityIdentifier("settings.agents.recordingStatus")
                            Text(session.source.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                            .accessibilityIdentifier("settings.agents.recordingStatus")
                        Spacer()
                        Button("Stop Recording") { Task { await service.stopActive() } }
                            .disabled(session.state == .finalizing)
                            .accessibilityIdentifier("settings.agents.stop")
                    }
                }
            }
            SettingsSection("Screen Recording permission") {
                Label(permissionGranted ? "Permission is granted." : "Permission is required before capture.",
                      systemImage: permissionGranted ? "checkmark.circle" : "exclamationmark.triangle")
                    .accessibilityIdentifier("settings.agents.permissionStatus")
                Text("Allow ShareX in Privacy & Security > Screen & System Audio Recording. If macOS requests it, quit and reopen ShareX after the change.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Request Permission") { permissionGranted = Permissions.requestScreenRecording() }
                        .disabled(permissionGranted)
                        .accessibilityIdentifier("settings.agents.requestPermission")
                    Button("Open System Settings…") { Permissions.openSettings() }
                        .accessibilityIdentifier("settings.agents.openPermissionSettings")
                }
            }
            SettingsSection("Command line") {
                Text("Install the sharex command for your user. Run this step again if you move the app.")
                    .font(.callout)
                Button(installing ? "Installing…" : "Install or Update CLI") { installCLI() }
                    .disabled(installing || executable == nil)
                    .accessibilityIdentifier("settings.agents.installCLI")
                Text("The command is saved at ~/.local/bin/sharex. If your shell cannot find it, add this line to ~/.zshrc and open a new terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                codeLine("export PATH=\"$HOME/.local/bin:$PATH\"", id: "path")
                codeLine("sharex capabilities", id: "verify")
                if let setupMessage {
                    Label(setupMessage, systemImage: setupFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.callout).foregroundStyle(setupFailed ? Color.orange : Color.secondary)
                        .textSelection(.enabled).accessibilityIdentifier("settings.agents.setupStatus")
                }
            }
            SettingsSection("Connect an agent") {
                Text("Copy a command into your terminal. Restart the agent client after registration. These commands use this app's path and do not require the CLI wrapper.")
                    .font(.callout).foregroundStyle(.secondary)
                if let executable {
                    Text("Claude Code").fontWeight(.medium)
                    codeLine(AgentInstallation.registrationCommand(client: "claude", executable: executable), id: "claude")
                    Text("Codex").fontWeight(.medium)
                    codeLine(AgentInstallation.registrationCommand(client: "codex", executable: executable), id: "codex")
                }
            }
            SettingsSection("Evidence files") {
                Text(service.capabilities.sessionRoot).font(.callout.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("settings.agents.sessionRoot")
                Text("Each session contains PNG screenshots, a silent H.264 MP4 when recorded, and a JSON manifest with file hashes. Agent capture does not open the editor or change your clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { permissionGranted = Permissions.hasScreenRecording }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionGranted = Permissions.hasScreenRecording
        }
    }

    private func codeLine(_ command: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.agents.command.\(id)")
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                setupFailed = false
                setupMessage = "Copied the \(id == "path" ? "PATH" : id) command."
            }
            .accessibilityLabel("Copy \(id) command")
            .accessibilityIdentifier("settings.agents.copy.\(id)")
        }
        .padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func installCLI() {
        guard let executable else { return }
        installing = true
        Task {
            let result = await Task.detached { Result { try AgentInstallation.install(executable: executable) } }.value
            installing = false
            switch result {
            case .success(let path): setupFailed = false; setupMessage = "Installed \(path.path)."
            case .failure(let error): setupFailed = true; setupMessage = error.localizedDescription
            }
        }
    }
}

extension RecordingState {
    var agentStatusTitle: String {
        switch self {
        case .starting: "Starting agent recording…"
        case .recording: "Agent recording is active"
        case .finalizing: "Saving agent recording…"
        case .completed: "Agent recording saved"
        case .failed: "Agent recording failed"
        case .interrupted: "Agent recording interrupted"
        }
    }
}
