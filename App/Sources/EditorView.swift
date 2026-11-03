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
        case resize(Int, Handle, last: CGPoint)
        case cropNew(start: CGPoint)
        case cropResize(Handle, last: CGPoint)
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

    init(frame: CGRect, renderer: Renderer, mode: SelectionMode, initialCrop: CGRect?, styles: [ShapeKind: ShapeStyle],
         showMagnifier: Bool, pickRects: [CGRect], finishOnPick: Bool) {
        self.finishOnPick = finishOnPick
        self.renderer = renderer
        self.doc = EditorDocument(crop: initialCrop, styles: styles)
        self.phase = initialCrop == nil ? .selecting(mode) : .editing
        self.showMagnifier = showMagnifier
        self.pickRects = pickRects
        self.selectionMode = initialCrop == nil ? mode : nil
        super.init(frame: frame)
        if phase == .editing { showToolbar() }
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
        drag = .none; lasso = nil; hover = nil; needsDisplay = true
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
        needsDisplay = true
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
        refocus()
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { mouse = nil; hover = nil; needsDisplay = true }

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
        needsDisplay = true
    }

    private func editingMouseDown(_ p: CGPoint) {
        commitText()
        if let s = doc.selected, let h = Handle.hit(p, on: s.bounds, tolerance: 6) {
            doc.beginDrag(); drag = .resize(s.id, h, last: p)
            if s.kind.isEffect { renderer.liveEffectID = s.id }
            return
        }
        switch doc.tool {
        case .select:
            if let a = doc.hitTest(p) {
                doc.selectedID = a.id; doc.beginDrag(); drag = .move(a.id, last: p)
                if a.kind.isEffect { renderer.liveEffectID = a.id }
            }
            else { doc.selectedID = nil; drag = .none }
        case .crop:
            doc.beginDrag()
            if let c = doc.state.crop, let h = Handle.hit(p, on: c, tolerance: 8) { drag = .cropResize(h, last: p) }
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
        }
        toolbar.sync()
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p; dragMoved = true
        let shift = e.modifierFlags.contains(.shift)
        switch drag {
        case .region: break
        case .lasso: lasso?.append(p)
        case .newShape(let id): doc.extendShape(id, to: p, constrain: shift)
        case .move(let id, let last): doc.move(id, by: Offset(from: last, to: p)); drag = .move(id, last: p)
        case .resize(let id, let h, let last): doc.resize(id, handle: h, by: Offset(from: last, to: p)); drag = .resize(id, h, last: p)
        // A drag under 1 pt keeps the previous crop rather than clearing it (Enter would then do nothing).
        case .cropNew(let s): if let r = Geometry.cropDrag(from: s, to: p, in: bounds0) { doc.setCropLive(r) }
        case .cropResize(let h, let last):
            if let c = doc.state.crop, let r = Geometry.clamp(h.resize(c, by: Offset(from: last, to: p)), to: bounds0) { doc.setCropLive(r) }
            drag = .cropResize(h, last: p)
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
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
        drag = .none
        if phase == .editing { toolbar.sync(); layoutToolbar() }
        needsDisplay = true
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
        needsDisplay = true
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
        needsDisplay = true
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
        needsDisplay = true
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
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        renderer.drawFrame(ctx)
        let dim = CGColor(gray: 0, alpha: 0.35)
        switch phase {
        case .selecting(let mode):
            var hole: CGRect? = hover
            if case .region(let s) = drag, dragMoved, let m = mouse { hole = Geometry.rect(from: s, to: m) }
            dimOutside(hole, ctx: ctx, color: dim)
            if let h = hole { outline(h, ctx: ctx); sizeLabel(for: h) }
            if mode == .lasso, let pts = lasso, pts.count > 1 {
                ctx.setStrokeColor(.white); ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [5, 3])
                ctx.beginPath(); ctx.addLines(between: pts); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
            }
            if showMagnifier, mode == .rectangle || mode == .lasso, let m = mouse { drawCrosshair(m, ctx: ctx); drawMagnifier(m, ctx: ctx) }
        case .editing:
            renderer.draw(doc, in: ctx, hide: editingTextID)
            let crop = doc.state.crop ?? bounds0
            ctx.saveGState()
            ctx.beginPath(); ctx.addRect(bounds0)
            if let pts = lasso { ctx.addLines(between: pts); ctx.closePath() } else { ctx.addRect(crop) }
            ctx.setFillColor(dim); ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
            outline(crop, ctx: ctx)
            if doc.tool == .crop { handles(crop, ctx: ctx) }
            if let s = doc.selected { selection(s.bounds, ctx: ctx) }
            sizeLabel(for: crop)
        }
    }

    private func dimOutside(_ r: CGRect?, ctx: CGContext, color: CGColor) {
        ctx.saveGState()
        ctx.beginPath(); ctx.addRect(bounds0); if let r { ctx.addRect(r) }
        ctx.setFillColor(color); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private func outline(_ r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1); ctx.setStrokeColor(.white); ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineDash(phase: 0, lengths: [4, 4]); ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()
    }

    private func handles(_ r: CGRect, ctx: CGContext) {
        for h in Handle.allCases {
            let c = h.point(on: r)
            let box = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.setFillColor(.white); ctx.fill(box)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(1); ctx.stroke(box)
        }
    }

    private func selection(_ r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 1)); ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.stroke(r.insetBy(dx: -3, dy: -3))
        ctx.restoreGState()
        handles(r, ctx: ctx)
    }

    private func sizeLabel(for r: CGRect) {
        let s = renderer.scale
        let text = "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)]
        let y = r.maxY + 4 < bounds.height - 16 ? r.maxY + 4 : r.minY + 4
        NSAttributedString(string: " \(text) ", attributes: attrs).draw(at: CGPoint(x: r.minX, y: y))
    }

    private func drawCrosshair(_ p: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: p.y), CGPoint(x: bounds.width, y: p.y),
                                         CGPoint(x: p.x, y: 0), CGPoint(x: p.x, y: bounds.height)])
        ctx.restoreGState()
    }

    /// 15×15 source pixels at 8x, nearest neighbour, with the pixel position underneath.
    private func drawMagnifier(_ p: CGPoint, ctx: CGContext) {
        let n: CGFloat = 15, zoom: CGFloat = 8, side = n * zoom
        let s = renderer.scale
        let src = CGRect(x: (p.x * s).rounded(.down) - (n - 1) / 2, y: (p.y * s).rounded(.down) - (n - 1) / 2, width: n, height: n)
        guard let crop = renderer.frame.cropping(to: src) else { return }
        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + side > bounds.width { origin.x = p.x - 20 - side }
        if origin.y + side + 18 > bounds.height { origin.y = p.y - 20 - side - 18 }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))
        ctx.saveGState()
        ctx.interpolationQuality = .none
        // cropping(to:) clips at image edges; place what we got where it belongs.
        let got = CGRect(x: box.minX + (max(src.minX, 0) - src.minX) * zoom, y: box.minY + (max(src.minY, 0) - src.minY) * zoom,
                         width: CGFloat(crop.width) * zoom, height: CGFloat(crop.height) * zoom)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(box)
        Imaging.drawUpright(crop, in: got, ctx: ctx)
        let mid = CGRect(x: box.minX + (n - 1) / 2 * zoom, y: box.minY + (n - 1) / 2 * zoom, width: zoom, height: zoom)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)); ctx.setLineWidth(1); ctx.stroke(mid)
        ctx.setStrokeColor(.white); ctx.setLineWidth(2); ctx.stroke(box)
        ctx.restoreGState()
        let label = " X: \(Int(p.x * s))  Y: \(Int(p.y * s)) "
        NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                       .foregroundColor: NSColor.white,
                                                       .backgroundColor: NSColor.black.withAlphaComponent(0.7)])
            .draw(at: CGPoint(x: box.minX, y: box.maxY + 2))
    }
}
