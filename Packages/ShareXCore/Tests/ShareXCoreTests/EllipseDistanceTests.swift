import XCTest
@testable import ShareXCore

final class EllipseDistanceTests: XCTestCase {
    func testSignedDistanceAtCenterAndAxisPoints() {
        let ellipse = CGRect(x: -5, y: -3, width: 10, height: 6)
        XCTAssertEqual(Geometry.signedDistance(.zero, toEllipse: ellipse), -3, accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 0, y: 1), toEllipse: ellipse), -2, accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 0, y: 5), toEllipse: ellipse), 2, accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 1.6, y: 0), toEllipse: ellipse), -sqrt(7.56), accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 4, y: 0), toEllipse: ellipse), -1, accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 7, y: 0), toEllipse: ellipse), 2, accuracy: 1e-12)
    }

    func testSignedDistanceForCircle() {
        let circle = CGRect(x: -5, y: -5, width: 10, height: 10)
        XCTAssertEqual(Geometry.signedDistance(.zero, toEllipse: circle), -5, accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 3, y: 4), toEllipse: circle), 0, accuracy: 1e-12)
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: 6, y: 8), toEllipse: circle), 5, accuracy: 1e-12)
    }

    func testEdgeDistancePreservesScaleAndQuadrant() {
        for scale in [CGFloat(1e-150), 1, 1e150] {
            let ellipse = CGRect(x: -100 * scale, y: -50 * scale, width: 200 * scale, height: 100 * scale)
            let nx: CGFloat = 0.006, ny: CGFloat = 0.016, length = hypot(nx, ny)
            for sx in [CGFloat(-1), CGFloat(1)] {
                for sy in [CGFloat(-1), CGFloat(1)] {
                    let p = CGPoint(x: sx * (60 + 4 * nx / length) * scale,
                                    y: sy * (40 + 4 * ny / length) * scale)
                    XCTAssertEqual(Geometry.signedDistance(p, toEllipse: ellipse) / scale, 4, accuracy: 1e-10)
                }
            }
        }
    }

    func testEmptyAndNonfiniteEllipsesHaveNoSelectableEdge() {
        for size in [CGSize.zero, CGSize(width: 0, height: 10), CGSize(width: 10, height: 0)] {
            let ellipse = CGRect(origin: .zero, size: size)
            XCTAssertEqual(Geometry.signedDistance(.zero, toEllipse: ellipse), .infinity)
            let a = Annotation(id: 1, kind: .ellipse, style: ShapeStyle(width: 40),
                               start: .zero, end: CGPoint(x: size.width, y: size.height))
            XCTAssertFalse(a.hit(.zero))
        }
        XCTAssertEqual(Geometry.signedDistance(CGPoint(x: CGFloat.nan, y: 0),
                                              toEllipse: CGRect(x: 0, y: 0, width: 100, height: 50)), .infinity)
        XCTAssertEqual(Geometry.signedDistance(.zero,
                                              toEllipse: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 50)), .infinity)
    }
}
