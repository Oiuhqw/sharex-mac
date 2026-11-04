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

    func testNewAndOlderSettingsSavePNGByDefault() {
        XCTAssertTrue(AppSettings().saveToFile)
        XCTAssertTrue(AppSettings.decode(nil).saveToFile)
        XCTAssertTrue(AppSettings.decode(Data(#"{"playSound":false}"#.utf8)).saveToFile)
    }

    func testExplicitClipboardOnlyPreferenceSurvivesReload() {
        let stored = AppSettings.decode(Data(#"{"saveToFile":false,"saveFolder":"/tmp/captures"}"#.utf8))
        XCTAssertFalse(stored.saveToFile)
        XCTAssertFalse(AppSettings.decode(stored.encoded()).saveToFile)
        XCTAssertEqual(stored.saveFolder, "/tmp/captures")
    }

    func testInvalidStoredRegionDoesNotResetOtherPreferences() {
        let invalid = [
            CGRect(x: 10, y: 20, width: -30, height: 40),
            CGRect(x: 10, y: 20, width: 30, height: 0),
            CGRect(x: 1e300, y: 20, width: 30, height: 40),
            CGRect(x: 10, y: -1e300, width: 30, height: 40),
            CGRect(x: 10, y: 20, width: 1e300, height: 40),
            CGRect(x: CGFloat(Int32.max) - 10, y: 20, width: 30, height: 40),
        ]
        for rect in invalid {
            var stored = AppSettings()
            stored.lastRegion = LastRegion(displayID: 7, rect: rect)
            stored.saveToFile = false
            stored.saveFolder = "/tmp/captures"
            stored.playSound = false
            stored.options.showCursor = true
            stored.toolStyles[.arrow] = ShapeStyle(color: .blue, width: 7)
            var expected = stored
            expected.lastRegion = nil
            XCTAssertEqual(AppSettings.decode(stored.encoded()), expected, "Invalid rectangle \(rect)")
        }
    }

    func testMalformedRegionKeepsUnrelatedSettings() {
        let stored = AppSettings.decode(Data(#"{"lastRegion":{"displayID":7,"rect":[["NaN",20],[30,40]]},"saveToFile":false,"playSound":false}"#.utf8))
        XCTAssertNil(stored.lastRegion)
        XCTAssertFalse(stored.saveToFile)
        XCTAssertFalse(stored.playSound)
    }

    func testNonfiniteRegionCannotBeReplayed() {
        for value in [CGFloat.nan, .infinity, -.infinity] {
            let region = LastRegion(displayID: 1, rect: CGRect(x: value, y: 0, width: 200, height: 100))
            XCTAssertNil(region.resolve(displays: [(1, CGSize(width: 1440, height: 900))]))
        }
    }

    func testLargeValidRegionIsRetainedAndClampedAtReplay() {
        var stored = AppSettings()
        stored.lastRegion = LastRegion(displayID: 1, rect: CGRect(x: -100, y: -100, width: 100_000, height: 100_000))
        let loaded = AppSettings.decode(stored.encoded())
        XCTAssertEqual(loaded.lastRegion, stored.lastRegion)
        XCTAssertEqual(loaded.lastRegion?.resolve(displays: [(1, CGSize(width: 7680, height: 4320))])?.rect,
                       CGRect(x: 0, y: 0, width: 7680, height: 4320))
    }

    func testSettingsBlobLimitRejectsOversizeBeforeDecode() {
        var boundary = Data(#"{"saveToFile":false}"#.utf8)
        boundary.append(Data(repeating: 32, count: AppSettings.maximumStoredBytes - boundary.count))
        XCTAssertFalse(AppSettings.decode(boundary).saveToFile)
        boundary.append(32)
        XCTAssertEqual(AppSettings.decode(boundary), AppSettings())
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
