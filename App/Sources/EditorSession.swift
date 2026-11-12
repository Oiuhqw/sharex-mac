import AppKit
import ShareXCore

struct EditorResult {
    let image: CGImage
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    let crop: CGRect
    let lastRegion: LastRegion?
}

@MainActor
final class EditorSession: NSObject, NSTextFieldDelegate {
    enum Phase: Equatable { case selecting(SelectionMode), annotating, editing, ended }
    private enum Drag {
        case none, region(start: CGPoint), lasso, newShape(Int), move(Int, last: CGPoint)
        case resize(Int, Handle, start: CGPoint), cropNew(start: CGPoint), cropResize(Handle, original: CGRect, start: CGPoint)
    }
    private struct View { weak var value: EditorView? }
    let renderer: Renderer
    private(set) var doc: EditorDocument
    private(set) var phase: Phase
    private(set) var lasso: [CGPoint]?
    private(set) var liveID: Int?
    private(set) var editingTextID: Int?
    private(set) var mouse: CGPoint?
    private(set) var hover: CGRect?
    private var drag: Drag = .none
    private var dragMoved = false
    private weak var gestureOwner: EditorView?
    private weak var activeView: EditorView?
    private var views: [View] = []
    private var textField: NSTextField?
    private var selectionMode: SelectionMode?
    private let finishOnPick: Bool
    private let pickRects: [CGRect]
    private let windows: [WindowInfo]
    private let outputScale: CGFloat?
    let saveFolder: String?
    var outputAction: String { saveFolder == nil ? "Copy" : "Copy and save" }
    var outputSummary: String {
        guard let saveFolder else { return "Clipboard only. PNG saving is off in Settings." }
        return "Clipboard + PNG to \(saveFolder.isEmpty ? "~/Pictures/ShareX" : saveFolder)"
    }
    var completion: ((EditorOutcome) -> Void)?
    private var failureMessage: String?
    var bounds0: CGRect { renderer.source.bounds }
    var canChooseSelection: Bool {
        switch phase { case .selecting, .annotating: return true; case .editing, .ended: return false }
    }
    var canPickWindow: Bool { canChooseSelection && doc.annotations.isEmpty && editingTextID == nil }
    var canAnnotate: Bool { phase != .ended }
    var canFinish: Bool {
        guard phase == .editing, let crop = doc.state.crop, let area = renderer.pixelArea(crop) else { return false }
        return Imaging.allocationBytes(width: area.w, height: area.h) != nil
    }
    var status: String? {
        if phase == .editing, !canFinish { return "Use Crop to reduce the captured area (64 megapixel limit)." }
        return failureMessage
    }

    init(renderer: Renderer, mode: SelectionMode, initialCrop: CGRect?, styles: [ShapeKind: ShapeStyle],
         pickRects: [CGRect], windows: [WindowInfo] = [], finishOnPick: Bool, outputScale: CGFloat? = nil,
         saveFolder: String? = "") {
        self.renderer = renderer; self.pickRects = pickRects; self.windows = windows
        self.finishOnPick = finishOnPick; self.outputScale = outputScale
        self.saveFolder = saveFolder
        doc = EditorDocument(crop: initialCrop, styles: styles)
        phase = initialCrop == nil ? .selecting(mode) : .editing
        selectionMode = initialCrop == nil ? mode : nil
        super.init()
        renderer.redactionFailuresChanged = { [weak self] rects in self?.eachView { $0.showFailures(rects) } }
        renderer.redactionFailuresNeedDisplay = { [weak self] rect in
            self?.eachView { $0.invalidateAnnotations(rect) }
            DispatchQueue.main.async { [weak self] in self?.eachView { $0.invalidateAnnotations(rect) } }
        }
        if let initialCrop { renderer.setScale(for: initialCrop) }
    }

