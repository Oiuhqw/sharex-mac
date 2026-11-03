import XCTest
@testable import ShareXCore

final class AnnotationHitTests: XCTestCase {
    func testArrowheadWingsAreSelectableInEveryDirection() {
        for angle in [CGFloat(0), .pi / 4, .pi / 2, .pi, -.pi / 2] {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: 400 + x * cos(angle) - y * sin(angle),
                        y: 400 + x * sin(angle) + y * cos(angle))
            }
            let a = Annotation(id: 1, kind: .arrow, style: ShapeStyle(width: 40),
                               start: point(0, 0), end: point(300, 0))
            for y in [CGFloat(-55), CGFloat(55)] {
                let wing = point(170, y)
                XCTAssertGreaterThan(Geometry.distance(wing, toSegment: a.start, a.end), 26,
                                     "The regression point must be outside shaft selection tolerance")
                XCTAssertTrue(a.hit(wing))
            }
            XCTAssertFalse(a.hit(point(150, 85)), "Empty space outside the head must remain clickable through")
        }
    }

    func testArrowheadIncludesEdgeToleranceAndShaft() {
        let a = Annotation(id: 1, kind: .arrow, style: ShapeStyle(width: 40),
                           start: .zero, end: CGPoint(x: 300, y: 0))
        let (left, _) = Geometry.arrowHead(tail: a.start, tip: a.end, length: 160)
        XCTAssertTrue(a.hit(CGPoint(x: left.x - 5, y: left.y)), "Selection tolerance includes head corners")
        XCTAssertFalse(a.hit(CGPoint(x: left.x - 8, y: left.y)))
        XCTAssertTrue(a.hit(CGPoint(x: 50, y: 25)), "Shaft tolerance still includes half the stroke width")
        XCTAssertFalse(a.hit(CGPoint(x: 50, y: 27)))
    }

    func testZeroLengthArrowHitDoesNotSelectDistantSpace() {
        let a = Annotation(id: 1, kind: .arrow, style: ShapeStyle(width: 4), start: .zero, end: .zero)
        XCTAssertTrue(a.hit(.zero))
        XCTAssertFalse(a.hit(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(a.isDegenerate, "An un-dragged arrow is still discarded on mouse-up")
    }

    private func ellipse(filled: Bool = false) -> Annotation {
        Annotation(id: 1, kind: .ellipse, style: ShapeStyle(width: 4, filled: filled),
                   start: .zero, end: CGPoint(x: 200, y: 100))
    }

    func testOutlineEllipseIncludesDiagonalEdges() {
        let a = ellipse()
        let q = CGFloat(0.5).squareRoot()
        // These are painted points on all four diagonal quadrants, far from the bounding box edges.
        for sx in [CGFloat(-1), CGFloat(1)] {
            for sy in [CGFloat(-1), CGFloat(1)] {
                XCTAssertTrue(a.hit(CGPoint(x: 100 + sx * 100 * q, y: 50 + sy * 50 * q)))
            }
        }
    }

    func testOutlineEllipseRejectsEmptyCornersAndCenter() {
        let a = ellipse()
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0),
                  CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 100, y: 50)] {
            XCTAssertFalse(a.hit(p))
        }
        XCTAssertTrue(a.hit(CGPoint(x: -7, y: 50)), "Stroke and selection tolerance remain selectable")
        XCTAssertFalse(a.hit(CGPoint(x: -9, y: 50)))
    }

    func testFilledEllipseIncludesInteriorButNotBoundingBoxCorners() {
        let a = ellipse(filled: true)
        XCTAssertTrue(a.hit(CGPoint(x: 100, y: 50)))
        XCTAssertTrue(a.hit(CGPoint(x: 140, y: 60)))
        XCTAssertTrue(a.hit(CGPoint(x: -5, y: 50)))
        XCTAssertFalse(a.hit(CGPoint(x: -7, y: 50)))
        XCTAssertFalse(a.hit(.zero))
        XCTAssertFalse(a.hit(CGPoint(x: 200, y: 100)))
    }

    func testEllipseHitTestingSelectsAndDeletesVisibleTopmostMark() {
        var d = EditorDocument()
        d.beginDrag()
        let back = d.addShape(.highlighter, at: .zero)
        d.extendShape(back, to: CGPoint(x: 200, y: 100))
        d.endDrag()
        d.beginDrag()
        let front = d.addShape(.ellipse, at: .zero)
        d.extendShape(front, to: CGPoint(x: 200, y: 100))
        d.endDrag()
        let q = CGFloat(0.5).squareRoot()
        let edge = CGPoint(x: 100 + 100 * q, y: 50 + 50 * q)
        XCTAssertEqual(d.hitTest(edge)?.id, front)
        XCTAssertEqual(d.hitTest(.zero)?.id, back, "Invisible ellipse corners must not intercept erase/select")
        XCTAssertEqual(d.hitTest(CGPoint(x: 100, y: 50))?.id, back)
        d.selectedID = d.hitTest(edge)?.id
        d.deleteSelected()
        XCTAssertEqual(d.annotations.map(\.id), [back])
        d.undo()
        XCTAssertEqual(d.hitTest(edge)?.id, front)
    }
}
