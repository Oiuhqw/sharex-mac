import AppKit
import ShareXCore

/// The overlay/editor window. A non-activating panel: it takes key focus (Esc, Enter, tool hotkeys, typed
/// text) without ShareX becoming the active app, because macOS 14+ may decline NSApp.activate() when the
/// hotkey fires while another app is in front. Without this, keys went to the other app.
final class OverlayWindow: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backing, defer: flag)
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        worksWhenModal = true
    }
    override var canBecomeKey: Bool { true }
    // A non-activating panel must not become main; that would require activating the app.
    override var canBecomeMain: Bool { false }
}

/// How an editor session ended.
enum EditorOutcome {
    case cancelled
    case finished(EditorResult)
    /// Window picker: capture this window live, then edit it.
    case pickedWindow(WindowInfo)
}

/// One editor session. Either full-screen overlays (one per frozen display), or a single titled window
/// around an image that was not a display frame (a live window capture or a multi-display stitch).
@MainActor
final class OverlayController: NSObject, EditorViewDelegate, NSWindowDelegate {
    private struct Surface {
        let window: NSWindow
        let view: EditorView
        let displayID: CGDirectDisplayID
        /// Pixels per point of the delivered image (may differ from the view's scale for a scaled-down canvas).
        let outputScale: CGFloat
        /// Window picker only: pickable windows, parallel to the view's pick rects.
        let pickWindows: [WindowInfo]
    }

    private var surfaces: [Surface] = []
    /// E2E seam: the live windows and editors of this session.
    #if SHAREX_E2E
    var e2eSurfaces: [(window: NSWindow, view: EditorView)] { surfaces.map { ($0.window, $0.view) } }
    #endif
    private var completion: ((EditorOutcome) -> Void)?
    private let onStyles: ([ShapeKind: ShapeStyle]) -> Void
    /// Latest explicitly changed tool defaults across all surfaces. Untouched screens hold stale copies.
    private var latestStyles: [ShapeKind: ShapeStyle]
    private var previousApp: NSRunningApplication?

