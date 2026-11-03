import XCTest
@testable import ShareXCore

final class EditorTests: XCTestCase {
    private func draw(_ doc: inout EditorDocument, _ k: ShapeKind, _ a: CGPoint, _ b: CGPoint, shift: Bool = false) -> Int {
        doc.beginDrag()
        let id = doc.addShape(k, at: a)
        doc.extendShape(id, to: b, constrain: shift)
        doc.endDrag()
        return id
    }

    func testDrawUndoRedo() {
        var d = EditorDocument()
        _ = draw(&d, .rectangle, CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 40))
        _ = draw(&d, .arrow, CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 40))
        XCTAssertEqual(d.annotations.map(\.kind), [.rectangle, .arrow])
        d.undo(); XCTAssertEqual(d.annotations.map(\.kind), [.rectangle])
        d.undo(); XCTAssertTrue(d.annotations.isEmpty)
        d.undo(); XCTAssertTrue(d.annotations.isEmpty)
        d.redo(); d.redo(); XCTAssertEqual(d.annotations.map(\.kind), [.rectangle, .arrow])
    }

    func testNewEditClearsRedo() {
        var d = EditorDocument()
        _ = draw(&d, .rectangle, .zero, CGPoint(x: 10, y: 10))
        d.undo()
        _ = draw(&d, .ellipse, .zero, CGPoint(x: 10, y: 10))
        d.redo()
        XCTAssertEqual(d.annotations.map(\.kind), [.ellipse])
    }

    func testClickWithoutDragIsDiscardedAndNotUndoable() {
        var d = EditorDocument()
        _ = draw(&d, .rectangle, CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 6))
        XCTAssertTrue(d.annotations.isEmpty)
        XCTAssertFalse(d.history.canUndo)
        XCTAssertNil(d.selectedID)
    }

    func testStepMarkerSurvivesClickAndRenumbersOnDelete() {
        var d = EditorDocument()
        let s1 = draw(&d, .step, CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10))
        let s2 = draw(&d, .step, CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 10))
        let s3 = draw(&d, .step, CGPoint(x: 90, y: 10), CGPoint(x: 90, y: 10))
        XCTAssertEqual(d.annotations.map { d.stepNumber(of: $0) }, [1, 2, 3])
        d.selectedID = s1; d.deleteSelected()
        XCTAssertEqual(d.stepNumber(of: d.annotations.first { $0.id == s2 }!), 1)
        XCTAssertEqual(d.stepNumber(of: d.annotations.first { $0.id == s3 }!), 2)
        d.undo()
        XCTAssertEqual(d.annotations.count, 3)
    }

    func testMoveIsOneUndoStep() {
        var d = EditorDocument()
        let id = draw(&d, .rectangle, .zero, CGPoint(x: 10, y: 10))
        d.beginDrag()
        for _ in 0..<5 { d.move(id, by: Offset(dx: 2, dy: 1)) }
        d.endDrag()
        XCTAssertEqual(d.selected?.rect, CGRect(x: 10, y: 5, width: 10, height: 10))
        d.undo()
        XCTAssertEqual(d.selected?.rect, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testResizeRectViaHandle() {
        var d = EditorDocument()
        let id = draw(&d, .blur, .zero, CGPoint(x: 10, y: 10))
        d.beginDrag(); d.resize(id, handle: .bottomRight, by: Offset(dx: 10, dy: 5)); d.endDrag()
        XCTAssertEqual(d.selected?.rect, CGRect(x: 0, y: 0, width: 20, height: 15))
    }

    func testResizeArrowMovesNearerEndpoint() {
        var d = EditorDocument()
        let id = draw(&d, .arrow, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50))
        d.beginDrag(); d.resize(id, handle: .bottomRight, by: Offset(dx: 10, dy: 10)); d.endDrag()
        XCTAssertEqual(d.selected?.start, .zero)
        XCTAssertEqual(d.selected?.end, CGPoint(x: 110, y: 60))
    }

    func testShiftConstrains() {
        var d = EditorDocument()
        _ = draw(&d, .rectangle, .zero, CGPoint(x: 30, y: -10), shift: true)
        XCTAssertEqual(d.annotations[0].rect, CGRect(x: 0, y: -30, width: 30, height: 30))
        _ = draw(&d, .line, .zero, CGPoint(x: 100, y: 3), shift: true)
        XCTAssertEqual(d.annotations[1].end.y, 0, accuracy: 1e-9)
    }

    func testPenAndHitTesting() {
        var d = EditorDocument()
        d.beginDrag()
        let id = d.addShape(.pen, at: CGPoint(x: 0, y: 0))
        d.extendShape(id, to: CGPoint(x: 50, y: 0)); d.extendShape(id, to: CGPoint(x: 50, y: 50))
        d.endDrag()
        XCTAssertEqual(d.annotations[0].points.count, 3)
        XCTAssertEqual(d.hitTest(CGPoint(x: 25, y: 2))?.id, id)
        XCTAssertNil(d.hitTest(CGPoint(x: 10, y: 40)))
    }

    func testOutlineInteriorIsClickThroughButFilledIsNot() {
        var d = EditorDocument()
        let back = draw(&d, .highlighter, .zero, CGPoint(x: 100, y: 100))
        let outline = draw(&d, .rectangle, CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90))
        XCTAssertEqual(d.hitTest(CGPoint(x: 50, y: 50))?.id, back)
        XCTAssertEqual(d.hitTest(CGPoint(x: 10, y: 50))?.id, outline)
    }

    func testTextEditingAndEmptyTextRemoves() {
        var d = EditorDocument()
        let id = d.addText(at: CGPoint(x: 5, y: 5))
        d.setText(id, "Hello")
        XCTAssertEqual(d.selected?.text, "Hello")
        XCTAssertTrue(d.selected!.hit(CGPoint(x: 10, y: 10)))
        d.setText(id, "  ")
        XCTAssertTrue(d.annotations.isEmpty)
        d.undo(); XCTAssertEqual(d.annotations.first?.text, "Hello")
    }

    func testStyleChangeAppliesToSelectionAndBecomesToolDefault() {
        var d = EditorDocument()
        let id = draw(&d, .rectangle, .zero, CGPoint(x: 10, y: 10))
        d.selectedID = id
        d.applyStyle({ $0.color = .blue; $0.width = 9 }, to: .rectangle)
        XCTAssertEqual(d.selected?.style.color, .blue)
        XCTAssertEqual(d.style(for: .rectangle).width, 9)
        d.undo()
        XCTAssertEqual(d.selected?.style.color, .red)
        XCTAssertEqual(d.style(for: .rectangle).width, 9, "tool default is a preference, not an edit")
    }

    func testCropIsUndoable() {
        var d = EditorDocument(crop: CGRect(x: 0, y: 0, width: 100, height: 100))
        d.setCrop(CGRect(x: 10, y: 10, width: 50, height: 50))
        d.undo()
        XCTAssertEqual(d.state.crop, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testUndoLimit() {
        var u = UndoStack<Int>(limit: 3)
        for i in 0..<10 { u.record(before: i, after: i + 1) }
        XCTAssertEqual(u.undoStates, [7, 8, 9])
        u.record(before: 5, after: 5)
        XCTAssertEqual(u.undoStates.count, 3)
    }

    func testToolKeys() {
        XCTAssertEqual(Tool.forKey("r"), .shape(.rectangle))
        XCTAssertEqual(Tool.forKey("v"), .select)
        XCTAssertEqual(Tool.forKey("c"), .crop)
        XCTAssertNil(Tool.forKey("z"))
        XCTAssertEqual(Set(ShapeKind.allCases.map(\.key)).count, ShapeKind.allCases.count, "keys must be unique")
        XCTAssertFalse(ShapeKind.allCases.contains { $0.key == "v" || $0.key == "c" })
    }
}
