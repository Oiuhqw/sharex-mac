import AppKit
import ShareXCore

/// What the overlay produced when the user pressed Enter.
struct EditorResult {
    let image: CGImage          // flattened, undecorated, full resolution
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    let crop: CGRect            // display top-left points
}

@MainActor
protocol EditorViewDelegate: AnyObject {
    func editorDidActivate(_ v: EditorView)
    /// Persist only this editor's actual style changes, not untouched copies on other displays.
    func editorDidChangeStyle(_ v: EditorView, kind: ShapeKind)
    /// The view left selection and is now editing; other screens must stop taking input.
    func editorDidEnterEditing(_ v: EditorView)
    /// Right-click reset the view back to selection.
    func editorDidReturnToSelection(_ v: EditorView)
    /// Window picker: the user clicked pick rect `index`. The window is captured live.
    func editorDidPickWindow(_ v: EditorView, index: Int)
    func editorDidFinish(_ v: EditorView, crop: CGRect, lasso: [CGPoint]?)
    func editorDidCancel(_ v: EditorView)
}

/// Full-screen view over one frozen display: selection first, then ShareX-style annotation in place.
/// Coordinates are this display's top-left points (the view is flipped and covers the screen).
@MainActor
final class EditorView: NSView, NSTextFieldDelegate {
    enum Phase: Equatable { case selecting(SelectionMode), editing }

    private enum Drag {
        case none
        case region(start: CGPoint)
        case lasso
        case newShape(Int)
        case move(Int, last: CGPoint)
        case resize(Int, Handle, start: CGPoint)
        case cropNew(start: CGPoint)
        case cropResize(Handle, original: CGRect, start: CGPoint)
    }

    weak var delegate: EditorViewDelegate?
    let renderer: Renderer
    private(set) var doc: EditorDocument
    private(set) var phase: Phase
    private(set) var lasso: [CGPoint]?
    let showMagnifier: Bool
    /// Pickable rects (windows, or the whole screen) in view coordinates, front to back.
    private let pickRects: [CGRect]
    /// Monitor picker with "open editor" off: the pick is delivered without an editing step.
    private let finishOnPick: Bool
    /// How the area was chosen; nil when the capture arrived with its area already fixed.
    private let selectionMode: SelectionMode?
    private var hover: CGRect?
    private var mouse: CGPoint?
    private var drag: Drag = .none
    private var dragMoved = false
    private var textField: NSTextField?
    private var editingTextID: Int?
    private lazy var toolbar = ToolbarView(editor: self)
    private let frameView: FrameView
    private var annotationsView: AnnotationsView?
    private var liveView: LiveMarkView?
    /// The mark being drawn, moved or resized, shown by liveView until mouse-up.
    private var liveID: Int?
    private let chrome: ChromeView