    /// Full-screen overlays. `preset` (display id + display top-left points) skips selection and opens the editor.
    init(frozen: [FrozenScreen], mode: SelectionMode, preset: Preset?, settings: AppSettings,
         onStyles: @escaping ([ShapeKind: ShapeStyle]) -> Void, completion: @escaping (EditorOutcome) -> Void) {
        self.completion = completion
        self.onStyles = onStyles
        self.latestStyles = settings.toolStyles
        super.init()
        let windowInfos = mode == .pickWindow || mode == .rectangle ? ScreenCapture.windows() : []
        for f in frozen {
            // With a preset only that display gets an overlay.
            if let preset, preset.displayID != f.displayID { continue }
            let sf = f.screen.frame
            let local = CGRect(origin: .zero, size: sf.size)
            var picks: [CGRect] = [], pickWindows: [WindowInfo] = []
            switch mode {
            case .pickMonitor: picks = [local]
            case .pickWindow, .rectangle:
                for w in windowInfos {
                    if let r = Geometry.clamp(Geometry.cocoaToDisplayTopLeft(w.frame, screenFrame: sf), to: local) {
                        picks.append(r); pickWindows.append(w)
                    }
                }
            default: break
            }
            let view = EditorView(frame: local, renderer: Renderer(frame: f.image, scale: f.scale), mode: mode,
                                  initialCrop: preset?.rect, styles: settings.toolStyles,
                                  showMagnifier: settings.options.showMagnifier, pickRects: picks,
                                  // Monitor picker with the editor off: a click delivers the display straight away.
                                  finishOnPick: mode == .pickMonitor && !settings.options.openEditor)
            let w = OverlayWindow(contentRect: sf, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(sf, display: false)
            w.level = .screenSaver
            w.isOpaque = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            add(w, view, displayID: f.displayID, outputScale: f.scale, pickWindows: pickWindows)
        }
    }

    struct Preset {
        let displayID: CGDirectDisplayID
        let rect: CGRect
    }

    /// A titled editor window around `image`, centred on `screen` and scaled down to fit when it is larger.
    /// The image sits on a transparent margin so the toolbar has room; the crop starts exactly on the image.
    init(canvas image: CGImage, scale: CGFloat, screen: NSScreen, title: String, settings: AppSettings,
         onStyles: @escaping ([ShapeKind: ShapeStyle]) -> Void, completion: @escaping (EditorOutcome) -> Void) {
        self.completion = completion
        self.onStyles = onStyles
        self.latestStyles = settings.toolStyles
        super.init()
        // The minimum keeps the vertical toolbar (style row ≈ 650 pt) inside the window. The review suggested
        // 560 × 240; that still clips Done/Cancel, so the floor is larger.
        let marginPt: CGFloat = 60, minPt = CGSize(width: 760, height: 420)
        let room = CGSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height - 80)
        // Image pixels per view point: the image's own scale (real size), or more when it must shrink to fit.
        let viewScale = max(scale, (CGFloat(image.width) / scale + 2 * marginPt) * scale / room.width,
                            (CGFloat(image.height) / scale + 2 * marginPt) * scale / room.height)
        let m = Int((marginPt * viewScale).rounded())
        let cw = max(image.width + 2 * m, Int(minPt.width * viewScale)), ch = max(image.height + 2 * m, Int(minPt.height * viewScale))
        let imageRect = PixelRect(x: (cw - image.width) / 2, y: (ch - image.height) / 2, w: image.width, h: image.height)
        guard let ctx = Imaging.context(width: cw, height: ch, flipped: true) else { return }
        Imaging.drawUpright(image, in: imageRect.cgRect, ctx: ctx)
        guard let canvas = ctx.makeImage() else { return }

        let size = CGSize(width: CGFloat(cw) / viewScale, height: CGFloat(ch) / viewScale)
        let renderer = Renderer(frame: canvas, scale: viewScale)
        renderer.smoothFrame = abs(viewScale - screen.backingScaleFactor) > 0.01
        let view = EditorView(frame: CGRect(origin: .zero, size: size), renderer: renderer,
                              mode: .rectangle, initialCrop: imageRect.points(scale: viewScale), styles: settings.toolStyles,
                              showMagnifier: false, pickRects: [], finishOnPick: false)
        let w = OverlayWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        w.title = title
        w.level = .floating
        w.backgroundColor = NSColor(white: 0.15, alpha: 1)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        let vf = screen.visibleFrame
        w.setFrameOrigin(CGPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
        add(w, view, displayID: ScreenCapture.displayID(of: screen), outputScale: scale, pickWindows: [])
    }

    private func add(_ w: NSWindow, _ view: EditorView, displayID: CGDirectDisplayID, outputScale: CGFloat, pickWindows: [WindowInfo]) {
        view.delegate = self
        // The overlay shows the frozen (possibly sensitive) frame; other apps' screen captures must not see it.
        // Our own freeze happens before any overlay exists, so this never affects what we capture.
        w.sharingType = .none
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.contentView = view
        surfaces.append(Surface(window: w, view: view, displayID: displayID, outputScale: outputScale, pickWindows: pickWindows))
    }

    func show() {
        // Nothing could be built (no matching display, or the canvas bitmap failed): end the session
        // instead of leaving the coordinator busy forever.
        guard !surfaces.isEmpty else { close(.cancelled); return }
        // Remember who had focus so it gets it back afterwards (and Active Window keeps working next time).
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        // Best effort only; key focus no longer depends on it (OverlayWindow is a non-activating panel).
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        for s in surfaces { s.window.orderFrontRegardless() }
        let key = surfaces.first { $0.window.frame.contains(mouse) } ?? surfaces.first
        key?.window.makeKey()
        if let key { key.window.makeFirstResponder(key.view) }
        // Every overlay shows the loupe from its first frame, wherever the cursor already is.
        for s in surfaces { s.view.syncMouse() }
        // Perf: the first frame is on screen once the window has displayed and the transaction is committed.
        key?.window.displayIfNeeded(); CATransaction.flush()
        Perf.stamp("overlay-shown")
    }

    private func close(_ outcome: EditorOutcome) {
        guard let c = completion else { return }
        completion = nil
        // Styles are saved whether the capture finished or was cancelled; they are preferences, not edits.
        if !surfaces.isEmpty { onStyles(latestStyles) }
        let closing = surfaces
        surfaces.removeAll()
        for s in closing { s.window.delegate = nil; s.window.orderOut(nil) }
        // We are inside the view's own mouse or key handler; release views on the next turn, not under it.
        Task { @MainActor in for s in closing { s.window.contentView = nil } }
        Focus.restore(previousApp)
        c(outcome)
    }

    private func surface(of v: EditorView) -> Surface? { surfaces.first { $0.view === v } }

    // MARK: EditorViewDelegate

    func editorDidChangeStyle(_ v: EditorView, kind: ShapeKind) {
        guard surface(of: v) != nil else { return }
        let style = v.doc.style(for: kind)
        latestStyles[kind] = style
        // Keep other surfaces' defaults current. Only preferences change, never existing marks or
        // their undo stacks, so a later width-only edit cannot restore an older screen's color.
        for s in surfaces where s.view !== v { s.view.rememberStyle(style, for: kind) }
    }

    func editorDidActivate(_ v: EditorView) {
        for s in surfaces where s.view !== v { s.view.deactivate() }
        surface(of: v)?.window.makeKey()
    }

    func editorDidEnterEditing(_ v: EditorView) {
        // One screen edits at a time; the others stop taking clicks so Enter can't be ambiguous.
        for s in surfaces where s.view !== v { s.view.deactivate(); s.window.ignoresMouseEvents = true }
    }

    func editorDidReturnToSelection(_ v: EditorView) {
        for s in surfaces { s.window.ignoresMouseEvents = false }
    }

    func editorDidPickWindow(_ v: EditorView, index i: Int) {
        guard let s = surface(of: v), i < s.pickWindows.count else { return }
        close(.pickedWindow(s.pickWindows[i]))
    }

    func editorDidFinish(_ v: EditorView, crop: CGRect, lasso: [CGPoint]?) {
        guard let s = surface(of: v),
              let image = Export.flatten(renderer: v.renderer, doc: v.doc, crop: crop, lasso: lasso) else { close(.cancelled); return }
        close(.finished(EditorResult(image: image, scale: s.outputScale, displayID: s.displayID, crop: crop)))
    }

    func editorDidCancel(_ v: EditorView) { close(.cancelled) }

    // The canvas window's close button.
    func windowWillClose(_ notification: Notification) { close(.cancelled) }
}

