import XCTest
@testable import ShareXCore

final class ResizeDragRegressionTests: XCTestCase {
    private func rectangle() -> (EditorDocument, Int) {
        var d = EditorDocument()
        d.beginDrag()
        let id = d.addShape(.rectangle, at: CGPoint(x: 200, y: 200))
        d.extendShape(id, to: CGPoint(x: 400, y: 360))
        d.endDrag()
        return (d, id)
    }

    func testAllHandlesTrackCrossingAndReversalFromOriginalBounds() {
        for handle in Handle.allCases {
            var (d, id) = rectangle()
            let original = d.selected!
            let point = handle.point(on: original.bounds)
            let dx: CGFloat = point.x == original.bounds.minX ? 1 : (point.x == original.bounds.maxX ? -1 : 0)
            let dy: CGFloat = point.y == original.bounds.minY ? 1 : (point.y == original.bounds.maxY ? -1 : 0)
            d.beginDrag()
            for amount in [CGFloat(250), 300, 120, -80] {
                let delta = Offset(dx: dx * amount, dy: dy * amount)
                d.resizeFromDragStart(id, handle: handle, by: delta)
                XCTAssertEqual(d.selected?.bounds, handle.resize(original.bounds, by: delta), "\(handle), delta \(delta)")
            }
            let final = d.selected
            d.endDrag()
            XCTAssertEqual(d.history.undoStates.count, 2, "the whole resize is one undo step")
            d.undo()
            XCTAssertEqual(d.selected, original)
            d.redo()
            XCTAssertEqual(d.selected, final)
        }
    }

    func testLineEndpointDoesNotSwitchWhenItCrossesTheOppositeEndpoint() {
        for kind in [ShapeKind.line, .arrow] {
            var d = EditorDocument()
            d.beginDrag()
            let id = d.addShape(kind, at: CGPoint(x: 100, y: 100))
            d.extendShape(id, to: CGPoint(x: 300, y: 300))
            d.endDrag()
            d.beginDrag()
            for value in [CGFloat(-250), -300, -150, 50] {
                d.resizeFromDragStart(id, handle: .bottomRight, by: Offset(dx: value, dy: value))
                XCTAssertEqual(d.selected?.start, CGPoint(x: 100, y: 100))
                XCTAssertEqual(d.selected?.end, CGPoint(x: 300 + value, y: 300 + value))
            }
            d.endDrag()
        }
    }

    func testPenRecoversOriginalDetailAfterPassingThroughZeroWidth() {
        var d = EditorDocument()
        d.beginDrag()
        let id = d.addShape(.pen, at: CGPoint(x: 100, y: 100))
        d.extendShape(id, to: CGPoint(x: 150, y: 250))
        d.extendShape(id, to: CGPoint(x: 300, y: 300))
        d.endDrag()
        let original = d.selected!
        d.beginDrag()
        for value in [CGFloat(-200), -250, -150, 0] {
            let delta = Offset(dx: value, dy: 0)
            d.resizeFromDragStart(id, handle: .right, by: delta)
            XCTAssertEqual(d.selected?.points, original.resized(.right, by: delta).points)
        }
        XCTAssertEqual(d.selected, original)
        d.endDrag()
        XCTAssertEqual(d.history.undoStates.count, 1, "returning to the original geometry is a no-op")
    }

    func testFixedSizeMarkUsesTotalDeltaRatherThanAccumulatingIt() {
        var d = EditorDocument()
        d.beginDrag()
        let id = d.addShape(.step, at: CGPoint(x: 200, y: 200))
        d.endDrag()
        d.beginDrag()
        d.resizeFromDragStart(id, handle: .bottomRight, by: Offset(dx: 10, dy: 20))
        d.resizeFromDragStart(id, handle: .bottomRight, by: Offset(dx: 30, dy: 40))
        XCTAssertEqual(d.selected?.start, CGPoint(x: 230, y: 240))
        d.endDrag()
    }

    func testResizeWithoutActiveDragDoesNotChangeTheDocument() {
        var (d, id) = rectangle()
        let original = d.state
        d.resizeFromDragStart(id, handle: .right, by: Offset(dx: 80, dy: 0))
        XCTAssertEqual(d.state, original)
    }

    func testPenReleaseAtLastDragPointDoesNotDuplicateSamples() {
        var d = EditorDocument()
        d.beginDrag()
        let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 140, y: 160)
        let id = d.addShape(.pen, at: start)
        d.extendShape(id, to: end)
        d.extendShape(id, to: end)
        XCTAssertEqual(d.selected?.points, [start, end])
        d.endDrag()
        XCTAssertEqual(d.history.undoStates.count, 1)
    }
}
