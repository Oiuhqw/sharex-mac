import XCTest
@testable import ShareXCore

final class DesktopTests: XCTestCase {
    private func map(_ frames: [CGRect], scales: [CGFloat] = [1, 2], offset: CGPoint = .zero) -> DesktopLayout {
        DesktopLayout(displays: frames.enumerated().map {
            .init(id: UInt32($0.offset + 1), frame: $0.element.offsetBy(dx: offset.x, dy: offset.y), scale: scales[$0.offset])
        })!
    }
    func testNegativeAndVerticalDesktopCoordinates() {
        let desktop = map([CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: -800, y: 600, width: 800, height: 600)])
        XCTAssertEqual(desktop.bounds, CGRect(x: 0, y: 0, width: 1600, height: 1200))
        XCTAssertEqual(desktop.point(cocoa: CGPoint(x: -20, y: 650)), CGPoint(x: 780, y: 550))
        XCTAssertEqual(desktop.placement(desktop.displays[0]), CGRect(x: 800, y: 600, width: 800, height: 600))
    }
    func testCropScaleUsesPositiveAreaIntersections() {
        let desktop = map([CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 800, y: 0, width: 800, height: 600)])
        XCTAssertEqual(desktop.scale(for: CGRect(x: 700, y: 100, width: 100, height: 100)), 1)
        XCTAssertEqual(desktop.scale(for: CGRect(x: 700, y: 100, width: 100.5, height: 100)), 2)
        XCTAssertEqual(desktop.scale(for: desktop.bounds), 2)
    }
    func testSparseUnionDoesNotRejectSmallSelectionAndRejectsGap() {
        let desktop = map([CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 100_000, y: 0, width: 800, height: 600)])
        let crop = CGRect(x: 50, y: 50, width: 120, height: 80)
        XCTAssertEqual(desktop.selection(crop), crop)
        XCTAssertEqual(desktop.scale(for: crop), 1)
        XCTAssertNil(desktop.selection(CGRect(x: 1000, y: 100, width: 200, height: 100)))
        XCTAssertGreaterThan(desktop.bounds.width * desktop.bounds.height * 4, 64 * 1024 * 1024)
    }
    func testLastRegionAllowsCommonTranslationScaleChangeAndExtraDisplays() throws {
        let frames = [CGRect(x: -800, y: 0, width: 800, height: 600), CGRect(x: 0, y: 0, width: 800, height: 600)]
        let desktop = map(frames), crop = CGRect(x: 700, y: 120, width: 200, height: 180)
        let saved = try XCTUnwrap(LastRegion(crop: crop, layout: desktop))
        let restored = try JSONDecoder().decode(LastRegion.self, from: JSONEncoder().encode(saved))
        let moved = map(frames, scales: [2, 1], offset: CGPoint(x: 150, y: -300))
        XCTAssertEqual(restored.resolve(layout: moved), crop)
        let expanded = try XCTUnwrap(DesktopLayout(displays: moved.displays + [.init(id: 3, frame: CGRect(x: -2000, y: 900, width: 300, height: 200), scale: 2)]))
        let result = try XCTUnwrap(restored.resolve(layout: expanded))
        XCTAssertEqual(result.origin.x - expanded.placement(expanded.displays[0]).minX, 700)
        XCTAssertEqual(result.size, crop.size)
    }
    func testLastRegionRejectsMissingMovedOrResizedParticipants() throws {
        let frames = [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 800, y: 0, width: 800, height: 600)]
        let saved = try XCTUnwrap(LastRegion(crop: CGRect(x: 700, y: 100, width: 200, height: 100), layout: map(frames)))
        XCTAssertNil(saved.resolve(layout: map([frames[0]], scales: [1])))
        XCTAssertNil(saved.resolve(layout: map([frames[0], frames[1].offsetBy(dx: 1, dy: 0)])))
        XCTAssertNil(saved.resolve(layout: map([frames[0], CGRect(x: 800, y: 0, width: 801, height: 600)])))
    }
    func testLegacyLastRegionStillClamps() throws {
        let legacy = LastRegion(displayID: 1, rect: CGRect(x: 700, y: 500, width: 300, height: 300))
        let decoded = try JSONDecoder().decode(LastRegion.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.participants)
        XCTAssertEqual(decoded.resolve(layout: map([CGRect(x: -800, y: 0, width: 800, height: 600)], scales: [1])),
                       CGRect(x: 700, y: 500, width: 100, height: 100))
    }
    func testSingleDisplayRegionIgnoresUntouchedDisplayMovement() throws {
        let frames = [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 800, y: 0, width: 800, height: 600)]
        let crop = CGRect(x: 200, y: 100, width: 100, height: 100)
        let saved = try XCTUnwrap(LastRegion(crop: crop, layout: map(frames)))
        XCTAssertEqual(saved.participants?.count, 1)
        XCTAssertEqual(saved.resolve(layout: map([frames[0], frames[1].offsetBy(dx: 200, dy: 0)])), crop)
    }
}
