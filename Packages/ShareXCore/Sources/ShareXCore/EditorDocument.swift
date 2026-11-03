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
    public var selectedID: Int?
    public var tool: Tool = .shape(.rectangle)
    public var styles: [ShapeKind: ShapeStyle]
    private var nextID = 1
    /// State at the start of the current drag, committed to history on `endDrag`.
    private var dragOrigin: EditorState?
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
        let a = Annotation(id: nextID, kind: kind, style: style(for: kind), start: p, end: p)
        nextID += 1
        state.annotations.append(a)
        selectedID = a.id
        return a.id
    }

    /// Extends the mark being drawn.
    public mutating func extendShape(_ id: Int, to p: CGPoint, constrain: Bool = false) {
        update(id) { a in
            if a.kind == .pen { a.points.append(p); a.end = p; return }
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
        var before = state
        if pendingTextID == id { before.annotations.removeAll { $0.id == id }; pendingTextID = nil }
        update(id) { $0.text = text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.annotations.removeAll { $0.id == id } }
        history.record(before: before, after: state)
        dropStaleSelection()
    }

    /// Changes the style of the selected mark (one undo step) and remembers it for that tool.
    public mutating func applyStyle(_ change: (inout ShapeStyle) -> Void, to kind: ShapeKind) {
        var s = style(for: kind); change(&s); styles[kind] = s
        guard let id = selectedID, selected?.kind == kind else { return }
        // The text mark being typed is not in history yet; its style rides along with its first setText.
        if id == pendingTextID { update(id) { change(&$0.style) }; return }
        commitPendingText()
        let before = state
        update(id) { change(&$0.style) }
        history.record(before: before, after: state)
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
    public mutating func setCropLive(_ r: CGRect?) { state.crop = r }

    public mutating func undo() { commitPendingText(); if let s = history.undo(state) { state = s; dropStaleSelection() } }
    public mutating func redo() { commitPendingText(); if let s = history.redo(state) { state = s; dropStaleSelection() } }

    /// A pending text mark that never got text is dropped (it was never visible).
    private mutating func commitPendingText() {
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
