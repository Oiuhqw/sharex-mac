import XCTest
@testable import ShareXCore

final class SettingsTests: XCTestCase {
    func testRoundTrip() {
        var s = AppSettings()
        s.options.delaySeconds = 3; s.options.showCursor = true
        s.toolStyles[.arrow] = ShapeStyle(color: .blue, width: 7)
        s.lastRegion = LastRegion(displayID: 2, rect: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(AppSettings.decode(s.encoded()), s)
    }

    func testCorruptOrPartialDataFallsBackPerKey() {
        XCTAssertEqual(AppSettings.decode(Data("nope".utf8)), AppSettings())
        XCTAssertEqual(AppSettings.decode(nil), AppSettings())
        let partial = AppSettings.decode(Data(#"{"saveToFile":true}"#.utf8))
        XCTAssertTrue(partial.saveToFile)
        XCTAssertEqual(partial.options, CaptureOptions())
    }

    func testLastRegionResolves() {
        let lr = LastRegion(displayID: 7, rect: CGRect(x: 100, y: 100, width: 500, height: 500))
        let both: [(id: UInt32, size: CGSize)] = [(1, CGSize(width: 1440, height: 900)), (7, CGSize(width: 400, height: 400))]
        XCTAssertEqual(lr.resolve(displays: both)?.id, 7)
        XCTAssertEqual(lr.resolve(displays: both)?.rect, CGRect(x: 100, y: 100, width: 300, height: 300))
        XCTAssertEqual(lr.resolve(displays: [(1, CGSize(width: 1440, height: 900))])?.id, 1, "display unplugged → primary")
        XCTAssertNil(lr.resolve(displays: []))
    }

    func testFileName() {
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(AppSettings.fileName(for: d, timeZone: TimeZone(identifier: "UTC")!), "ShareX_1970-01-01_00-00-00.png")
    }

    func testStyleSelectionModes() {
        XCTAssertEqual(CaptureStyle.region.selection, .rectangle)
        XCTAssertEqual(CaptureStyle.freehand.selection, .lasso)
        XCTAssertEqual(CaptureStyle.windowPicker.selection, .pickWindow)
        XCTAssertEqual(CaptureStyle.monitorPicker.selection, .pickMonitor)
        XCTAssertEqual(CaptureStyle.fullscreen.selection, .none)
        XCTAssertEqual(CaptureStyle.allCases.count, 8)
    }
}