    func attach(_ view: EditorView) { views.append(View(value: view)) }
    private func eachView(_ body: (EditorView) -> Void) { for v in views { if let v = v.value { body(v) } } }
    func activate(_ view: EditorView) {
        guard phase != .ended else { return }
        if activeView !== view { commitText(); activeView = view }
        view.window?.makeKey()
    }
    func restoreResponder() {
        if let f = textField { f.window?.makeFirstResponder(f) }
        else if let view = activeView { view.window?.makeFirstResponder(view) }
    }
    func refresh() {
        guard phase != .ended else { return }
        if let crop = doc.state.crop, renderer.setScale(for: crop) { eachView { $0.invalidateAll() } }
        if let dirty = renderer.synchronize(doc) { eachView { $0.invalidateAnnotations(dirty) } }
        eachView { $0.refresh() }
    }
    func setTool(_ tool: Tool) {
        guard canAnnotate, gestureOwner == nil, tool != .crop || phase == .editing else { return }
        commitText()
        if canChooseSelection { phase = .annotating; hover = nil; lasso = nil }
        doc.tool = tool
        if tool != .select { doc.selectedID = nil }
        restoreResponder(); refresh()
    }
    func chooseSelection(_ mode: SelectionMode) {
        guard canChooseSelection, gestureOwner == nil else { return }
        commitText()
        guard mode != .pickWindow || canPickWindow else { return }
        selectionMode = mode; phase = .selecting(mode); doc.selectedID = nil
        hover = nil; lasso = nil
        restoreResponder(); refresh()
    }
    func selectDesktop() {
        guard canChooseSelection, gestureOwner == nil else { return }
        commitText(); completeArea(bounds0)
    }
    func undo() {
        commitText(); doc.undo()
        if phase == .editing, doc.state.crop == nil {
            phase = .annotating; lasso = nil
            if doc.tool == .crop { doc.tool = .select }
        }
        restoreResponder(); refresh()
    }
    func redo() {
        commitText(); doc.redo()
        if phase == .annotating, doc.state.crop != nil { phase = .editing }
        restoreResponder(); refresh()
    }
    func deleteSelection() { commitText(); doc.deleteSelected(); restoreResponder(); refresh() }
    var styleTarget: ShapeKind? {
        if let selected = doc.selected { return selected.kind }
        if case .shape(let kind) = doc.tool { return kind }
        return nil
    }
    func changeStyle(_ change: (inout ShapeStyle) -> Void) {
        commitText()
        guard let kind = styleTarget else { return }
        doc.applyStyle(change, to: kind); restoreResponder(); refresh()
    }
    func rememberStyle(_ style: ShapeStyle, for kind: ShapeKind) { doc.styles[kind] = style; refresh() }
    func finish() {
        commitText()
        guard canFinish, let crop = doc.state.crop else { refresh(); return }
        guard let image = Export.flatten(renderer: renderer, doc: doc, crop: crop, lasso: lasso) else {
            failureMessage = "Screenshot could not be prepared. Use Crop to reduce the area or try Done again."
            refresh(); return
        }
        let layout = renderer.source.layout
        end(.finished(EditorResult(image: image, scale: outputScale ?? renderer.scale,
                                   displayID: layout?.participants(in: crop).first?.id ?? 0, crop: crop,
                                   lastRegion: layout.flatMap { LastRegion(crop: crop, layout: $0) })))
    }
    func cancel() { end(.cancelled) }
    private func end(_ outcome: EditorOutcome) {
        guard phase != .ended else { return }
        phase = .ended
        textField?.delegate = nil; textField?.removeFromSuperview(); textField = nil; editingTextID = nil
        gestureOwner = nil; drag = .none; liveID = nil; renderer.liveEffectID = nil
        let callback = completion; completion = nil
        renderer.releaseTransientResources()
        callback?(outcome)
        views.removeAll(); activeView = nil
    }
    func hover(at p: CGPoint?, from view: EditorView) {
        guard gestureOwner == nil else { return }
        mouse = p
        hover = p.flatMap { pickTarget(at: $0) }
        eachView { $0.refreshChrome() }
    }
    private func pickIndex(at p: CGPoint) -> Int? {
        guard case .selecting(let mode) = phase, mode != .lasso else { return nil }
        return pickRects.firstIndex { $0.contains(p) }
    }
    private func pickTarget(at p: CGPoint) -> CGRect? {
        if case .selecting(.pickMonitor) = phase { return renderer.source.tiles.first { $0.rect.contains(p) }?.rect }
        return pickIndex(at: p).map { pickRects[$0] }
    }
    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds0.minX), bounds0.maxX), y: min(max(p.y, bounds0.minY), bounds0.maxY))
    }
    func pointerDown(_ point: CGPoint, clicks: Int, from view: EditorView) {
        guard phase != .ended, gestureOwner == nil else { return }
        activate(view); commitText(); gestureOwner = view; dragMoved = false
        let p = clamped(point); mouse = p
        if clicks == 2, phase == .editing, doc.tool != .shape(.text), doc.tool != .crop, doc.hitTest(p) == nil {
            gestureOwner = nil; finish(); return
        }
        switch phase {
        case .selecting(.rectangle): drag = .region(start: p)
        case .selecting(.lasso): lasso = [p]; drag = .lasso
        case .selecting: drag = .none
        case .annotating, .editing: editingMouseDown(p)
        case .ended: return
        }
        refresh()
    }
    func pointerDragged(_ point: CGPoint, shift: Bool, from view: EditorView) {
        guard gestureOwner === view else { return }
        let p = clamped(point); mouse = p; dragMoved = true
        renderer.fastLivePreview = true
        updateDrag(to: p, constrain: shift); refresh()
    }
    func pointerUp(_ point: CGPoint, shift: Bool, from view: EditorView) {
        guard gestureOwner === view else { return }
        let p = clamped(point); renderer.fastLivePreview = false
        if case .region(let start) = drag, p != start { dragMoved = true }
        if case .lasso = drag, lasso?.last != p { dragMoved = true }
        if dragMoved { updateDrag(to: p, constrain: shift) }
        mouse = p
        let completedDrag = drag
        gestureOwner = nil; drag = .none; liveID = nil; renderer.liveEffectID = nil
        switch (phase, completedDrag) {
        case (.selecting, .region(let start)):
            if let r = dragMoved ? Geometry.rect(from: start, to: p) : pickTarget(at: p) { completeArea(r) }
        case (.selecting, .lasso):
            if let points = lasso, points.count >= 3,
               points.dropFirst(2).contains(where: {
                   (points[1].x - points[0].x) * ($0.y - points[0].y) != (points[1].y - points[0].y) * ($0.x - points[0].x)
               }) {
                completeArea(Geometry.bounds(of: points))
            }
            else { lasso = nil }
        case (.selecting(.pickWindow), _):
            guard canPickWindow else { phase = .annotating; hover = nil; refresh(); return }
            if let i = pickIndex(at: p), windows.indices.contains(i) { end(.pickedWindow(windows[i])); return }
        case (.selecting(.pickMonitor), _):
            if let r = pickTarget(at: p) { enterEditing(crop: r); if finishOnPick { finish() } }
        case (.annotating, .none), (.editing, .none): break
        case (.annotating, _), (.editing, _): doc.endDrag()
        default: break
        }
        refresh()
    }
    func secondary(_ p: CGPoint, from view: EditorView) {
        guard gestureOwner == nil, phase != .ended else { return }
        activate(view); commitText()
        guard phase == .editing || phase == .annotating else { cancel(); return }
        if !doc.annotations.isEmpty {
            if let a = doc.hitTest(p) { doc.selectedID = a.id; deleteSelection() }
            return
        }
        guard let mode = selectionMode else { cancel(); return }
        phase = .selecting(mode); lasso = nil; doc = EditorDocument(styles: doc.styles); refresh()
    }
    private func setCropLive(_ rect: CGRect) {
        guard let crop = renderer.source.selection(rect) else { return }
        if renderer.setScale(for: crop) { eachView { $0.invalidateAll() } }
        if let area = renderer.pixelArea(crop) { doc.setCropLive(area.points(scale: renderer.scale)) }
    }
    private func enterEditing(crop: CGRect) {
        guard let crop = renderer.source.selection(crop) else { return }
        setCropLive(crop); phase = .editing
    }
    private func completeArea(_ crop: CGRect) {
        enterEditing(crop: crop)
        if phase == .editing { finish() } else { refresh() }
    }
    var selectionHole: CGRect? {
        if case .region(let start) = drag, dragMoved, let mouse { return Geometry.rect(from: start, to: mouse) }
        return hover
    }
    private func beginTextEditing(_ id: Int) {
        guard let a = doc.annotations.first(where: { $0.id == id }), let view = activeView else { return }
        doc.selectedID = id; editingTextID = id
        let field = NSTextField(string: a.text)
        field.font = .systemFont(ofSize: CGFloat(a.style.fontSize), weight: .semibold)
        field.textColor = NSColor(cgColor: Imaging.cgColor(a.style.color)) ?? .red
        field.isBordered = true; field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85); field.focusRingType = .none
        field.delegate = self
        let local = view.local(a.start), width = min(max(200, a.textSize.width + 40), view.bounds.width - 8)
        field.frame = CGRect(x: min(max(4, local.x), view.bounds.width - width - 4),
                             y: min(max(view.toolbarBottom + 4, local.y), view.bounds.height - a.textSize.height - 8),
                             width: width, height: a.textSize.height + 4)
        view.addSubview(field); textField = field; view.window?.makeFirstResponder(field); refresh()
    }
    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        case #selector(NSResponder.insertNewline(_:)): commitText(); return true
        case #selector(NSResponder.insertTab(_:)):
            if canChooseSelection { chooseSelection(.rectangle); return true }
            return false
        default: return false
        }
    }
    func commitText() {
        guard let field = textField, let id = editingTextID else { return }
        textField = nil; editingTextID = nil; field.delegate = nil
        doc.setText(id, field.stringValue); field.removeFromSuperview(); restoreResponder(); refresh()
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
        refresh()
    }

    private func updateDrag(to p: CGPoint, constrain shift: Bool) {
        switch drag {
        case .region: break
        case .lasso: if lasso?.last != p { lasso?.append(p) }
        case .newShape(let id): doc.extendShape(id, to: p, constrain: shift)
        case .move(let id, let last): doc.move(id, by: Offset(from: last, to: p)); drag = .move(id, last: p)
        case .resize(let id, let h, let start): doc.resizeFromDragStart(id, handle: h, by: Offset(from: start, to: p))
        case .cropNew(let s): if let r = Geometry.cropDrag(from: s, to: p, in: bounds0, scale: renderer.scale) {
            setCropLive(r)
        }
        case .cropResize(let h, let original, let start):
            // Always resize the drag's original crop. Normalizing a crossed edge or clamping at the
            // display boundary must not change which edge the pointer controls on the next event.
            let resized = h.resize(original, by: Offset(from: start, to: p))
            if let r = Geometry.cropDrag(from: resized.origin, to: CGPoint(x: resized.maxX, y: resized.maxY),
                                         in: bounds0, scale: renderer.scale) {
                setCropLive(r)
            }
        case .none: break
        }
    }

    func nudge(_ key: UInt16, by n: Int, resizing: Bool) {
        guard phase == .editing || phase == .annotating else { return }
        commitText()
        let dx = key == 123 ? -n : key == 124 ? n : 0
        let dy = key == 126 ? -n : key == 125 ? n : 0
        if doc.tool == .crop, let crop = doc.state.crop, let area = renderer.pixelArea(crop) {
            let adjusted = area.adjusted(dx: dx, dy: dy, resizing: resizing, width: renderer.pixelWidth, height: renderer.pixelHeight)
            if let crop = renderer.source.selection(adjusted.points(scale: renderer.scale)) { doc.setCrop(crop) }
        } else if let id = doc.selectedID {
            doc.beginDrag(); doc.move(id, by: Offset(dx: CGFloat(dx), dy: CGFloat(dy))); doc.endDrag()
        }
        refresh()
    }

}
