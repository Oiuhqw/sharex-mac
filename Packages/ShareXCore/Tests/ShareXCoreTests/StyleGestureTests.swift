import XCTest
@testable import ShareXCore

final class StyleGestureTests: XCTestCase {
    private func rectangle(_ doc: inout EditorDocument) -> Int {
        doc.beginDrag()
        let id = doc.addShape(.rectangle, at: .zero)
        doc.extendShape(id, to: CGPoint(x: 80, y: 60)); doc.endDrag()
        return id
    }

    func testContinuousChangesAreVisibleAndUndoAsOneEdit() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        let before = doc.state, count = doc.history.undoStates.count
        doc.beginStyleGesture(to: .rectangle)
        for opacity in [0.9, 0.6, 0.3] {
            doc.applyStyle({ $0.opacity = opacity }, to: .rectangle)
            XCTAssertEqual(doc.selected?.style.opacity, opacity)
            XCTAssertEqual(doc.history.undoStates.count, count)
        }
        doc.endStyleGesture()
        let after = doc.state
        XCTAssertEqual(doc.history.undoStates.count, count + 1)
        doc.undo(); XCTAssertEqual(doc.state, before)
        doc.redo(); XCTAssertEqual(doc.state, after)
        XCTAssertEqual(doc.style(for: .rectangle).opacity, 0.3)
    }

    func testNoOpGestureKeepsRedo() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        doc.applyStyle({ $0.width = 20 }, to: .rectangle); doc.undo()
        let history = doc.history.undoStates
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 18 }, to: .rectangle)
        doc.applyStyle({ $0.width = 4 }, to: .rectangle)
        doc.endStyleGesture()
        XCTAssertEqual(doc.history.undoStates, history)
        XCTAssertTrue(doc.history.canRedo)
        doc.redo(); XCTAssertEqual(doc.selected?.style.width, 20)
    }

    func testDefaultsHaveNoDocumentHistory() {
        var doc = EditorDocument()
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.color = .blue; $0.width = 16 }, to: .rectangle)
        doc.endStyleGesture()
        XCTAssertFalse(doc.history.canUndo)
        _ = rectangle(&doc)
        XCTAssertEqual(doc.selected?.style.color, .blue)
        XCTAssertEqual(doc.selected?.style.width, 16)
        doc.undo(); XCTAssertTrue(doc.annotations.isEmpty)
    }

    func testPendingTextStyleBelongsToFirstTextCommit() {
        var doc = EditorDocument()
        let id = doc.addText(at: .zero)
        doc.beginStyleGesture(to: .text)
        doc.applyStyle({ $0.fontSize = 36; $0.color = .green }, to: .text)
        doc.endStyleGesture()
        XCTAssertFalse(doc.history.canUndo)
        XCTAssertEqual(doc.pendingTextID, id)
        doc.setText(id, "Label")
        XCTAssertEqual(doc.history.undoStates.count, 1)
        doc.undo(); XCTAssertTrue(doc.annotations.isEmpty)
        doc.redo(); XCTAssertEqual(doc.annotations.first?.style.fontSize, 36)
        XCTAssertEqual(doc.annotations.first?.style.color, .green)
    }

    func testEmptyTextGestureLeavesNoHistory() {
        var doc = EditorDocument()
        let id = doc.addText(at: .zero)
        doc.beginStyleGesture(to: .text)
        doc.applyStyle({ $0.opacity = 0.4 }, to: .text)
        doc.setText(id, "")
        XCTAssertFalse(doc.isStyleGestureActive)
        XCTAssertFalse(doc.history.canUndo)
        XCTAssertTrue(doc.annotations.isEmpty)
        XCTAssertEqual(doc.style(for: .text).opacity, 0.4)
    }

    func testSelectionBoundarySeparatesTargets() {
        var doc = EditorDocument()
        let first = rectangle(&doc), second = rectangle(&doc)
        doc.selectedID = first
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 12 }, to: .rectangle)
        doc.selectedID = second
        XCTAssertFalse(doc.isStyleGestureActive)
        doc.applyStyle({ $0.width = 24 }, to: .rectangle)
        doc.undo()
        XCTAssertEqual(doc.annotations.first { $0.id == first }?.style.width, 12)
        XCTAssertEqual(doc.annotations.first { $0.id == second }?.style.width, 4)
        doc.undo(); XCTAssertEqual(doc.annotations.first { $0.id == first }?.style.width, 4)
    }

    func testToolBoundaryCommitsBeforeNextStyle() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.opacity = 0.2 }, to: .rectangle)
        doc.tool = .shape(.pen)
        XCTAssertFalse(doc.isStyleGestureActive)
        doc.applyStyle({ $0.width = 9 }, to: .pen)
        doc.undo(); XCTAssertEqual(doc.selected?.style.opacity, 1)
        XCTAssertEqual(doc.style(for: .pen).width, 9)
    }

    func testGeometryBoundaryKeepsStyleAndMoveSeparate() {
        var doc = EditorDocument()
        let id = rectangle(&doc)
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 12 }, to: .rectangle)
        doc.beginDrag(); doc.move(id, by: Offset(dx: 10, dy: 20)); doc.endDrag()
        doc.undo()
        XCTAssertEqual(doc.selected?.start, .zero)
        XCTAssertEqual(doc.selected?.style.width, 12)
        doc.undo(); XCTAssertEqual(doc.selected?.style.width, 4)
    }

    func testUndoAndDeletionEndActiveGesture() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 12 }, to: .rectangle)
        doc.undo()
        XCTAssertFalse(doc.isStyleGestureActive)
        XCTAssertEqual(doc.selected?.style.width, 4)
        doc.redo()
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 20 }, to: .rectangle)
        doc.deleteSelected(); doc.undo()
        XCTAssertEqual(doc.annotations.first?.style.width, 20)
        doc.undo(); XCTAssertEqual(doc.annotations.first?.style.width, 12)
    }

    func testRepeatedBeginAndEndDoNotSplitHistory() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        let before = doc.state
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 10 }, to: .rectangle)
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 20 }, to: .rectangle)
        doc.endStyleGesture(); doc.endStyleGesture()
        doc.undo(); XCTAssertEqual(doc.state, before)
    }

    func testDiscreteChangesKeepSeparateUndoSteps() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        doc.applyStyle({ $0.opacity = 0.8 }, to: .rectangle)
        doc.applyStyle({ $0.opacity = 0.6 }, to: .rectangle)
        doc.undo(); XCTAssertEqual(doc.selected?.style.opacity, 0.8)
        doc.undo(); XCTAssertEqual(doc.selected?.style.opacity, 1)
    }

    func testCropBoundaryKeepsStyleAndCropSeparate() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 12 }, to: .rectangle)
        doc.setCrop(CGRect(x: 10, y: 10, width: 30, height: 30))
        doc.undo()
        XCTAssertNil(doc.state.crop)
        XCTAssertEqual(doc.selected?.style.width, 12)
        doc.undo(); XCTAssertEqual(doc.selected?.style.width, 4)
    }

    func testDifferentStyleKindEndsCapturedGesture() {
        var doc = EditorDocument()
        _ = rectangle(&doc)
        doc.beginStyleGesture(to: .rectangle)
        doc.applyStyle({ $0.width = 12 }, to: .rectangle)
        doc.applyStyle({ $0.fontSize = 32 }, to: .text)
        XCTAssertFalse(doc.isStyleGestureActive)
        XCTAssertEqual(doc.selected?.style.width, 12)
        XCTAssertEqual(doc.style(for: .text).fontSize, 32)
        doc.undo(); XCTAssertEqual(doc.selected?.style.width, 4)
    }
}
