import XCTest
@testable import ShareXCore

/// Seeded property-based fuzzing. Every failure prints its seed and case number; rerun with
/// FUZZ_SEED=<seed> to reproduce. FUZZ_SCALE multiplies iteration counts for long soak runs.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let env = ProcessInfo.processInfo.environment
let fuzzSeed = UInt64(env["FUZZ_SEED"] ?? "") ?? 0x5AE7_C0DE
let fuzzScale = Int(env["FUZZ_SCALE"] ?? "") ?? 1

extension SplitMix64 {
    mutating func cg(_ r: ClosedRange<Double>) -> CGFloat { CGFloat(Double.random(in: r, using: &self)) }
    mutating func point(_ span: Double = 2000) -> CGPoint { CGPoint(x: cg(-span...span), y: cg(-span...span)) }
    mutating func rect(_ span: Double = 4000) -> CGRect {
        CGRect(x: cg(-span...span), y: cg(-span...span), width: cg(0...span), height: cg(0...span))
    }
    /// Retina, non-Retina and the odd scaled modes.
    mutating func scale() -> CGFloat { Bool.random(using: &self) ? [1, 2, 3][Int.random(in: 0...2, using: &self)] : cg(0.5...4) }
}

extension CGRect {
    /// Containment with a 1e-6 tolerance, written out because corelibs Foundation's `contains(CGRect)` is unreliable.
    func covers(_ r: CGRect) -> Bool {
        let a = standardized, b = r.standardized, e = 1e-6
        return b.minX >= a.minX - e && b.minY >= a.minY - e && b.maxX <= a.maxX + e && b.maxY <= a.maxY + e
    }
}

final class FuzzTests: XCTestCase {
    var counted = 0
    override func tearDown() { print("fuzz \(name): \(counted) iterations, seed \(fuzzSeed)") }

    // MARK: Geometry

    func testPixelPointRoundTrip() {
        var rng = SplitMix64(fuzzSeed)
        for i in 0..<(40_000 * fuzzScale) {
            let s = rng.scale(), r = rng.rect()
            let p = Geometry.pixelRect(r, scale: s)
            // Outward snapping covers the rect.
            let back = p.points(scale: s)
            XCTAssertTrue(back.covers(r.standardized), "case \(i): \(r) @\(s) -> \(p)")
            // and adds less than one pixel per side.
            XCTAssertLessThanOrEqual(back.width - r.width, 2 / s + 1e-6, "case \(i)")
            // Pixel-aligned rects are a fixed point.
            XCTAssertEqual(Geometry.pixelRect(back, scale: s), p, "case \(i): \(p) @\(s)")
            let w = Int.random(in: 1...10_000, using: &rng), h = Int.random(in: 1...10_000, using: &rng)
            if let c = p.clamped(width: w, height: h) {
                XCTAssertTrue(c.x >= 0 && c.y >= 0 && c.w > 0 && c.h > 0 && c.x + c.w <= w && c.y + c.h <= h, "case \(i)")
                XCTAssertEqual(c.flippedY(height: h).flippedY(height: h), c)
            }
            counted += 1
        }
    }

    func testCocoaTopLeftAndClampInvariants() {
        var rng = SplitMix64(fuzzSeed &+ 1)
        for i in 0..<(20_000 * fuzzScale) {
            let screen = rng.rect(), r = rng.rect()
            let t = Geometry.cocoaToDisplayTopLeft(r, screenFrame: screen)
            XCTAssertEqual(t.size.width, r.size.width, accuracy: 1e-6)
            XCTAssertEqual(t.minY + r.maxY, screen.maxY, accuracy: 1e-6, "case \(i)")
            XCTAssertEqual(t.minX + screen.minX, r.minX, accuracy: 1e-6)
            let b = rng.rect()
            if let c = Geometry.clamp(r, to: b) {
                XCTAssertTrue(b.covers(c), "case \(i)")
                XCTAssertGreaterThanOrEqual(c.width, 1); XCTAssertGreaterThanOrEqual(c.height, 1)
            }
            if let c = Geometry.cropDrag(from: rng.point(), to: rng.point(), in: b) {
                XCTAssertTrue(b.covers(c), "case \(i)")
            }
            counted += 1
        }
    }

