import AppKit
import ShareXCore

/// Runs one capture: permission → delay → freeze → overlay/editor → flatten → decorate → clipboard.
@MainActor
final class CaptureCoordinator {
    private let settings: SettingsStore
    private(set) var overlay: OverlayController?
    private(set) var busy = false

    init(settings: SettingsStore) { self.settings = settings }

    func capture(_ style: CaptureStyle) {
        guard !busy else { return }
        busy = true
        Perf.stamp("capture-start")
        Task { @MainActor in
            defer { if overlay == nil { busy = false } }
            do { try await run(CaptureRequest(style: style, options: settings.value.options)) }
            catch { report(error) }
        }
    }

    private func run(_ req: CaptureRequest) async throws {
        guard Permissions.requestScreenRecording() else { throw CaptureError.noPermission }
        let o = req.options
        // Esc (or a click on the timer) during the delay cancels the capture.
        guard await Countdown.run(seconds: o.delaySeconds) else { return }

        let layout = DesktopLayout(displays: NSScreen.screens.map {
            .init(id: ScreenCapture.displayID(of: $0), frame: $0.frame, scale: $0.backingScaleFactor)
        })
        let savedRegion = settings.value.lastRegion
        let last = layout.flatMap { savedRegion?.resolve(layout: $0) }
        var style: CaptureStyle = req.style == .lastRegion && last == nil ? .region : req.style

        let mouse = NSEvent.mouseLocation
        guard let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { throw CaptureError.noDisplays }
        let full = { (s: NSScreen) in OverlayController.Preset(displayID: ScreenCapture.displayID(of: s),
                                                               rect: CGRect(origin: .zero, size: s.frame.size)) }
        var targets = NSScreen.screens
        var preset: OverlayController.Preset?

        switch style {
        case .activeWindow:
            // Captured live and on its own, so overlapping windows and the overlay never get in the picture.
            guard let w = ScreenCapture.activeWindow() else { NSSound.beep(); return }
            try await editOrDeliver(window: w)
            return
        case .activeMonitor:
            targets = [underMouse]; preset = full(underMouse)
        case .lastRegion:
            guard let last, let layout else { return }
            let ids = Set(layout.participants(in: last).map(\.id))
            targets = targets.filter { ids.contains(ScreenCapture.displayID(of: $0)) }
        case .fullscreen where NSScreen.screens.count == 1:
            preset = full(underMouse)
        default: break
        }

        var frozen: [FrozenScreen]
        do { frozen = try await ScreenCapture.freeze(targets, showCursor: o.showCursor) }
        catch CaptureError.noDisplays where style == .lastRegion { frozen = [] }

        if style == .lastRegion {
            if matchesCurrentLayout(frozen), let map = DesktopImageSource(frozen: frozen)?.layout,
               let crop = savedRegion?.resolve(layout: map) {
                preset = OverlayController.Preset(displayID: 0, rect: crop, desktop: true)
            } else {
                style = .region
                frozen = try await ScreenCapture.freeze(NSScreen.screens, showCursor: o.showCursor)
            }
        }

        guard matchesCurrentLayout(frozen) else {
            throw CaptureError.captureFailed("The display layout changed. Start a new capture.")
        }
        guard let source = DesktopImageSource(frozen: frozen) else { throw CaptureError.imageTooLarge }
        if style == .fullscreen { preset = OverlayController.Preset(displayID: 0, rect: source.bounds, desktop: true) }
        if let preset, !o.openEditor {
            let crop: CGRect
            if preset.desktop { crop = preset.rect }
            else if let display = source.layout?.displays.first(where: { $0.id == preset.displayID }), let map = source.layout {
                let placement = map.placement(display)
                crop = preset.rect.offsetBy(dx: placement.minX, dy: placement.minY)
            } else { throw CaptureError.noDisplays }
            let scale = source.scale(for: crop) ?? 1
            let renderer = Renderer(source: source, scale: scale)
            guard let image = Export.flatten(renderer: renderer, doc: EditorDocument(), crop: crop, lasso: nil) else { throw CaptureError.imageTooLarge }
            await deliver(image, scale: scale, last: style == .lastRegion ? source.layout.flatMap { LastRegion(crop: crop, layout: $0) } : nil)
            return
        }

        let remember = [CaptureStyle.region, .freehand, .lastRegion].contains(style)
        present(OverlayController(frozen: frozen, mode: style.selection, preset: preset, settings: settings.value,
                                  onStyles: { [weak self] in self?.saveStyles($0) }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled: self.endSession()
            case .finished(let r):
                // The overlay is already gone; stay busy until the clipboard holds the image.
                self.overlay = nil
                Task { @MainActor in
                    await self.deliver(r.image, scale: r.scale,
                                       last: remember ? r.lastRegion : nil)
                    self.busy = false
                }
            case .pickedWindow(let w):
                self.overlay = nil   // stay busy: the live capture follows
                Task { @MainActor in
                    do { try await self.editOrDeliver(window: w) }
                    catch { self.report(error) }
                    if self.overlay == nil { self.busy = false }
                }
            }
        })
    }

    private func matchesCurrentLayout(_ frozen: [FrozenScreen]) -> Bool {
        let screens = NSScreen.screens
        return !frozen.isEmpty && frozen.allSatisfy { tile in
            screens.contains { ScreenCapture.displayID(of: $0) == tile.displayID
                && $0.frame == tile.frame && $0.backingScaleFactor == tile.scale }
        }
    }

    /// A window captured live with transparent corners; border and shadow are drawn around it like any capture.
    private func editOrDeliver(window w: WindowInfo) async throws {
        let shot = try await ScreenCapture.captureWindow(w)
        if settings.value.options.openEditor { openCanvas(shot.image, scale: shot.scale, screen: shot.screen, title: w.title) }
        else { await deliver(shot.image, scale: shot.scale, last: nil) }
    }

    private func openCanvas(_ image: CGImage, scale: CGFloat, screen: NSScreen, title: String) {
        present(OverlayController(canvas: image, scale: scale, screen: screen, title: title.isEmpty ? "ShareX" : title,
                                  settings: settings.value, onStyles: { [weak self] in self?.saveStyles($0) }) { [weak self] outcome in
            guard let self else { return }
            guard case .finished(let r) = outcome else { self.endSession(); return }
            self.overlay = nil
            Task { @MainActor in
                await self.deliver(r.image, scale: r.scale, last: nil)
                self.busy = false
            }
        })
    }

    /// Per-tool styles chosen in the editor become the next capture's defaults (and survive relaunch).
    private func saveStyles(_ styles: [ShapeKind: ShapeStyle]) {
        guard styles != settings.value.toolStyles else { return }
        settings.update { $0.toolStyles = styles }
    }

    private func present(_ c: OverlayController) {
        overlay = c
        c.show()
    }

    private func endSession() {
        overlay = nil
        busy = false
    }

    func report(_ error: Error) {
        // The alerts below activate ShareX. Afterwards give focus back to the user's app (unless the alert sent
        // them elsewhere, e.g. System Settings), or ShareX stays frontmost with no window and Active Window beeps.
        let previous = NSWorkspace.shared.frontmostApplication
        defer {
            if NSWorkspace.shared.frontmostApplication == .current {
                Focus.restore(previous)
            }
        }
        switch error {
        case CaptureError.noPermission: Permissions.showDeniedAlert()
        case CaptureError.windowGone, CaptureError.imageTooLarge, CaptureError.captureFailed:
            // Not a fault, but silent beeps leave the user guessing.
            NSApp.activate()
            #if SHAREX_E2E
            if E2E.suppressAlerts { E2E.alertsShown += 1; break }   // E2E seam: no modal on a headless runner
            #endif
            let a = NSAlert()
            a.messageText = "Screenshot could not be prepared"
            a.informativeText = error.localizedDescription
            a.runModal()
        default: NSSound.beep(); Log.capture.error("capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Decorate + PNG/TIFF encode run off the main thread; the pasteboard write is on main. The saved file is
    /// the clipboard's own PNG bytes, so the two can never differ.
    private func deliver(_ flat: CGImage, scale: CGFloat, last: LastRegion?) async {
        let s = settings.value
        let st = Perf.signposter.beginInterval("deliver")
        defer { Perf.signposter.endInterval("deliver", st) }
        let box = ImageBox(image: flat), opts = s.options
        let encoded = await Task.detached(priority: .userInitiated) { () -> Export.Encoded? in
            Export.encode(Export.decorateOffMain(box.image, options: opts, scale: scale), scale: scale)
        }.value
        guard let encoded else {
            let previous = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Screenshot could not be prepared"
            alert.informativeText = "No image was copied or saved. Try a smaller capture or close other apps to free memory."
            alert.runModal()
            if NSWorkspace.shared.frontmostApplication == .current { Focus.restore(previous) }
            return
        }
        let delivery = ExportDelivery(encoded: encoded, folder: s.saveToFile ? s.saveFolder : nil)
        await delivery.attempt()
        await delivery.finish(playSound: s.playSound)
        if delivery.hasOutput, let last { settings.update { $0.lastRegion = last } }
    }


}

/// Hand focus back to the app the user was in. If it is gone, terminated, or refuses activation, hide ShareX
/// so it never stays frontmost with no window (Active Window would then capture nothing and beep).
@MainActor enum Focus {
    static func restore(_ previous: NSRunningApplication?) {
        if let p = previous, p != .current, !p.isTerminated, p.activate() { return }
        NSApp.hide(nil)
    }
}
