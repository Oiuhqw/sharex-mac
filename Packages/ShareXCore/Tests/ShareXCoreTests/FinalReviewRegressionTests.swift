import XCTest
@testable import ShareXCore

/// Bugs found in the final validation pass (static review and fuzz round 2).
final class FinalReviewRegressionTests: XCTestCase {
    private func json(_ s: String) -> AppSettings { AppSettings.decode(Data(s.utf8)) }

    // toolStyles is a [ShapeKind: ShapeStyle], which JSONEncoder writes as a flat [key, value, …] array.
    // Settings written before borderColor existed: synthesized decoding threw on the missing key and
    // reset every capture option to its default.
    func testOldSettingsWithoutBorderColorKeepTheirOptions() {
        let s = json(#"{"options":{"delaySeconds":3,"showCursor":true,"showMagnifier":false,"borderWidth":5,"shadow":true,"openEditor":false}}"#)
        XCTAssertEqual(s.options.delaySeconds, 3)
        XCTAssertTrue(s.options.showCursor)
        XCTAssertFalse(s.options.showMagnifier)
        XCTAssertEqual(s.options.borderWidth, 5)
        XCTAssertTrue(s.options.shadow)
        XCTAssertFalse(s.options.openEditor)
        XCTAssertEqual(s.options.borderColor, CaptureOptions().borderColor)
    }

    func testToolStyleMissingAFieldKeepsTheRest() {
        let s = json(#"{"toolStyles":["arrow",{"color":{"r":0,"g":1,"b":0,"a":1},"width":7}]}"#)
        XCTAssertEqual(s.toolStyles[.arrow]?.width, 7)
        XCTAssertEqual(s.toolStyles[.arrow]?.color, .green.with(g: 1, r: 0, b: 0))
        XCTAssertEqual(s.toolStyles[.arrow]?.fontSize, ShapeStyle().fontSize)
    }

    // A hand-edited border width of Int.max made Export.decorate trap converting Double to Int.
    func testOutOfRangeValuesAreClampedOnLoad() {
        let s = json(#"{"options":{"delaySeconds":-5,"borderWidth":9223372036854775807,"borderColor":{"r":7,"g":-1,"b":0.5,"a":2}},"#
                     + #""toolStyles":["blur",{"color":{"r":0,"g":0,"b":0,"a":1},"width":-3,"opacity":0,"filled":false,"fontSize":1e300,"strength":1e9}]}"#)
        XCTAssertEqual(s.options.delaySeconds, 0)
        XCTAssertEqual(s.options.borderWidth, CaptureOptions.maxBorderWidth)
        XCTAssertEqual(s.options.borderColor, RGBA(1, 0, 0.5, 1))
        let b = s.toolStyles[.blur]
        XCTAssertEqual(b?.width, 0); XCTAssertEqual(b?.opacity, 0.1); XCTAssertEqual(b?.fontSize, 96); XCTAssertEqual(b?.strength, 100)
        XCTAssertEqual(AppSettings.decode(s.encoded()), s, "sanitized settings round-trip")
    }

    func testDelayAboveTheLimitIsClamped() {
        XCTAssertEqual(json(#"{"options":{"delaySeconds":100000}}"#).options.delaySeconds, CaptureOptions.maxDelaySeconds)
    }

    // Two captures in the same second overwrote each other's PNG.
    func testSaveNamesNeverCollide() {
        let d = Date(timeIntervalSince1970: 0), tz = TimeZone(identifier: "UTC")!
        var taken: Set<String> = []
        for _ in 0..<4 { taken.insert(AppSettings.uniqueFileName(for: d, timeZone: tz) { taken.contains($0) }) }
        XCTAssertEqual(taken, ["ShareX_1970-01-01_00-00-00.png", "ShareX_1970-01-01_00-00-00-2.png",
                               "ShareX_1970-01-01_00-00-00-3.png", "ShareX_1970-01-01_00-00-00-4.png"])
    }
}

private extension RGBA {
    func with(g: Double, r: Double, b: Double) -> RGBA { RGBA(r, g, b, a) }
}