    func testMultiDisplayStitch() {
        var rng = SplitMix64(fuzzSeed &+ 2)
        for i in 0..<(10_000 * fuzzScale) {
            let n = Int.random(in: 1...6, using: &rng)
            let frames = (0..<n).map { _ in
                CGRect(x: rng.cg(-8000...8000).rounded(), y: rng.cg(-4000...4000).rounded(),
                       width: rng.cg(640...6016).rounded(), height: rng.cg(480...3384).rounded())
            }
            let scales = (0..<n).map { _ in rng.scale() }
            let u = Geometry.union(frames)
            for f in frames { XCTAssertTrue(u.covers(f), "case \(i)") }
            guard let l = StitchLayout(frames: frames, scales: scales) else {
                XCTAssertGreaterThan(max(u.width, u.height) * scales.max()!, 1e5, "case \(i): rejected only when too big"); counted += 1; continue
            }
            let canvas = CGRect(x: 0, y: 0, width: u.width, height: u.height)
            XCTAssertEqual(l.scale, scales.max()!)
            XCTAssertEqual(CGFloat(l.width), (u.width * l.scale).rounded())
            for (f, p) in zip(frames, l.placements) {
                XCTAssertEqual(p.size, f.size)
                XCTAssertTrue(canvas.covers(p), "case \(i): \(p) outside \(canvas)")
                // Relative position is preserved (y flips).
                XCTAssertEqual(p.minX - f.minX, -u.minX, accuracy: 1e-6)
                XCTAssertEqual(p.maxY + f.minY, u.maxY, accuracy: 1e-6)
            }
            counted += 1
        }
    }

    func testEffectMathNeverWeakOrBroken() {
        var rng = SplitMix64(fuzzSeed &+ 3)
        for i in 0..<(10_000 * fuzzScale) {
            let s = Double.random(in: -100...1000, using: &rng), sc = rng.scale()
            XCTAssertGreaterThanOrEqual(EffectMath.blurSigma(strength: s, scale: sc), 8, "case \(i)")
            XCTAssertGreaterThanOrEqual(EffectMath.pixelateBlock(strength: s, scale: sc), 8, "case \(i)")
            let start = Int.random(in: -5000...5000, using: &rng), count = Int.random(in: 1...3000, using: &rng)
            let block = Int(EffectMath.pixelateBlock(strength: Double.random(in: 0...60, using: &rng), scale: sc))
            let b = EffectMath.blockStarts(origin: start, start: start, count: count, block: block)
            XCTAssertEqual(b.first, start, "case \(i): grid anchored at the region edge")
            XCTAssertEqual(b.count, (count + block - 1) / block)
            counted += 1
        }
    }

    // MARK: Editor

    private static let kinds = ShapeKind.allCases

