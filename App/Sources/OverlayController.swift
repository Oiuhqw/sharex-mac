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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let editor = contentView as? EditorView {
            editor.cancel()
            return
        }
        super.sendEvent(event)
    }
}

/// How an editor session ended.
enum EditorOutcome {
    case cancelled
    case finished(EditorResult)
    /// Window picker: capture this window live, then edit it.
    case pickedWindow(WindowInfo)
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private struct Surface { let window: NSWindow; let view: EditorView }
    private var surfaces: [Surface] = []
    private(set) var session: EditorSession?
    private var completion: ((EditorOutcome) -> Void)?
    private let onStyles: ([ShapeKind: ShapeStyle]) -> Void
    private var previousApp: NSRunningApplication?
    private var escapeMonitor: Any?
    private var preparationFailed = false
    private var topologyObserver: NSObjectProtocol?
    #if SHAREX_E2E
    static var e2eDeclineActivation = false
    var e2eSurfaces: [(window: NSWindow, view: EditorView)] { surfaces.map { ($0.window, $0.view) } }
    #endif

    struct Preset {
        let displayID: CGDirectDisplayID
        let rect: CGRect
        var desktop = false
    }

    init(frozen: [FrozenScreen], mode: SelectionMode, preset: Preset?, settings: AppSettings,
         onStyles: @escaping ([ShapeKind: ShapeStyle]) -> Void, completion: @escaping (EditorOutcome) -> Void) {
        self.completion = completion; self.onStyles = onStyles
        super.init()
        guard let source = DesktopImageSource(frozen: frozen), let map = source.layout else { preparationFailed = true; return }
        let initial: CGRect?
        if let preset {
            if preset.desktop { initial = source.selection(preset.rect) }
            else if let display = map.displays.first(where: { $0.id == preset.displayID }) {
                let placement = map.placement(display)
                initial = source.selection(preset.rect.offsetBy(dx: placement.minX, dy: placement.minY))
            } else { initial = nil }
        } else { initial = nil }
        let windows = ScreenCapture.windows().filter { map.bounds.intersects(Geometry.cocoaToDisplayTopLeft($0.frame, screenFrame: map.cocoaBounds)) }
        let picks = windows.map { Geometry.cocoaToDisplayTopLeft($0.frame, screenFrame: map.cocoaBounds).intersection(map.bounds) }
        let renderer = Renderer(source: source, scale: source.scale(for: initial ?? source.bounds) ?? 1)
        let session = EditorSession(renderer: renderer, mode: mode, initialCrop: initial, styles: settings.toolStyles,
                                    pickRects: picks, windows: windows, finishOnPick: !settings.options.openEditor)
        install(session)
        for (index, frozen) in frozen.enumerated() {
            let display = map.displays[index], frame = display.frame, viewport = map.placement(display)
            let view = EditorView(frame: CGRect(origin: .zero, size: frame.size), session: session, viewport: viewport,
                                  image: frozen.image, showMagnifier: settings.options.showMagnifier,
                                  safeTop: max(4, frozen.screen.safeAreaInsets.top + 4))
            let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(frame, display: false); window.level = .screenSaver; window.isOpaque = true; window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            add(window, view)
        }
        let topology = NSScreen.screens.map { DesktopLayout.Display(id: ScreenCapture.displayID(of: $0), frame: $0.frame, scale: $0.backingScaleFactor) }
        topologyObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let current = NSScreen.screens.map { DesktopLayout.Display(id: ScreenCapture.displayID(of: $0), frame: $0.frame, scale: $0.backingScaleFactor) }
                if current != topology { self?.session?.cancel() }
            }
        }
    }

    private func install(_ session: EditorSession) {
        self.session = session
        session.completion = { [weak self] in self?.close($0) }
    }

    /// A titled editor window around `image`, centred on `screen` and scaled down to fit when it is larger.
    /// The image sits on a transparent margin so the toolbar has room; the crop starts exactly on the image.
    init(canvas image: CGImage, scale: CGFloat, screen: NSScreen, title: String, settings: AppSettings,
         onStyles: @escaping ([ShapeKind: ShapeStyle]) -> Void, completion: @escaping (EditorOutcome) -> Void) {
        self.completion = completion
        self.onStyles = onStyles
        super.init()
        let marginPt: CGFloat = 60, minPt = CGSize(width: 760, height: 420)
        let room = CGSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height - 80)
        preparationFailed = true
        guard Imaging.accepts(image), scale.isFinite, scale > 0, room.width > 0, room.height > 0 else { return }
        // Image pixels per view point: the image's own scale (real size), or more when it must shrink to fit.
        let viewScale = max(scale, (CGFloat(image.width) / scale + 2 * marginPt) * scale / room.width,
                            (CGFloat(image.height) / scale + 2 * marginPt) * scale / room.height)
        let margin = (marginPt * viewScale).rounded()
        let padded = CGSize(width: max(CGFloat(image.width) + 2 * margin, ceil(minPt.width * viewScale)),
                            height: max(CGFloat(image.height) + 2 * margin, ceil(minPt.height * viewScale)))
        guard let dimensions = Imaging.pixelDimensions(size: padded, scale: 1) else { return }
        let cw = dimensions.width, ch = dimensions.height
        let imageRect = PixelRect(x: (cw - image.width) / 2, y: (ch - image.height) / 2, w: image.width, h: image.height)
        guard let ctx = Imaging.context(width: cw, height: ch, flipped: true) else { return }
        Imaging.drawUpright(image, in: imageRect.cgRect, ctx: ctx)
        guard let canvas = ctx.makeImage() else { return }

        let size = CGSize(width: CGFloat(cw) / viewScale, height: CGFloat(ch) / viewScale)
        let renderer = Renderer(frame: canvas, scale: viewScale)
        renderer.smoothFrame = abs(viewScale - screen.backingScaleFactor) > 0.01
        let session = EditorSession(renderer: renderer, mode: .rectangle, initialCrop: imageRect.points(scale: viewScale),
                                    styles: settings.toolStyles, pickRects: [], finishOnPick: false, outputScale: scale)
        install(session)
        let view = EditorView(frame: CGRect(origin: .zero, size: size), session: session,
                              viewport: CGRect(origin: .zero, size: size), image: canvas, showMagnifier: settings.options.showMagnifier)
        let w = OverlayWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        w.title = title
        w.level = .floating
        w.backgroundColor = NSColor(white: 0.15, alpha: 1)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        let vf = screen.visibleFrame
        w.setFrameOrigin(CGPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
        add(w, view)
        preparationFailed = false
    }


    private func add(_ window: NSWindow, _ view: EditorView) {
        window.sharingType = .none; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true; window.contentView = view; window.delegate = self
        surfaces.append(Surface(window: window, view: view))
    }

    func show() {
        // Nothing could be built (no matching display, or the canvas bitmap failed): end the session
        // instead of leaving the coordinator busy forever.
        guard !surfaces.isEmpty else {
            if preparationFailed { reportPreparationFailure() }
            close(.cancelled); return
        }
        // Popovers have their own window and responder. Esc still ends the whole capture.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let cancelled = MainActor.assumeIsolated {
                guard let self, self.completion != nil else { return false }
                self.session?.cancel()
                return true
            }
            return cancelled ? nil : event
        }
        // Remember who had focus so it gets it back afterwards (and Active Window keeps working next time).
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        // Best effort only; key focus no longer depends on it (OverlayWindow is a non-activating panel).
        #if SHAREX_E2E
        if !Self.e2eDeclineActivation { NSApp.activate() }
        #else
        NSApp.activate()
        #endif
        let mouse = NSEvent.mouseLocation
        for s in surfaces { s.window.orderFrontRegardless() }
        let key = surfaces.first { $0.window.frame.contains(mouse) } ?? surfaces.first
        key?.window.makeKey()
        if let key { session?.activate(key.view); key.window.makeFirstResponder(key.view) }
        // Every overlay shows the loupe from its first frame, wherever the cursor already is.
        for s in surfaces { s.view.syncMouse() }
        // Perf: the first frame is on screen once the window has displayed and the transaction is committed.
        key?.window.displayIfNeeded(); CATransaction.flush()
        Perf.stamp("overlay-shown")
    }

    private func close(_ outcome: EditorOutcome) {
        guard let c = completion else { return }
        completion = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let topologyObserver { NotificationCenter.default.removeObserver(topologyObserver) }; topologyObserver = nil
        // Styles are saved whether the capture finished or was cancelled; they are preferences, not edits.
        if !surfaces.isEmpty { onStyles(session?.doc.styles ?? [:]) }
        let closing = surfaces
        surfaces.removeAll()
        for s in closing { s.view.releaseResources(); s.window.delegate = nil; s.window.orderOut(nil) }
        // We are inside the view's own mouse or key handler; release views on the next turn, not under it.
        Task { @MainActor in for s in closing { s.window.contentView = nil } }
        Focus.restore(previousApp)
        c(outcome)
    }


    private func reportPreparationFailure() {
        #if SHAREX_E2E
        if E2E.suppressAlerts { E2E.alertsShown += 1; return }
        #endif
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Screenshot could not be prepared"
        alert.informativeText = "No image was copied or saved. Try a smaller capture or close other apps to free memory."
        alert.runModal()
    }
    func windowWillClose(_ notification: Notification) { session?.cancel() }
}
