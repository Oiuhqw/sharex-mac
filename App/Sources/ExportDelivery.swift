import AppKit
import ShareXCore
import UniformTypeIdentifiers

/// Keeps the encoded capture alive while the user recovers a failed output. Retrying only writes the
/// destinations that failed: it never duplicates a successful save or replaces a successful clipboard copy.
@MainActor
final class ExportDelivery {
    let encoded: Export.Encoded
    let folder: String?
    private(set) var copied = false
    private(set) var savedURL: URL?

    init(encoded: Export.Encoded, folder: String?) {
        self.encoded = encoded
        self.folder = folder
    }

    var filePending: Bool { folder != nil && savedURL == nil }
    var complete: Bool { copied && !filePending }
    var hasOutput: Bool { copied || savedURL != nil }

    func attempt() async {
        if !copied {
            copied = Export.write(encoded)
            if copied { Perf.stamp("clipboard-ready") }
        }
        // File export is deliberately independent of the clipboard result.
        if let folder, savedURL == nil { savedURL = await Export.savePNGData(encoded.png, folder: folder) }
    }

    @discardableResult
    func saveAs(to url: URL) async -> Bool {
        guard await Export.savePNGData(encoded.png, to: url) else { return false }
        savedURL = url
        return true
    }

    var failureTitle: String {
        if copied { return "Screenshot copied, but not saved" }
        if savedURL != nil { return "Screenshot saved, but not copied" }
        return "Screenshot could not be exported"
    }

    var failureDetail: String {
        var lines: [String] = []
        lines.append(copied ? "The screenshot is on the clipboard." : "The screenshot could not be copied to the clipboard.")
        if let savedURL { lines.append("Saved to: \(savedURL.path)") }
        else if let folder {
            let destination = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("The PNG could not be saved to \(destination.isEmpty ? "~/Pictures/ShareX" : destination). Check the folder permissions and available disk space.")
        }
        lines.append("Retry the failed output, or choose Save As to keep the screenshot in another location.")
        return lines.joined(separator: "\n\n")
    }

    enum Action { case retry, saveAs, dismiss }

    /// The regular success sound only plays once every requested output has succeeded.
    func finish(playSound: Bool) async {
        if !complete { await recover() }
        guard complete, playSound else { return }
        #if SHAREX_E2E
        if E2E.enabled { E2EExport.successSounds += 1; return }
        #endif
        NSSound(named: "Tink")?.play()
    }

    private func recover() async {
        let previous = NSWorkspace.shared.frontmostApplication
        defer {
            if NSWorkspace.shared.frontmostApplication == .current { Focus.restore(previous) }
        }
        while !complete {
            NSApp.activate()
            switch showFailure() {
            case .retry: await attempt()
            case .saveAs:
                guard let url = chooseDestination() else { continue }
                if !(await saveAs(to: url)) {
                    // Preserve the original failure and the encoded image for another retry.
                    showSaveFailure()
                }
            case .dismiss: return
            }
        }
    }

    private func showFailure() -> Action {
        #if SHAREX_E2E
        if let respond = E2EExport.respond { return respond(self) }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failureTitle
        alert.informativeText = failureDetail
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: hasOutput ? "Done" : "Discard")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .saveAs
        default: return .dismiss
        }
    }

    private func chooseDestination() -> URL? {
        #if SHAREX_E2E
        if let choose = E2EExport.chooseDestination { return choose() }
        #endif
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = AppSettings.fileName(for: Date())
        panel.directoryURL = Export.resolveFolder(folder ?? "", create: false)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func showSaveFailure() {
        #if SHAREX_E2E
        if E2E.enabled { E2EExport.saveAlerts += 1; return }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PNG could not be saved"
        alert.informativeText = "Check the destination's permissions and available disk space, or choose another location. Your screenshot is still available to retry."
        alert.runModal()
    }
}
