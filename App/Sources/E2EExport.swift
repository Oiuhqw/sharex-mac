#if SHAREX_E2E
import AppKit
import ShareXCore

/// Failure injection uses the shipped delivery and recovery logic. Only modal responses and failed I/O
/// are substituted; successful clipboard writes, PNG writes and image encoding use the real APIs.
@MainActor
enum E2EExport {
    static var respond: ((ExportDelivery) -> ExportDelivery.Action)?
    static var chooseDestination: (() -> URL?)?
    static var successSounds = 0
    static var saveAlerts = 0

    static func run() async {
        let fm = FileManager.default
        let root = E2E.out.appendingPathComponent("export-regressions")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let image = E2E.checker(96, 80), let encoded = Export.encode(image, scale: 2) else {
            E2E.record("export-regressions-setup", false); return
        }
        let original = E2E.app.settings.value
        defer {
            Export.e2eRejectClipboard = false
            Export.e2eRejectFile = false
            respond = nil; chooseDestination = nil
            E2E.setOpts { $0 = original }
        }
        func files(_ folder: String) -> [String] { (try? fm.contentsOfDirectory(atPath: folder)) ?? [] }
        func session(_ name: String, save: Bool = true) -> ExportDelivery {
            Export.e2eRejectClipboard = false; Export.e2eRejectFile = false
            successSounds = 0; saveAlerts = 0
            respond = { _ in .dismiss }; chooseDestination = nil
            return ExportDelivery(encoded: encoded, folder: save ? root.appendingPathComponent(name).path : nil)
        }

        let both = session("both")
        await both.attempt(); await both.finish(playSound: true)
        let disk = both.savedURL.flatMap { try? Data(contentsOf: $0) }
        E2E.record("export-both-success", both.complete && successSounds == 1 && disk == encoded.png
                   && NSPasteboard.general.data(forType: .png) == encoded.png)

        let clipboardOnly = session("clipboard-only", save: false)
        await clipboardOnly.attempt(); await clipboardOnly.finish(playSound: false)
        E2E.record("export-clipboard-only", clipboardOnly.complete && clipboardOnly.savedURL == nil && successSounds == 0)

        let copyFailed = session("copy-failed")
        Export.e2eRejectClipboard = true
        await copyFailed.attempt()
        let saved = copyFailed.savedURL
        await copyFailed.finish(playSound: true)
        E2E.record("export-copy-failure-still-saves", !copyFailed.copied && copyFailed.hasOutput && !copyFailed.complete
                   && saved.flatMap { try? Data(contentsOf: $0) } == encoded.png
                   && copyFailed.failureTitle == "Screenshot saved, but not copied" && successSounds == 0)
        var prompts = 0
        respond = { _ in
            prompts += 1; Export.e2eRejectClipboard = false
            return prompts == 1 ? .retry : .dismiss
        }
        await copyFailed.finish(playSound: true)
        E2E.record("export-retry-copy-no-duplicate-file", copyFailed.complete && copyFailed.savedURL == saved
                   && files(copyFailed.folder!).count == 1 && prompts == 1 && successSounds == 1
                   && NSPasteboard.general.data(forType: .tiff) == encoded.tiff)

        let saveFailed = session("save-failed")
        Export.e2eRejectFile = true
        await saveFailed.attempt()
        let change = NSPasteboard.general.changeCount
        await saveFailed.finish(playSound: true)
        E2E.record("export-save-failure-keeps-clipboard", saveFailed.copied && saveFailed.filePending
                   && saveFailed.failureTitle == "Screenshot copied, but not saved" && successSounds == 0
                   && NSPasteboard.general.data(forType: .png) == encoded.png)
        prompts = 0
        respond = { _ in
            prompts += 1; Export.e2eRejectFile = false
            return prompts == 1 ? .retry : .dismiss
        }
        await saveFailed.finish(playSound: true)
        E2E.record("export-retry-save-preserves-clipboard", saveFailed.complete && successSounds == 1 && prompts == 1
                   && NSPasteboard.general.changeCount == change && files(saveFailed.folder!).count == 1)

        let neither = session("neither")
        Export.e2eRejectClipboard = true; Export.e2eRejectFile = true
        await neither.attempt(); await neither.finish(playSound: true)
        E2E.record("export-total-failure-no-success-sound", !neither.hasOutput && !neither.complete && successSounds == 0
                   && neither.failureTitle == "Screenshot could not be exported" && files(neither.folder!).isEmpty)
        let rescued = root.appendingPathComponent("rescued.png")
        prompts = 0
        respond = { _ in prompts += 1; return prompts == 1 ? .saveAs : .dismiss }
        chooseDestination = { rescued }
        await neither.finish(playSound: true)
        E2E.record("export-save-as-rescues-total-failure", neither.savedURL == rescued && neither.hasOutput
                   && !neither.copied && successSounds == 0 && (try? Data(contentsOf: rescued)) == encoded.png)

        let blocked = root.appendingPathComponent("not-a-directory")
        try? Data("block".utf8).write(to: blocked)
        _ = session("reset")
        let invalid = ExportDelivery(encoded: encoded, folder: blocked.path)
        await invalid.attempt()
        E2E.record("export-invalid-folder-visible", invalid.copied && invalid.filePending
                   && invalid.failureDetail.contains(blocked.path)
                   && Export.resolveFolder("relative-folder", create: false) == nil)
        let alternate = root.appendingPathComponent("alternate.png")
        prompts = 0
        respond = { _ in prompts += 1; return prompts <= 2 ? .saveAs : .dismiss }
        chooseDestination = { prompts == 1 ? blocked.appendingPathComponent("failed.png") : alternate }
        await invalid.finish(playSound: true)
        E2E.record("export-save-as-retries-invalid-destination", invalid.complete && saveAlerts == 1 && successSounds == 1
                   && invalid.savedURL == alternate && (try? Data(contentsOf: alternate)) == encoded.png)

        let cancelled = session("save-panel-cancel")
        Export.e2eRejectFile = true
        await cancelled.attempt()
        prompts = 0
        respond = { _ in prompts += 1; return prompts == 1 ? .saveAs : .dismiss }
        chooseDestination = { nil }
        await cancelled.finish(playSound: true)
        E2E.record("export-save-panel-cancel-keeps-image", cancelled.copied && cancelled.savedURL == nil
                   && prompts == 2 && successSounds == 0 && NSPasteboard.general.data(forType: .png) == encoded.png)

        // Full coordinator integration: a failed clipboard must still save, remember Last Region, release
        // busy and avoid playing the success sound when the user dismisses the partial-failure alert.
        _ = session("coordinator")
        let target = root.appendingPathComponent("coordinator").path
        var title = ""
        respond = { delivery in title = delivery.failureTitle; return .dismiss }
        Export.e2eRejectClipboard = true
        E2E.setOpts { s in
            s.saveToFile = true; s.saveFolder = target; s.playSound = true; s.lastRegion = nil
            s.options.delaySeconds = 0; s.options.openEditor = true
        }
        E2E.coord.capture(.region)
        if await E2E.until({ E2E.surface() != nil }) {
            E2E.drag(CGPoint(x: 120, y: 120), CGPoint(x: 320, y: 280))
            E2E.ret()
        }
        let idle = await E2E.until({ !E2E.coord.busy })
        E2E.record("export-coordinator-partial-failure", idle && files(target).count == 1
                   && E2E.app.settings.value.lastRegion != nil && successSounds == 0
                   && title == "Screenshot saved, but not copied")
        if !idle { E2E.esc() }

        let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String
        E2E.record("application-icon", iconName == "AppIcon"
                   && Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
    }
}
#endif
