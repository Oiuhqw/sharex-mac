import XCTest
@testable import ShareXCore

final class GeometryTests: XCTestCase {
    func testRectFromAnyDragDirection() {
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)), r)
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 20)), r)
    }

    func testCocoaToDisplayTopLeftOnPrimary() {
        // Primary 1440x900. A rect 100pt from the bottom, 50pt tall, is 750pt from the top.
        let s = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let r = Geometry.cocoaToDisplayTopLeft(CGRect(x: 10, y: 100, width: 20, height: 50), screenFrame: s)
        XCTAssertEqual(r, CGRect(x: 10, y: 750, width: 20, height: 50))
    }

    func testCocoaToDisplayTopLeftOnSecondaryAboveLeft() {
        // External display to the left and above the primary (negative x, y beyond primary height).
        let s = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        let r = Geometry.cocoaToDisplayTopLeft(CGRect(x: -1920, y: 1880, width: 100, height: 100), screenFrame: s)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testPixelRectSnapsOutward() {
        let p = Geometry.pixelRect(CGRect(x: 10.3, y: 5.6, width: 1.0, height: 1.0), scale: 2)
        XCTAssertEqual(p, PixelRect(x: 20, y: 11, w: 3, h: 3))
        XCTAssertEqual(Geometry.pixelRect(CGRect(x: 1, y: 2, width: 3, height: 4), scale: 2), PixelRect(x: 2, y: 4, w: 6, h: 8))
    }

    func testPixelRectClampFlipAndBackToPoints() {
        let r = PixelRect(x: -4, y: 6, w: 20, h: 10)
        XCTAssertEqual(r.clamped(width: 10, height: 12), PixelRect(x: 0, y: 6, w: 10, h: 6))
        XCTAssertNil(r.clamped(width: 10, height: 6))
        XCTAssertEqual(PixelRect(x: 2, y: 3, w: 4, h: 5).flippedY(height: 20), PixelRect(x: 2, y: 12, w: 4, h: 5))
        XCTAssertEqual(PixelRect(x: 2, y: 4, w: 6, h: 8).points(scale: 2), CGRect(x: 1, y: 2, width: 3, height: 4))
        // Round trip through points at an awkward scale gives the same pixels back.
        let odd = PixelRect(x: 7, y: 13, w: 101, h: 59)
        for s in [1.0, 2.0, 3.0, 1.37, 2.71] as [CGFloat] { XCTAssertEqual(Geometry.pixelRect(odd.points(scale: s), scale: s), odd) }
    }

    func testClamp() {
        let b = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(Geometry.clamp(CGRect(x: -10, y: 90, width: 30, height: 30), to: b), CGRect(x: 0, y: 90, width: 20, height: 10))
        XCTAssertNil(Geometry.clamp(CGRect(x: 200, y: 200, width: 5, height: 5), to: b))
    }

    func testSegmentDistance() {
        XCTAssertEqual(Geometry.distance(CGPoint(x: 5, y: 3), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 3, accuracy: 1e-9)
        XCTAssertEqual(Geometry.distance(CGPoint(x: 13, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 5, accuracy: 1e-9)
        XCTAssertEqual(Geometry.distance(CGPoint(x: 3, y: 4), toSegment: .zero, .zero), 5, accuracy: 1e-9)
    }

    func testArrowHeadPointsBackFromTip() {
        let (a, b) = Geometry.arrowHead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), length: 10)
        XCTAssertLessThan(a.x, 100); XCTAssertLessThan(b.x, 100)
        XCTAssertEqual(a.y, -b.y, accuracy: 1e-9)
    }

    func testHandleResizeAndFlip() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(Handle.bottomRight.resize(r, by: Offset(dx: 5, dy: 5)), CGRect(x: 10, y: 10, width: 25, height: 25))
        XCTAssertEqual(Handle.left.resize(r, by: Offset(dx: 30, dy: 99)), CGRect(x: 30, y: 10, width: 10, height: 20))
        XCTAssertEqual(Handle.hit(CGPoint(x: 31, y: 9), on: r, tolerance: 2), .topRight)
        XCTAssertNil(Handle.hit(CGPoint(x: 20, y: 20), on: r, tolerance: 2))
    }

    func testDecorationLayout() {
        let plain = DecorationLayout(imageSize: CGSize(width: 100, height: 50), border: 0, shadow: false)
        XCTAssertEqual(plain.canvas, CGSize(width: 100, height: 50))
        XCTAssertEqual(plain.image.origin, .zero)
        let d = DecorationLayout(imageSize: CGSize(width: 100, height: 50), border: 2, shadow: true)
        let pad = DecorationLayout.shadowBlurPoints + DecorationLayout.shadowOffsetPoints + 2
        XCTAssertEqual(d.canvas, CGSize(width: 100 + 2 * pad, height: 50 + 2 * pad))
        XCTAssertEqual(d.image, CGRect(x: pad, y: pad, width: 100, height: 50))
        // At 2x the shadow doubles in pixels so it looks the same size on screen.
        let r = DecorationLayout(imageSize: CGSize(width: 100, height: 50), border: 0, shadow: true, scale: 2)
        XCTAssertEqual(r.shadowBlur, 2 * DecorationLayout.shadowBlurPoints)
        XCTAssertEqual(r.image.minX, 2 * (DecorationLayout.shadowBlurPoints + DecorationLayout.shadowOffsetPoints))
    }
}