    /// Random edit sequences, including the app's real call patterns (drag, text, style, crop, delete).
    func testEditorRandomSequences() {
        var rng = SplitMix64(fuzzSeed &+ 4)
        for i in 0..<(4_000 * fuzzScale) {
            let initialCrop: CGRect? = Bool.random(using: &rng) ? CGRect(x: 0, y: 0, width: 800, height: 600) : nil
            var d = EditorDocument(crop: initialCrop)
            var everID = Set<Int>()
            let ops = Int.random(in: 1...60, using: &rng)
            var log: [String] = []
            for _ in 0..<ops {
                let op = Int.random(in: 0..<11, using: &rng)
                log.append("\(op)")
                switch op {
                case 0, 1, 2:
                    let k = Self.kinds.randomElement(using: &rng)!
                    if k == .text { break }
                    d.beginDrag()
                    let id = d.addShape(k, at: rng.point())
                    XCTAssertFalse(everID.contains(id), "case \(i): id \(id) reused"); everID.insert(id)
                    for _ in 0..<Int.random(in: 0...4, using: &rng) { d.extendShape(id, to: rng.point(), constrain: Bool.random(using: &rng)) }
                    d.endDrag()
                case 3:
                    let id = d.addText(at: rng.point())
                    XCTAssertFalse(everID.contains(id), "case \(i): id \(id) reused"); everID.insert(id)
                    if Bool.random(using: &rng) { d.applyStyle({ $0.color = .blue }, to: .text) }
                    d.setText(id, ["", "  ", "Hi", "multi\nline", "😀"].randomElement(using: &rng)!)
                case 4:
                    if let a = d.annotations.randomElement(using: &rng) {
                        d.selectedID = a.id; d.beginDrag()
                        if Bool.random(using: &rng) { d.move(a.id, by: Offset(dx: rng.cg(-50...50), dy: rng.cg(-50...50))) }
                        else { d.resize(a.id, handle: Handle.allCases.randomElement(using: &rng)!, by: Offset(dx: rng.cg(-500...500), dy: rng.cg(-500...500))) }
                        d.endDrag()
                    }
                case 5:
                    if let a = d.annotations.randomElement(using: &rng) { d.selectedID = a.id; d.applyStyle({ $0.width = .random(in: 1...30) }, to: a.kind) }
                case 6:
                    if let a = d.annotations.randomElement(using: &rng) { d.selectedID = a.id; d.deleteSelected() }
                case 7:
                    d.beginDrag()
                    if let r = Geometry.cropDrag(from: rng.point(800), to: rng.point(800), in: CGRect(x: 0, y: 0, width: 800, height: 600)) { d.setCropLive(r) }
                    d.endDrag()
                case 8: d.undo()
                case 9: d.redo()
                default:
                    if Bool.random(using: &rng) { _ = d.addText(at: rng.point()) }   // left pending, as when the user clicks away
                }
                let ids = d.annotations.map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "case \(i): duplicate ids \(ids)")
                if let s = d.selectedID { XCTAssertTrue(ids.contains(s), "case \(i): stale selection") }
            }
            d.beginDrag(); d.endDrag()   // settles a pending text mark
            XCTAssertFalse(d.annotations.contains { $0.kind == .text && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                           "case \(i): invisible text mark; ops \(log)")
            // The newest state reachable is the one after redoing everything still on the redo stack.
            while d.history.canRedo { d.redo() }
            let final = d.state
            var undos = 0
            while d.history.canUndo { d.undo(); undos += 1; if undos > 1000 { break } }
            XCTAssertLessThanOrEqual(undos, ops * 2, "case \(i)")
            XCTAssertTrue(d.annotations.isEmpty, "case \(i): undo-all leaves \(d.annotations.count) marks")
            XCTAssertEqual(d.state.crop, initialCrop, "case \(i): undo-all crop")
            while d.history.canRedo { d.redo() }
            XCTAssertEqual(d.state.annotations.map(\.id), final.annotations.map(\.id), "case \(i): redo-all ids; ops \(log)")
            XCTAssertEqual(d.state, final, "case \(i): redo-all differs; ops \(log)")
            counted += 1
        }
    }

    func testUndoLimitUnderLongSessions() {
        var rng = SplitMix64(fuzzSeed &+ 5)
        for _ in 0..<(20 * fuzzScale) {
            var d = EditorDocument()
            for _ in 0..<Int.random(in: 201...400, using: &rng) {
                d.beginDrag(); let id = d.addShape(.rectangle, at: .zero); d.extendShape(id, to: CGPoint(x: 20, y: 20)); d.endDrag()
            }
            var undos = 0
            while d.history.canUndo { d.undo(); undos += 1 }
            XCTAssertEqual(undos, 200)
            counted += 1
        }
    }

    // MARK: Settings

