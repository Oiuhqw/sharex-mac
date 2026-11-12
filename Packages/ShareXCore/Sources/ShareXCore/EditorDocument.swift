import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The undoable part of the editor: marks plus the crop. Selection and the active tool are not undoable.
public struct EditorState: Codable, Equatable, Sendable {
    public var annotations: [Annotation] = []
    /// Final output area in frozen-frame points. nil until a selection exists.
    public var crop: CGRect?
    public init(annotations: [Annotation] = [], crop: CGRect? = nil) { (self.annotations, self.crop) = (annotations, crop) }
}

/// Snapshot undo/redo. States are small value arrays, so snapshots are cheap and can't drift.
public struct UndoStack<State: Equatable & Sendable>: Sendable {
    public private(set) var undoStates: [State] = []
    public private(set) var redoStates: [State] = []
    public let limit: Int
    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    /// Record `before` as the state prior to a change. No-op changes are not recorded.
    public mutating func record(before: State, after: State) {
        guard before != after else { return }
        undoStates.append(before)
        if undoStates.count > limit { undoStates.removeFirst(undoStates.count - limit) }
        redoStates.removeAll()
    }

    public mutating func undo(_ current: State) -> State? {
        guard let s = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return s
    }

    public mutating func redo(_ current: State) -> State? {
        guard let s = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return s
    }
}

/// Editor model driven by the overlay view. Pure: the view feeds it points in frozen-frame space.
public struct EditorDocument: Sendable {
    public private(set) var state: EditorState
    public private(set) var history = UndoStack<EditorState>()
    public var selectedID: Int? {
        willSet { if newValue != selectedID { endStyleGesture() } }
    }
    public var tool: Tool = .shape(.rectangle) {
        willSet { if newValue != tool { endStyleGesture() } }
    }
    public var styles: [ShapeKind: ShapeStyle]
    private var nextID = 1
    /// State at the start of the current drag, committed to history on `endDrag`.
    private var dragOrigin: EditorState?
    private enum StyleGesture: Sendable {
        case annotation(id: Int, kind: ShapeKind, before: EditorState)
        case pendingText(id: Int, kind: ShapeKind)
        case toolDefault(kind: ShapeKind)

        var kind: ShapeKind {
            switch self {
            case .annotation(_, let kind, _), .pendingText(_, let kind), .toolDefault(let kind): kind
            }
        }
        var id: Int? {
            switch self {
            case .annotation(let id, _, _), .pendingText(let id, _): id
            case .toolDefault: nil
            }
        }
    }
    private var styleGesture: StyleGesture?
    public var isStyleGestureActive: Bool { styleGesture != nil }
    /// A text mark added by `addText` that has no text yet. It is not in history: the first `setText`
    /// records the add and the text together, so one undo removes it.
    public private(set) var pendingTextID: Int?

    public init(crop: CGRect? = nil, styles: [ShapeKind: ShapeStyle] = [:]) {
        state = EditorState(crop: crop)
        self.styles = styles
    }

    public var annotations: [Annotation] { state.annotations }
    public var selected: Annotation? { selectedID.flatMap { id in state.annotations.first { $0.id == id } } }

    public func style(for k: ShapeKind) -> ShapeStyle { styles[k] ?? .defaults(for: k) }

    /// 1-based number shown on a step marker: its order among steps, so deleting one renumbers the rest.
    public func stepNumber(of a: Annotation) -> Int {
        (state.annotations.filter { $0.kind == .step }.firstIndex { $0.id == a.id } ?? 0) + 1
    }

    /// Topmost annotation under `p`.
    public func hitTest(_ p: CGPoint) -> Annotation? { state.annotations.last { $0.hit(p) } }

    // MARK: Drags. One drag = one undo step.

    public mutating func beginDrag() { commitPendingText(); dragOrigin = state }

    public mutating func endDrag() {
        if let i = state.annotations.firstIndex(where: { $0.id == selectedID }), state.annotations[i].isDegenerate,
           state.annotations[i].kind != .text {
            state.annotations.remove(at: i); selectedID = nil
        }
        if let o = dragOrigin { history.record(before: o, after: state) }
        dragOrigin = nil
    }

    /// Starts a new mark at `p` with the current style for `kind`. Returns its id.
    @discardableResult
    public mutating func addShape(_ kind: ShapeKind, at p: CGPoint) -> Int {
        endStyleGesture()
        let a = Annotation(id: nextID, kind: kind, style: style(for: kind), start: p, end: p)
        nextID += 1
        state.annotations.append(a)
        selectedID = a.id
        return a.id
    }

