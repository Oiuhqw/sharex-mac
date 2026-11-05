import XCTest
@testable import ShareXCore

/// One test per bug from the validation round that the core can reproduce.
final class RegressionTests: XCTestCase {
    // validation-macdev "Undo/redo": a new text mark took two undos and left an invisible empty mark.
    func testNewTextIsOneUndoStepAndLeavesNothingBehind() {
        var d = EditorDocument()
        let id = d.addText(at: CGPoint(x: 5, y: 5))
        d.setText(id, "Hello")
        d.undo()
        XCTAssertTrue(d.annotations.isEmpty, "one undo removes the whole text mark")
        XCTAssertFalse(d.history.canUndo)
        d.redo()
        XCTAssertEqual(d.annotations.map(\.text), ["Hello"])
    }

    func testAbandonedTextLeavesNoHistoryAndNoMark() {
        var d = EditorDocument()
        let id = d.addText(at: .zero)
        d.setText(id, "")
        XCTAssertTrue(d.annotations.isEmpty)
        XCTAssertFalse(d.history.canUndo, "nothing visible happened, so nothing to undo")
    }

    func testUndoWhileTextIsPendingDropsTheEmptyMarkAndUndoesThePreviousEdit() {
        var d = EditorDocument()
        d.beginDrag(); let r = d.addShape(.rectangle, at: .zero); d.extendShape(r, to: CGPoint(x: 9, y: 9)); d.endDrag()
        _ = d.addText(at: CGPoint(x: 50, y: 50))
        d.undo()
        XCTAssertTrue(d.annotations.isEmpty)
        XCTAssertNil(d.pendingTextID)
    }

    func testStyleChangeWhileTypingIsPartOfTheTextStep() {
        var d = EditorDocument()
        let id = d.addText(at: .zero)
        d.applyStyle({ $0.color = .blue }, to: .text)
        d.setText(id, "Hi")
        XCTAssertEqual(d.selected?.style.color, .blue)
        d.undo()
        XCTAssertTrue(d.annotations.isEmpty)
    }

    // validation-macdev "Crop": a crop-tool drag under 1 pt set the crop to nil, so Enter did nothing.
    func testTinyCropDragKeepsThePreviousCrop() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertNil(Geometry.cropDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.5, y: 10.2), in: bounds))
        var d = EditorDocument(crop: CGRect(x: 0, y: 0, width: 50, height: 50))
        d.beginDrag()
        if let r = Geometry.cropDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.5, y: 10.2), in: bounds) { d.setCropLive(r) }
        d.endDrag()
        XCTAssertEqual(d.state.crop, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(Geometry.cropDrag(from: CGPoint(x: 190, y: 90), to: CGPoint(x: 300, y: -5), in: bounds),
                       CGRect(x: 190, y: 0, width: 10, height: 90))
    }

    // validation-macdev "Per-tool styles": styles were never saved. The app now writes them; the core must round-trip them.
    func testToolStylesSurviveEncodeDecode() {
        var s = AppSettings()
        var st = ShapeStyle.defaults(for: .rectangle); st.color = .blue; st.width = 7; st.filled = true
        s.toolStyles = [.rectangle: st, .blur: .defaults(for: .blur)]
        s.options.borderColor = .white
        let back = AppSettings.decode(s.encoded())
        XCTAssertEqual(back.toolStyles, s.toolStyles)
        XCTAssertEqual(back.options.borderColor, .white)
    }

    // validation-eng: redaction strength and grid placement had no tests.
    func testBlurSigmaMatchesBoxReferenceWithFloor() {
        XCTAssertEqual(EffectMath.blurSigma(strength: 10, scale: 2), 20)
        XCTAssertEqual(EffectMath.blurSigma(strength: 1, scale: 1), 8, "weak settings still redact")
        XCTAssertEqual(EffectMath.blurSigma(strength: .nan, scale: 2), 16)
        XCTAssertEqual(EffectMath.pixelateBlock(strength: 0.5, scale: 1), 8)
        XCTAssertEqual(EffectMath.pixelateBlock(strength: 2, scale: 2), 16, "N1: 2 pt floored to 8 pt")
        XCTAssertEqual(EffectMath.blurSigma(strength: 2, scale: 2), 16)
        XCTAssertEqual(EffectMath.pixelateBlock(strength: 8, scale: 2), 16)
    }

    func testPixelateGridStartsAtRegionTopLeft() {
        // y-up region 30..<70 (x), 10..<50 (y). Top-left in y-up is (minX, maxY).
        let r = PixelRect(x: 30, y: 10, w: 40, h: 40)
        XCTAssertEqual(EffectMath.pixelateCenter(yUp: r), CGPoint(x: 30, y: 50))
        // With the grid anchored at the region edge, the first block starts exactly at it and none straddles it.
        XCTAssertEqual(EffectMath.blockStarts(origin: 30, start: 30, count: 40, block: 16), [30, 46, 62])
        // A grid anchored elsewhere would cut a partial block at the edge.
        XCTAssertEqual(EffectMath.blockStarts(origin: 0, start: 30, count: 40, block: 16).first, 30)
        XCTAssertEqual(EffectMath.blockStarts(origin: 0, start: 30, count: 40, block: 16).dropFirst().first, 32)
    }

    func testStitchUsesMaxScaleAndGlobalPositions() {
        // Primary 1440×900 @2x, secondary 1920×1080 @1x to the left and lower.
        let l = StitchLayout(frames: [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -180, width: 1920, height: 1080)],
                             scales: [2, 1])!
        XCTAssertEqual(l.scale, 2)
        XCTAssertEqual(l.width, 3360 * 2); XCTAssertEqual(l.height, 1080 * 2)
        XCTAssertEqual(l.placements[0], CGRect(x: 1920, y: 0, width: 1440, height: 900))
        XCTAssertEqual(l.placements[1], CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertNil(StitchLayout(frames: [], scales: []))
    }
}

/// Found by FuzzTests: corrupt bytes in stored settings trapped inside Foundation's JSONDecoder.
final class SettingsCrashRegressionTests: XCTestCase {
    func testControlCharacterInKeyFallsBackInsteadOfTrapping() {
        let bad = Data("{\"toolStyles\":{\"rect\u{10}angle\":{}},\"saveToFile\":true}".utf8)
        XCTAssertEqual(AppSettings.decode(bad), AppSettings())
    }
}

/// Found by FuzzTests: an untyped text mark leaked into history when another mark's style changed.
final class EditorFuzzRegressionTests: XCTestCase {
    func testStyleChangeOnOtherMarkDoesNotCaptureUntypedText() {
        var d = EditorDocument()
        d.beginDrag(); let r = d.addShape(.rectangle, at: .zero); d.extendShape(r, to: CGPoint(x: 9, y: 9)); d.endDrag()
        _ = d.addText(at: CGPoint(x: 50, y: 50))
        d.selectedID = r
        d.applyStyle({ $0.width = 9 }, to: .rectangle)
        d.undo(); d.redo()
        XCTAssertEqual(d.annotations.map(\.kind), [.rectangle])
    }

    func testEmptyTextClearsSelection() {
        var d = EditorDocument()
        let id = d.addText(at: .zero)
        d.setText(id, " ")
        XCTAssertNil(d.selectedID)
    }

    func testNewTextWhileAnotherIsPendingDropsTheFirst() {
        var d = EditorDocument()
        _ = d.addText(at: .zero)
        let b = d.addText(at: CGPoint(x: 40, y: 40))
        d.setText(b, "B")
        d.undo()
        XCTAssertTrue(d.annotations.isEmpty)
    }
}
