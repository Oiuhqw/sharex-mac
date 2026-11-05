import AppKit
import QuartzCore
import ShareXCore

@MainActor
final class EditorView: NSView {
    typealias Phase = EditorSession.Phase
    let session: EditorSession
    let viewport: CGRect
    let showMagnifier: Bool
    let safeTop: CGFloat
    var renderer: Renderer { session.renderer }
    var doc: EditorDocument { session.doc }
    var phase: Phase { session.phase }
    var lasso: [CGPoint]? { session.lasso }
    var styles: [ShapeKind: ShapeStyle] { doc.styles }
    var tool: Tool { doc.tool }
    var styleTarget: ShapeKind? { session.styleTarget }
    var bounds0: CGRect { session.bounds0 }
    private lazy var toolbar = ToolbarView(editor: self)
    private let frameView: FrameView
    private var annotationsView: AnnotationsView?
    private var liveView: LiveMarkView?
    private let chrome: ChromeView
    private var moveArea: NSTrackingArea?
    var toolbarBottom: CGFloat { toolbar.frame.maxY }

    init(frame: CGRect, session: EditorSession, viewport: CGRect, image: CGImage, showMagnifier: Bool, safeTop: CGFloat = 4) {
        self.session = session; self.viewport = viewport; self.showMagnifier = showMagnifier; self.safeTop = safeTop
        let local = CGRect(origin: .zero, size: frame.size)
        frameView = FrameView(frame: local, image: image, smooth: session.renderer.smoothFrame)
        chrome = ChromeView(frame: local)
        super.init(frame: frame)
        wantsLayer = true; layerContentsRedrawPolicy = .never; layer?.masksToBounds = true
        addSubview(frameView); addSubview(chrome); addSubview(toolbar)
        session.attach(self); refresh()
    }
    convenience init(frame: CGRect, renderer: Renderer, mode: SelectionMode, initialCrop: CGRect?, styles: [ShapeKind: ShapeStyle],
                     showMagnifier: Bool, pickRects: [CGRect], finishOnPick: Bool) {
        let session = EditorSession(renderer: renderer, mode: mode, initialCrop: initialCrop, styles: styles,
                                    pickRects: pickRects, finishOnPick: finishOnPick)
        self.init(frame: frame, session: session, viewport: CGRect(origin: .zero, size: frame.size),
                  image: renderer.source.tiles[0].image, showMagnifier: showMagnifier)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - viewport.minX, y: p.y - viewport.minY) }
    private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
    private func desktopPoint(for event: NSEvent) -> CGPoint {
        if let map = renderer.source.layout, let window = event.window ?? window {
            return map.point(cocoa: window.convertPoint(toScreen: event.locationInWindow))
        }
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + viewport.minX, y: p.y + viewport.minY)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveArea { removeTrackingArea(moveArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); moveArea = area
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { updateTrackingAreas(); syncMouse() } }
    func syncMouse() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { session.hover(at: CGPoint(x: p.x + viewport.minX, y: p.y + viewport.minY), from: self) }
    }
    func setTool(_ tool: Tool) { session.activate(self); session.setTool(tool) }
    func undo() { session.activate(self); session.undo() }
    func redo() { session.activate(self); session.redo() }
    func deleteSelection() { session.activate(self); session.deleteSelection() }
    func changeStyle(_ change: (inout ShapeStyle) -> Void) { session.activate(self); session.changeStyle(change) }
    func rememberStyle(_ style: ShapeStyle, for kind: ShapeKind) { session.rememberStyle(style, for: kind) }
    func finish() { session.activate(self); session.finish() }
    func cancel() { session.cancel() }
    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }
    @objc func copy(_ sender: Any?) { if phase == .editing { finish() } }
    override func mouseMoved(with event: NSEvent) { session.hover(at: desktopPoint(for: event), from: self) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { if !viewport.contains(desktopPoint(for: event)) { session.hover(at: nil, from: self) } }
    override func mouseDown(with event: NSEvent) { session.pointerDown(desktopPoint(for: event), clicks: event.clickCount, from: self) }
    override func mouseDragged(with event: NSEvent) { session.pointerDragged(desktopPoint(for: event), shift: event.modifierFlags.contains(.shift), from: self) }
    override func mouseUp(with event: NSEvent) { session.pointerUp(desktopPoint(for: event), shift: event.modifierFlags.contains(.shift), from: self) }
    override func rightMouseDown(with event: NSEvent) { session.secondary(desktopPoint(for: event), from: self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair); addCursorRect(toolbar.frame, cursor: .arrow) }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 53: cancel(); return                                   // Esc
        case 36, 76: if phase == .editing { finish() }; return       // Return, keypad Enter
        case 51, 117: if phase == .editing { deleteSelection() }; return
        case 123...126: session.nudge(e.keyCode, by: shift ? 10 : 1, resizing: e.modifierFlags.contains(.option)); return
        default: break
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return }
        if cmd {
            switch ch {
            case "z": shift ? redo() : undo()
            case "c": if phase == .editing { finish() }
            default: super.keyDown(with: e)
            }
            return
        }
        if phase == .editing, let t = Tool.forKey(ch) { setTool(t) }
    }


    func releaseResources() {
        liveView?.releaseResources(); chrome.releaseResources(); frameView.layer?.contents = nil
        toolbar.closePopover()
    }
    func invalidateAll() { annotationsView?.needsDisplay = true; liveView?.releaseResources() }
    func invalidateAnnotations(_ rect: CGRect) { annotationsView?.setNeedsDisplay(rect.intersection(viewport).integral) }
    func showFailures(_ rects: [CGRect]) { liveView?.showFailedMasks(rects) }
    func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        switch phase {
        case .selecting:
            annotationsView?.isHidden = true; liveView?.isHidden = true
            liveView?.show(nil, renderer: renderer)
        case .editing:
            if annotationsView == nil {
                let annotations = AnnotationsView(frame: bounds, renderer: renderer)
                annotations.bounds = viewport
                addSubview(annotations, positioned: .above, relativeTo: frameView); annotationsView = annotations
                let live = LiveMarkView(frame: bounds)
                live.layer?.sublayerTransform = CATransform3DMakeTranslation(-viewport.minX, -viewport.minY, 0)
                addSubview(live, positioned: .above, relativeTo: annotations); liveView = live
            }
            annotationsView?.isHidden = false; liveView?.isHidden = false
            let live = session.liveID.flatMap { id in doc.annotations.first { $0.id == id } }
            annotationsView?.sync(doc, hide: session.editingTextID, live: live?.id)
            if live == nil { annotationsView?.displayIfNeeded() }
            liveView?.show(live, renderer: renderer)
        case .ended: break
        }
        toolbar.sync(); toolbar.fit(maxWidth: max(1, bounds.width - 8))
        let size = toolbar.fittingSize
        toolbar.frame = CGRect(x: max(4, (bounds.width - size.width) / 2), y: safeTop, width: size.width, height: size.height)
        window?.invalidateCursorRects(for: self)
        chrome.reservedTop = toolbar.frame.maxY + 4
        refreshChrome()
    }
    func refreshChrome() {
        var state = ChromeView.State()
        switch phase {
        case .selecting(let mode):
            let hole = session.selectionHole.map(local)
            state.dimEverything = true; state.dimHole = hole.map { CGPath(rect: $0, transform: nil) }
            if let hole { state.outline = hole; state.sizeLabel = (hole, sizeText(session.selectionHole!)) }
            if mode == .lasso { state.lasso = lasso?.map(local) }
            if mode == .rectangle || mode == .lasso, let mouse = session.mouse, viewport.contains(mouse) {
                state.crosshair = local(mouse); setMagnifier(mouse, state: &state)
            }
        case .editing:
            let crop = doc.state.crop ?? bounds0, localCrop = local(crop)
            let hole = CGMutablePath()
            if let points = lasso { hole.addLines(between: points.map(local)); hole.closeSubpath() } else { hole.addRect(localCrop) }
            state.dimEverything = true; state.dimHole = hole; state.outline = localCrop
            if doc.tool == .crop { state.cropHandles = localCrop }
            if let selected = doc.selected { state.selection = local(selected.bounds) }
            if crop.intersects(viewport) { state.sizeLabel = (localCrop.intersection(bounds), sizeText(crop)) }
            if doc.tool == .crop, let mouse = session.mouse, viewport.contains(mouse) { setMagnifier(mouse, state: &state) }
        case .ended: break
        }
        chrome.apply(state)
    }
    private func setMagnifier(_ mouse: CGPoint, state: inout ChromeView.State) {
        guard showMagnifier else { return }
        let scale = renderer.scale, pixels = ChromeView.source(mouse, scale: scale)
        guard !renderer.sourceIsProtected(pixels) else { return }
        if renderer.source.tiles.count == 1 {
            chrome.setMagnifierSource(renderer.source.tiles[0].image)
        } else {
            let area = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
            guard let image = renderer.source.sample(area, scale: scale, maximumPixels: 1024) else { return }
            chrome.setMagnifierSource(image, originPixels: CGPoint(x: pixels.minX - viewport.minX * scale, y: pixels.minY - viewport.minY * scale))
        }
        state.magnifier = (local(mouse), scale)
    }
    private func sizeText(_ rect: CGRect) -> String {
        let scale = renderer.source.scale(for: rect) ?? renderer.scale
        let area = Geometry.pixelRect(rect, scale: scale)
        return "\(area.w) × \(area.h)"
    }
    #if SHAREX_E2E
    var e2eLoupe: (visible: Bool, frame: CGRect, label: String, contentsRect: CGRect, source: CGSize) { chrome.e2eLoupe }
    var e2eSizeLabel: String { chrome.e2eSizeLabel }
    var e2eAnnotationSyncCount: Int { annotationsView?.e2eSyncCount ?? 0 }
    var e2eLiveLayerBytes: Int { liveView?.e2eRetainedPatchBytes ?? 0 }
    var e2eToolbar: ToolbarView { toolbar }
    #endif
}