    /// Extends the mark being drawn.
    public mutating func extendShape(_ id: Int, to p: CGPoint, constrain: Bool = false) {
        update(id) { a in
            if a.kind == .pen {
                if a.points.last != p { a.points.append(p) }
                a.end = p
                return
            }
            if a.kind == .step || a.kind == .text { return }
            var q = p
            if constrain {
                // Shift: squares/circles for rect kinds, 45° steps for segments.
                let dx = p.x - a.start.x, dy = p.y - a.start.y
                if a.kind.isSegment {
                    let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(dx, dy)
                    q = CGPoint(x: a.start.x + len * cos(ang), y: a.start.y + len * sin(ang))
                } else {
                    let s = max(abs(dx), abs(dy))
                    q = CGPoint(x: a.start.x + (dx < 0 ? -s : s), y: a.start.y + (dy < 0 ? -s : s))
                }
            }
            a.end = q
        }
    }

    public mutating func move(_ id: Int, by d: Offset) { update(id) { $0 = $0.moved(by: d) } }
    public mutating func resize(_ id: Int, handle: Handle, by d: Offset) { update(id) { $0 = $0.resized(handle, by: d) } }

    /// Resizes from the immutable annotation captured by `beginDrag`, using the total pointer delta.
    /// Reusing the previous normalized bounds swaps edges after a crossing and collapses pen points
    /// irreversibly at zero width/height. Starting from the original keeps every event independent.
    public mutating func resizeFromDragStart(_ id: Int, handle: Handle, by d: Offset) {
        guard let original = dragOrigin?.annotations.first(where: { $0.id == id }) else { return }
        update(id) { $0 = original.resized(handle, by: d) }
    }

    /// Adds an empty text mark for typing into. Not undoable by itself; see `setText`.
    @discardableResult
    public mutating func addText(at p: CGPoint) -> Int {
        commitPendingText()
        let id = addShape(.text, at: p)
        pendingTextID = id
        return id
    }

    /// Replaces the text of a text mark as one undo step. Empty text deletes the mark.
    /// For a mark from `addText` the step covers the add too, and empty text leaves no history at all.
    public mutating func setText(_ id: Int, _ text: String) {
        endStyleGesture()
        var before = state
        if pendingTextID == id { before.annotations.removeAll { $0.id == id }; pendingTextID = nil }
        update(id) { $0.text = text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.annotations.removeAll { $0.id == id } }
        history.record(before: before, after: state)
        dropStaleSelection()
    }

    public mutating func beginStyleGesture(to kind: ShapeKind) {
        guard styleGesture == nil else { return }
        if let selected, selected.kind == kind {
            if selected.id == pendingTextID {
                styleGesture = .pendingText(id: selected.id, kind: kind)
            } else {
                commitPendingText()
                styleGesture = .annotation(id: selected.id, kind: kind, before: state)
            }
        } else {
            styleGesture = .toolDefault(kind: kind)
        }
    }

    public mutating func endStyleGesture() {
        let gesture = styleGesture
        styleGesture = nil
        if let gesture, case .annotation(_, _, let before) = gesture { history.record(before: before, after: state) }
    }

    /// Live slider changes share one history entry. Defaults remain outside document history.
    public mutating func applyStyle(_ change: (inout ShapeStyle) -> Void, to kind: ShapeKind) {
        if let gesture = styleGesture, gesture.kind != kind { endStyleGesture() }
        var s = style(for: kind); change(&s); styles[kind] = s
        let target = if let gesture = styleGesture { gesture.id } else { selected?.kind == kind ? selectedID : nil }
        guard let id = target else { return }
        let record = styleGesture == nil && id != pendingTextID
        if record { commitPendingText() }
        let before = state
        update(id) { change(&$0.style) }
        if record { history.record(before: before, after: state) }
    }

    public mutating func deleteSelected() {
        commitPendingText()
        guard let id = selectedID else { return }
        let before = state
        state.annotations.removeAll { $0.id == id }
        selectedID = nil
        history.record(before: before, after: state)
    }

    public mutating func setCrop(_ r: CGRect?) {
        commitPendingText()
        let before = state
        state.crop = r
        history.record(before: before, after: state)
    }

    /// Crop changes made during a drag (live), committed by `endDrag`.
    public mutating func setCropLive(_ r: CGRect?) { endStyleGesture(); state.crop = r }

    public mutating func undo() { commitPendingText(); if let s = history.undo(state) { state = s; dropStaleSelection() } }
    public mutating func redo() { commitPendingText(); if let s = history.redo(state) { state = s; dropStaleSelection() } }

    /// A pending text mark that never got text is dropped (it was never visible).
    private mutating func commitPendingText() {
        endStyleGesture()
        guard let id = pendingTextID else { return }
        pendingTextID = nil
        if let a = state.annotations.first(where: { $0.id == id }), a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.annotations.removeAll { $0.id == id }
            dropStaleSelection()
        }
    }

    private mutating func dropStaleSelection() { if selected == nil { selectedID = nil } }

    private mutating func update(_ id: Int, _ f: (inout Annotation) -> Void) {
        guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        f(&state.annotations[i])
    }
}