    init(frame: CGRect, renderer: Renderer, mode: SelectionMode, initialCrop: CGRect?, styles: [ShapeKind: ShapeStyle],
         showMagnifier: Bool, pickRects: [CGRect], finishOnPick: Bool) {
        self.finishOnPick = finishOnPick
        self.renderer = renderer
        self.doc = EditorDocument(crop: initialCrop, styles: styles)
        self.phase = initialCrop == nil ? .selecting(mode) : .editing
        self.showMagnifier = showMagnifier
        self.pickRects = pickRects
        self.selectionMode = initialCrop == nil ? mode : nil
        let local = CGRect(origin: .zero, size: frame.size)
        self.frameView = FrameView(frame: local, image: renderer.frame, smooth: renderer.smoothFrame)
        self.chrome = ChromeView(frame: local)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(frameView)
        addSubview(chrome)
        if phase == .editing { showToolbar() }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self))
    }

    var styles: [ShapeKind: ShapeStyle] { doc.styles }
    var tool: Tool { doc.tool }
    var bounds0: CGRect { CGRect(origin: .zero, size: bounds.size) }

    /// Another screen became active: drop back to an untouched selection state.
    func deactivate() {
        guard case .selecting = phase else { return }
        drag = .none; lasso = nil; hover = nil; refresh()
    }

    // MARK: Commands (toolbar + keys)

    func setTool(_ t: Tool) {
        commitText()
        doc.tool = t
        if case .shape = t { doc.selectedID = nil }
        refocus()
    }

    /// Toolbar clicks can steal first responder; keys must keep reaching the editor.
    private func refocus() {
        if textField == nil { window?.makeFirstResponder(self) }
        toolbar.sync()
        refresh()
    }
    func undo() { commitText(); doc.undo(); refocus() }
    func redo() { commitText(); doc.redo(); refocus() }

    // Edit-menu actions (⌘Z, ⇧⌘Z, ⌘C arrive here through the main menu while the view is first responder).
    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }
    @objc func copy(_ sender: Any?) { if phase == .editing { finish() } }
    func deleteSelection() { doc.deleteSelected(); refocus() }
    func cancel() { delegate?.editorDidCancel(self) }

    /// The kind whose style the toolbar edits: the selection's, else the active tool's.
    var styleTarget: ShapeKind? {
        if let s = doc.selected { return s.kind }
        if case .shape(let k) = doc.tool { return k }
        return nil
    }

    func changeStyle(_ change: (inout ShapeStyle) -> Void) {
        guard let k = styleTarget else { return }
        doc.applyStyle(change, to: k)
        delegate?.editorDidChangeStyle(self, kind: k)
        refocus()
    }

    /// Keep tool defaults in sync across display overlays without changing existing annotations.
    func rememberStyle(_ style: ShapeStyle, for kind: ShapeKind) {
        doc.styles[kind] = style
        toolbar.sync()
    }

    func finish() {
        commitText()
        guard let crop = doc.state.crop else { return }
        delegate?.editorDidFinish(self, crop: crop, lasso: lasso)
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p
        if case .selecting = phase { hover = pickTarget(at: p) }
        refresh()
    }

    override func mouseExited(with event: NSEvent) { mouse = nil; hover = nil; refresh() }

    private func pickTarget(at p: CGPoint) -> CGRect? { pickIndex(at: p).map { pickRects[$0] } }

    private func pickIndex(at p: CGPoint) -> Int? {
        guard case .selecting(let m) = phase, m != .lasso else { return nil }
        return pickRects.firstIndex { $0.contains(p) }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        delegate?.editorDidActivate(self)
        dragMoved = false
        // ShareX: double-click empty space finalizes.
        if e.clickCount == 2, phase == .editing, doc.tool != .shape(.text), doc.tool != .crop, doc.hitTest(p) == nil {
            finish(); return
        }
        switch phase {
        case .selecting(.rectangle): drag = .region(start: p)
        case .selecting(.lasso): lasso = [p]; drag = .lasso
        case .selecting: drag = .none
        case .editing: editingMouseDown(p)
        }
        refresh()
    }

    private func editingMouseDown(_ p: CGPoint) {
        commitText()
        if let s = doc.selected, let h = Handle.hit(p, on: s.bounds, tolerance: 6) {
            doc.beginDrag(); drag = .resize(s.id, h, start: p)
            if s.kind.isEffect { renderer.liveEffectID = s.id }
            if LiveMarkView.supports(s.kind) { liveID = s.id }
            return
        }
        switch doc.tool {
        case .select:
            if let a = doc.hitTest(p) {
                doc.selectedID = a.id; doc.beginDrag(); drag = .move(a.id, last: p)
                if a.kind.isEffect { renderer.liveEffectID = a.id }
                if LiveMarkView.supports(a.kind) { liveID = a.id }
            }
            else { doc.selectedID = nil; drag = .none }
        case .crop:
            doc.beginDrag()
            if let c = doc.state.crop, let h = Handle.hit(p, on: c, tolerance: 8) { drag = .cropResize(h, original: c, start: p) }
            else { drag = .cropNew(start: p) }
        case .shape(.text):
            if let a = doc.hitTest(p), a.kind == .text { beginTextEditing(a.id); return }
            // Not undoable until text is typed: the first setText records add + text as one step.
            beginTextEditing(doc.addText(at: p))
        case .shape(let k):
            doc.beginDrag()
            let id = doc.addShape(k, at: p)
            drag = .newShape(id)
            if k.isEffect { renderer.liveEffectID = id }
            if LiveMarkView.supports(k) { liveID = id }
        }
        toolbar.sync()
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p; dragMoved = true
        updateDrag(to: p, constrain: e.modifierFlags.contains(.shift))
        refresh()
    }

    /// The release event can be newer than the last coalesced drag event. Apply both through the
    /// same path so the exported mark/crop ends exactly where the pointer was released.
    private func updateDrag(to p: CGPoint, constrain shift: Bool) {
        switch drag {
        case .region: break
        case .lasso: if lasso?.last != p { lasso?.append(p) }
        case .newShape(let id): doc.extendShape(id, to: p, constrain: shift)
        case .move(let id, let last): doc.move(id, by: Offset(from: last, to: p)); drag = .move(id, last: p)
        case .resize(let id, let h, let start): doc.resizeFromDragStart(id, handle: h, by: Offset(from: start, to: p))
        // A drag under 1 pt keeps the previous crop rather than clearing it (Enter would then do nothing).
        case .cropNew(let s): if let r = Geometry.cropDrag(from: s, to: p, in: bounds0) { doc.setCropLive(r) }
        case .cropResize(let h, let original, let start):
            // Always resize the drag's original crop. Normalizing a crossed edge or clamping at the
            // display boundary must not change which edge the pointer controls on the next event.
            if let r = Geometry.clamp(h.resize(original, by: Offset(from: start, to: p)), to: bounds0) { doc.setCropLive(r) }
        case .none: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // A click must keep its existing snap/step semantics and must not create a pen stroke.
        if dragMoved { updateDrag(to: p, constrain: e.modifierFlags.contains(.shift)) }
        mouse = p
        switch (phase, drag) {
        case (.selecting, .region(let s)):
            // A click without a drag snaps to the window under the cursor, like ShareX.
            let r = dragMoved ? Geometry.rect(from: s, to: p) : pickTarget(at: p)
            if let r, let c = Geometry.clamp(r, to: bounds0) { enterEditing(crop: c) }
        case (.selecting, .lasso):
            if let pts = lasso, pts.count >= 3, let c = Geometry.clamp(Geometry.bounds(of: pts), to: bounds0) { enterEditing(crop: c) }
            else { lasso = nil }
        case (.selecting(.pickWindow), _):
            if let i = pickIndex(at: p) { delegate?.editorDidPickWindow(self, index: i); return }
        case (.selecting(.pickMonitor), _):
            if let r = pickTarget(at: p) {
                enterEditing(crop: r)
                if finishOnPick { finish(); return }
            }
        case (.editing, .none): break
        case (.editing, _):
            doc.endDrag()
            renderer.liveEffectID = nil
        default: break
        }
        drag = .none; liveID = nil
        if phase == .editing { toolbar.sync(); layoutToolbar() }
        refresh()
    }

    override func rightMouseDown(with e: NSEvent) {
        commitText()
        guard phase == .editing else { cancel(); return }
        // With marks on the image a right-click never throws work away: it deletes the mark under the cursor.
        if !doc.annotations.isEmpty {
            if let a = doc.hitTest(convert(e.locationInWindow, from: nil)) { doc.selectedID = a.id; deleteSelection() }
            return
        }
        // ShareX: right click clears the selection, or cancels when the area was fixed up front.
        guard let mode = selectionMode else { cancel(); return }
        phase = .selecting(mode); lasso = nil
        doc = EditorDocument(styles: doc.styles)
        toolbar.removeFromSuperview()
        window?.invalidateCursorRects(for: self)
        delegate?.editorDidReturnToSelection(self)
        refresh()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if toolbar.superview != nil { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    private func enterEditing(crop: CGRect) {
        doc.setCropLive(crop)
        phase = .editing
        showToolbar()
        delegate?.editorDidEnterEditing(self)
    }

    private func showToolbar() {
        if toolbar.superview == nil { addSubview(toolbar) }
        toolbar.sync()
        layoutToolbar()
    }

    private func layoutToolbar() {
        toolbar.fit(maxWidth: bounds.width - 8)
        let size = toolbar.fittingSize
        let crop = doc.state.crop ?? bounds0
        // Above the crop when there is room, otherwise just inside the top of the screen.
        var y = crop.minY - size.height - 8
        if y < 4 { y = min(crop.maxY + 8, bounds.height - size.height - 4) }
        let x = min(max(4, crop.midX - size.width / 2), bounds.width - size.width - 4)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 53: cancel(); return                                   // Esc
        case 36, 76: if phase == .editing { finish() }; return       // Return, keypad Enter
        case 51, 117: if phase == .editing { deleteSelection() }; return
        case 123...126: nudge(e.keyCode, by: shift ? 10 : 1); return
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

    private func nudge(_ key: UInt16, by n: CGFloat) {
        guard phase == .editing, let id = doc.selectedID else { return }
        let d: Offset = switch key {
        case 123: Offset(dx: -n, dy: 0)
        case 124: Offset(dx: n, dy: 0)
        case 125: Offset(dx: 0, dy: n)
        default: Offset(dx: 0, dy: -n)
        }
        doc.beginDrag(); doc.move(id, by: d); doc.endDrag()
        refresh()
    }

    // MARK: Text

    private func beginTextEditing(_ id: Int) {
        guard let a = doc.annotations.first(where: { $0.id == id }) else { return }
        doc.selectedID = id
        editingTextID = id
        let f = NSTextField(string: a.text)
        f.font = .systemFont(ofSize: CGFloat(a.style.fontSize), weight: .semibold)
        f.textColor = NSColor(cgColor: Imaging.cgColor(a.style.color)) ?? .red
        f.isBordered = true; f.drawsBackground = true
        f.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        f.focusRingType = .none
        f.delegate = self
        f.frame = CGRect(origin: a.start, size: CGSize(width: max(200, a.textSize.width + 40), height: a.textSize.height + 4))
        addSubview(f)
        window?.makeFirstResponder(f)
        textField = f
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    /// Esc and Return go to the field editor, not to keyDown; both commit the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertNewline(_:)): commitText(); return true
        default: return false
        }
    }

    private func commitText() {
        guard let f = textField, let id = editingTextID else { return }
        textField = nil; editingTextID = nil
        doc.setText(id, f.stringValue)
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        refresh()
    }

    // MARK: Drawing

    /// Pushes the current state into the layer views. Replaces a full-screen draw(_:) on every mouse event.
    func refresh() {
        var c = ChromeView.State()
        switch phase {
        case .selecting(let mode):
            annotationsView?.isHidden = true; liveView?.isHidden = true
            var hole: CGRect? = hover
            if case .region(let s) = drag, dragMoved, let m = mouse { hole = Geometry.rect(from: s, to: m) }
            c.dimEverything = true
            c.dimHole = hole.map { CGPath(rect: $0, transform: nil) }
            if let h = hole { c.outline = h; c.sizeLabel = (h, sizeText(h)) }
            if mode == .lasso { c.lasso = lasso }
            if showMagnifier, mode == .rectangle || mode == .lasso, let m = mouse {
                c.crosshair = m
                c.magnifier = (m, renderer.frame.cropping(to: ChromeView.source(m, scale: renderer.scale)), renderer.scale)
            }
        case .editing:
            if annotationsView == nil {
                let v = AnnotationsView(frame: CGRect(origin: .zero, size: bounds.size), renderer: renderer)
                addSubview(v, positioned: .above, relativeTo: frameView)
                annotationsView = v
                let l = LiveMarkView(frame: CGRect(origin: .zero, size: bounds.size))
                addSubview(l, positioned: .above, relativeTo: v)
                liveView = l
            }
            annotationsView?.isHidden = false; liveView?.isHidden = false
            let live = liveID.flatMap { id in doc.annotations.first { $0.id == id } }
            annotationsView?.sync(doc, hide: editingTextID, live: live?.id)
            liveView?.show(live, renderer: renderer)
            let crop = doc.state.crop ?? bounds0
            let hole = CGMutablePath()
            if let pts = lasso { hole.addLines(between: pts); hole.closeSubpath() } else { hole.addRect(crop) }
            c.dimEverything = true; c.dimHole = hole
            c.outline = crop
            if doc.tool == .crop { c.cropHandles = crop }
            if let s = doc.selected { c.selection = s.bounds }
            c.sizeLabel = (crop, sizeText(crop))
        }
        chrome.apply(c)
    }

    private func sizeText(_ r: CGRect) -> String {
        let s = renderer.scale
        return "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))"
    }
}
