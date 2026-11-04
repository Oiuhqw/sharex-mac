import XCTest
@testable import ShareXCore

final class GeometryTests: XCTestCase {
    func testCapturePixelsClampsBeforeSnapping() {
        XCTAssertEqual(Geometry.capturePixels(CGRect(x: 10.25, y: 7.75, width: 20.5, height: 10.5), scale: 2, width: 100, height: 80),
                       PixelRect(x: 20, y: 15, w: 42, h: 22))
        XCTAssertEqual(Geometry.capturePixels(CGRect(x: -3.5, y: 39.5, width: 10, height: 12), scale: 2, width: 100, height: 80),
                       PixelRect(x: 0, y: 79, w: 13, h: 1))
        XCTAssertNil(Geometry.capturePixels(CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), scale: 2, width: 100, height: 80))
        XCTAssertNil(Geometry.capturePixels(CGRect(x: 0, y: 0, width: 1, height: 1), scale: .nan, width: 100, height: 80))
    }

    func testPixelCropKeysPreserveOnePixelAndClamp() {
        let area = PixelRect(x: 20, y: 15, w: 42, h: 22)
        XCTAssertEqual(area.adjusted(dx: 1, dy: -1, resizing: false, width: 100, height: 80), PixelRect(x: 21, y: 14, w: 42, h: 22))
        XCTAssertEqual(area.adjusted(dx: -100, dy: 100, resizing: false, width: 100, height: 80), PixelRect(x: 0, y: 58, w: 42, h: 22))
        XCTAssertEqual(area.adjusted(dx: -100, dy: 100, resizing: true, width: 100, height: 80), PixelRect(x: 20, y: 15, w: 1, h: 65))
        XCTAssertEqual(area.adjusted(dx: 10, dy: -10, resizing: true, width: 100, height: 80), PixelRect(x: 20, y: 15, w: 52, h: 12))
    }

    func testRetinaCropDragAllowsOnePixel() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(Geometry.cropDrag(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 10.5, y: 20.5), in: bounds, scale: 2),
                       CGRect(x: 10, y: 20, width: 0.5, height: 0.5))
        XCTAssertNil(Geometry.cropDrag(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 10.4, y: 20.5), in: bounds, scale: 2))
    }

    func testOnePixelCropAtFractionalCanvasScale() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let scale = CGFloat(2040) / 1400
        let start = CGPoint(x: 650, y: 450)
        XCTAssertNotNil(Geometry.cropDrag(from: start,
            to: CGPoint(x: start.x + 1 / scale, y: start.y + 1 / scale), in: bounds, scale: scale))
        XCTAssertNotNil(Geometry.cropDrag(from: CGPoint(x: start.x + 1 / scale, y: start.y + 1 / scale),
            to: start, in: bounds, scale: scale))
        XCTAssertNil(Geometry.cropDrag(from: start,
            to: CGPoint(x: start.x + 0.999 / scale, y: start.y + 1 / scale), in: bounds, scale: scale))
        let expected = PixelRect(x: 947, y: 655, w: 1, h: 1)
        let points = expected.points(scale: scale)
        let accepted = Geometry.cropDrag(from: points.origin,
            to: CGPoint(x: points.maxX, y: points.maxY), in: bounds, scale: scale)
        XCTAssertEqual(accepted.map { Geometry.pixelRect($0, scale: scale) }, expected)
    }

    func testFullyCoveredPixelsPreservePixelDerivedEdges() {
        let area = PixelRect(x: 31, y: 29, w: 100, h: 80)
        for scale in [CGFloat(1), CGFloat(2), CGFloat(2040) / 1400] {
            XCTAssertEqual(Geometry.fullyCoveredPixels(area.points(scale: scale), scale: scale, width: 400, height: 300), area)
        }
        XCTAssertEqual(Geometry.fullyCoveredPixels(CGRect(x: 10.25, y: 7.75, width: 20.5, height: 10.5),
                                                   scale: 2, width: 100, height: 80),
                       PixelRect(x: 21, y: 16, w: 40, h: 20))
        XCTAssertNil(Geometry.fullyCoveredPixels(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                                                 scale: 1, width: 100, height: 80))
    }

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
