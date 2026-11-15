import AppKit
import ShareXAgent
import SwiftUI

@MainActor
struct RecordingView: View {
    let service: AgentCaptureService
    @State private var targets: [CaptureTarget] = []
    @State private var selection: String?
    @State private var includeCursor = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record a screen or window").font(.title2.bold())
            Text("Silent H.264 MP4.")
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(targets, id: \.token) { target in
                    Label {
                        VStack(alignment: .leading) {
                            Text(target.name)
                            if let application = target.application {
                                Text(application).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: target.kind == .display ? "display" : "macwindow")
                    }
                    .tag(target.token)
                    .accessibilityIdentifier("recording.target.\(target.kind.rawValue).\(target.token)")
                }
            }
            .frame(minHeight: 170)
            .disabled(service.isRecording || loading || service.shuttingDown)
            HStack {
                Toggle("Include cursor", isOn: $includeCursor)
                    .accessibilityIdentifier("recording.cursor")
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                    .accessibilityIdentifier("recording.refresh")
            }
            .disabled(service.isRecording || loading || service.shuttingDown)
            Text(limits).font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(status(at: context.date)).font(.headline)
                    .accessibilityIdentifier("recording.status")
            }
            if let message = service.recordingError ?? service.recordingSnapshot?.failure?.message ?? error {
                Text(message).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !Permissions.hasScreenRecording {
                Button("Open Screen Recording Settings…") { Permissions.openSettings() }
            }
            HStack {
                if service.isRecording {
                    Button("Stop Recording") { Task { await service.stopActive() } }
                        .disabled(service.recordingState == .finalizing)
                        .accessibilityIdentifier("recording.stop")
                } else {
                    Button("Start Recording") {
                        guard let selection else { return }
                        error = nil
                        Task { await service.startManual(target: selection, includeCursor: includeCursor) }
                    }
                    .disabled(selection == nil || loading || service.shuttingDown)
                    .accessibilityIdentifier("recording.start")
                }
                Spacer()
                if let url = service.completedRecording {
                    Button("Reveal MP4") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .accessibilityIdentifier("recording.reveal")
                } else if let url = service.evidenceDirectory, service.recordingState?.isTerminal == true {
                    Button("Show Evidence Folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .accessibilityIdentifier("recording.reveal")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 440)
        .task { if targets.isEmpty { await refresh() } }
    }

    private var limits: String {
        let options = RecordingOptions(), limits = CaptureLimits()
        return "\(options.fps) fps · up to \(Int(options.maxDurationSeconds / 60)) minutes · \(options.maxBytes / 1_073_741_824) GiB · \(limits.maxWidthPixels) × \(limits.maxHeightPixels) · \(limits.diskReserveBytes / 1_048_576) MiB disk reserve"
    }

    private func status(at date: Date) -> String {
        switch service.recordingState {
        case .starting: return "Preparing recording…"
        case .recording:
            let seconds = max(0, Int(date.timeIntervalSince(service.recordingSnapshot?.startedAt ?? date)))
            return "\(service.recordingOrigin == .agent ? "Agent recording" : "Recording") · \(String(format: "%02d:%02d", seconds / 60, seconds % 60))"
        case .finalizing: return "Saving recording…"
        case .completed: return "Recording saved"
        case .failed: return "Recording failed. Evidence is preserved."
        case .interrupted: return "Recording interrupted. Evidence is preserved."
        case nil: return loading ? "Loading targets…" : "Choose a target, then start recording."
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            targets = try await service.recordingTargets()
            if !targets.contains(where: { $0.token == selection }) { selection = targets.first?.token }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