    func testSettingsDecodingNeverCrashesAndFallsBack() {
        var rng = SplitMix64(fuzzSeed &+ 6)
        let valid = { var s = AppSettings(); s.saveToFile = true; s.toolStyles = [.arrow: .defaults(for: .arrow)]
            s.lastRegion = LastRegion(displayID: 3, rect: CGRect(x: 1, y: 2, width: 3, height: 4)); return s }()
        let good = valid.encoded()
        let json = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
        let junk: [Any] = [NSNull(), 1, -1, 1e308, "x", true, [1, 2], ["a": 1], [String](), "rectangle", ["rectangle": 5]]
        for i in 0..<(30_000 * fuzzScale) {
            let data: Data
            switch i % 4 {
            case 0:   // random bytes
                data = Data((0..<Int.random(in: 0...256, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            case 1:   // valid JSON, bytes flipped
                var b = [UInt8](good)
                for _ in 0..<Int.random(in: 1...8, using: &rng) { b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
                data = Data(b)
            case 2:   // valid JSON, values swapped for wrong types
                var o = json
                for k in o.keys where Bool.random(using: &rng) { o[k] = junk.randomElement(using: &rng)! }
                data = try! JSONSerialization.data(withJSONObject: o)
            default:  // truncated
                data = good.prefix(Int.random(in: 0..<good.count, using: &rng))
            }
            let s = AppSettings.decode(data)
            XCTAssertEqual(AppSettings.decode(s.encoded()), s, "case \(i): decoded settings do not round-trip")
            _ = s.lastRegion?.resolve(displays: [(1, CGSize(width: 1440, height: 900))])
            counted += 1
        }
    }

    // MARK: Sanitizing (round 2)

    func testSanitizedSettingsAreInRangeIdempotentAndRoundTrip() {
        var rng = SplitMix64(fuzzSeed &+ 7)
        func wild() -> Double {
            switch Int.random(in: 0...3, using: &rng) {
            case 0: Double.random(in: -1e6...1e6, using: &rng)
            case 1: [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 0, -0.0][Int.random(in: 0...3, using: &rng)]
            default: Double.random(in: -2...200, using: &rng)
            }
        }
        for i in 0..<(30_000 * fuzzScale) {
            var s = AppSettings()
            s.options.delaySeconds = Int.random(in: Int.min...Int.max, using: &rng) >> Int.random(in: 0...63, using: &rng)
            s.options.borderWidth = Int.random(in: Int.min...Int.max, using: &rng) >> Int.random(in: 0...63, using: &rng)
            s.options.borderColor = RGBA(wild(), wild(), wild(), wild())
            let k = ShapeKind.allCases[Int.random(in: 0..<ShapeKind.allCases.count, using: &rng)]
            s.toolStyles[k] = ShapeStyle(color: RGBA(wild(), wild(), wild(), wild()), width: wild(), opacity: wild(),
                                         filled: Bool.random(using: &rng), fontSize: wild(), strength: wild())
            let d = AppSettings.decode(s.encoded())
            let o = d.options, st = d.toolStyles[k] ?? ShapeStyle()
            XCTAssertTrue((0...CaptureOptions.maxDelaySeconds).contains(o.delaySeconds), "case \(i)")
            XCTAssertTrue((0...CaptureOptions.maxBorderWidth).contains(o.borderWidth), "case \(i)")
            for c in [o.borderColor.r, o.borderColor.g, o.borderColor.b, o.borderColor.a, st.color.r, st.opacity] {
                XCTAssertTrue((0...1).contains(c), "case \(i): \(c)")
            }
            XCTAssertTrue((0...40).contains(st.width) && (8...96).contains(st.fontSize) && (0...100).contains(st.strength), "case \(i)")
            XCTAssertEqual(o.sanitized(), o); XCTAssertEqual(st.sanitized(), st)
            XCTAssertEqual(AppSettings.decode(d.encoded()), d, "case \(i)")
            // Decorating with the stored width is now always representable in pixels.
            _ = DecorationLayout(imageSize: CGSize(width: 100, height: 100), border: o.borderWidth * 3, shadow: o.shadow, scale: 3)
            counted += 1
        }
    }
}
