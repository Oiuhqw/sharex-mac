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
        let displays = NSScreen.screens.map { (id: ScreenCapture.displayID(of: $0), size: $0.frame.size) }
        // No usable last region yet (or its display is gone): behave like Region.
        let last = settings.value.lastRegion?.resolve(displays: displays)
        let style: CaptureStyle = req.style == .lastRegion && last == nil ? .region : req.style
        // Esc (or a click on the timer) during the delay cancels the capture.
        guard await Countdown.run(seconds: o.delaySeconds) else { return }

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
            guard let lr = last, let s = NSScreen.screens.first(where: { ScreenCapture.displayID(of: $0) == lr.id }) else { return }
            targets = [s]; preset = OverlayController.Preset(displayID: lr.id, rect: lr.rect)
        case .fullscreen where NSScreen.screens.count == 1:
            preset = full(underMouse)
        default: break
        }

        let frozen = try await ScreenCapture.freeze(targets, showCursor: o.showCursor)

        if style == .fullscreen, frozen.count > 1 {
            // All displays stitched into one image, edited in a window when the editor is on.
            let scale = frozen.map(\.scale).max() ?? 1
            guard let img = stitch(frozen) else { return }   // same scale StitchLayout picks
            if o.openEditor { openCanvas(img, scale: scale, screen: underMouse, title: "All displays") }
            else { await deliver(img, scale: scale, last: nil) }
            return
        }

        if let preset, !o.openEditor, let f = frozen.first(where: { $0.displayID == preset.displayID }) {
            let r = Renderer(frame: f.image, scale: f.scale)
            if let img = Export.flatten(renderer: r, doc: EditorDocument(), crop: preset.rect, lasso: nil) {
                await deliver(img, scale: f.scale,
                        last: style == .lastRegion ? LastRegion(displayID: preset.displayID, rect: preset.rect) : nil)
            }
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
                                       last: remember ? LastRegion(displayID: r.displayID, rect: r.crop) : nil)
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
        case CaptureError.windowGone:
            // Not a fault, but silent beeps leave the user guessing.
            NSApp.activate()
            #if SHAREX_E2E
            if E2E.suppressAlerts { E2E.alertsShown += 1; break }   // E2E seam: no modal on a headless runner
            #endif
            let a = NSAlert()
            a.messageText = "Window not captured"
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

    /// Places every display at its global position. Output uses the highest scale so Retina detail survives.
    private func stitch(_ frozen: [FrozenScreen]) -> CGImage? {
        // Placement and canvas size come from the core's StitchLayout (unit-tested and fuzzed).
        guard let layout = StitchLayout(frames: frozen.map(\.screen.frame), scales: frozen.map(\.scale)),
              let ctx = Imaging.context(width: layout.width, height: layout.height, flipped: true) else { return nil }
        ctx.scaleBy(x: layout.scale, y: layout.scale)
        ctx.interpolationQuality = .high
        for (f, r) in zip(frozen, layout.placements) { Imaging.drawUpright(f.image, in: r, ctx: ctx) }
        return ctx.makeImage()
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
