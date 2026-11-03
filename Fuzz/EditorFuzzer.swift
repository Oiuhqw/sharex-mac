import Foundation

/// libFuzzer entry point: bytes drive a sequence of editor operations (the overlay's input stream),
/// plus the stitch layout and effect maths on the same bytes. Invariants trap on violation.
struct ByteReader {
    var bytes: [UInt8]; var i = 0
    var done: Bool { i >= bytes.count }
    mutating func u8() -> UInt8 { defer { i += 1 }; return i < bytes.count ? bytes[i] : 0 }
    mutating func i16() -> Int { Int(Int16(bitPattern: UInt16(u8()) << 8 | UInt16(u8()))) }
    mutating func cg() -> CGFloat { CGFloat(i16()) / 4 }
    mutating func point() -> CGPoint { CGPoint(x: cg(), y: cg()) }
}

func check(_ c: Bool, _ m: @autoclosure () -> String) { if !c { fatalError(m()) } }

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    var r = ByteReader(bytes: Array(UnsafeRawBufferPointer(start: start, count: count)))
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var doc = EditorDocument(crop: bounds)
    let initial = doc.state
    var ops = 0, trimmed = false
    while !r.done && ops < 400 {
        ops += 1
        switch r.u8() % 16 {
        case 0, 1:
            let kind = ShapeKind.allCases[Int(r.u8()) % ShapeKind.allCases.count]
            doc.beginDrag(); let id = doc.addShape(kind, at: r.point())
            for _ in 0..<Int(r.u8() % 5) { doc.extendShape(id, to: r.point(), constrain: r.u8() & 1 == 1) }
            doc.endDrag()
        case 2: _ = doc.addText(at: r.point())
        case 3: if let id = doc.pendingTextID ?? doc.selectedID { doc.setText(id, ["", " ", "a", "hi\nthere", "\u{0}"][Int(r.u8()) % 5]) }
        case 4: doc.undo()
        case 5: doc.redo()
        case 6: doc.deleteSelected()
        case 7: doc.selectedID = doc.hitTest(r.point())?.id
        case 8: if let id = doc.selectedID { doc.beginDrag(); doc.move(id, by: Offset(dx: r.cg(), dy: r.cg())); doc.endDrag() }
        case 9: if let id = doc.selectedID {
            doc.beginDrag(); doc.resize(id, handle: Handle.allCases[Int(r.u8()) % 8], by: Offset(dx: r.cg(), dy: r.cg())); doc.endDrag() }
        case 10:
            let kind = ShapeKind.allCases[Int(r.u8()) % ShapeKind.allCases.count]
            let w = Double(r.i16()) / 8, o = Double(r.u8()) / 255
            doc.applyStyle({ $0.width = w; $0.opacity = o; $0.filled.toggle() }, to: kind)
        case 11:
            let a = r.point(), b = r.point()
            if let c = Geometry.cropDrag(from: a, to: b, in: bounds) {
                check(c.width >= 1 && c.height >= 1, "crop too small \(c)"); doc.setCrop(c)
            }
        case 12:
            let n = Int(r.u8() % 4) + 1
            let frames = (0..<n).map { _ in CGRect(x: r.cg() * 8, y: r.cg() * 8, width: abs(r.cg()) * 8, height: abs(r.cg()) * 8) }
            let scales = (0..<n).map { _ in CGFloat(r.u8() % 4) }
            if let l = StitchLayout(frames: frames, scales: scales) {
                check(l.width >= 1 && l.height >= 1 && l.placements.count == n && l.scale > 0, "stitch \(frames) \(scales)")
            }
        case 13:
            let s = Double(r.i16()), sc = CGFloat(r.u8()) / 32
            let sig = EffectMath.blurSigma(strength: s, scale: sc), blk = EffectMath.pixelateBlock(strength: s, scale: sc)
            check(sig >= 4 && sig.isFinite && blk >= 2 && blk.isFinite, "effect \(s) \(sc)")
            let start = r.i16(), cnt = Int(r.u8()), block = Int(r.u8() % 64) + 1, origin = r.i16()
            let st = EffectMath.blockStarts(origin: origin, start: start, count: cnt, block: block)
            check(cnt == 0 || st.first == start, "grid start")
            check(st.allSatisfy { $0 >= start && $0 < start + cnt }, "grid range")
        case 14:
            let rr = CGRect(x: r.cg(), y: r.cg(), width: abs(r.cg()), height: abs(r.cg()))
            let sc = CGFloat(r.u8() % 8 + 1) / 2
            let p = Geometry.pixelRect(rr, scale: sc)
            check(p.w >= 0 && p.h >= 0, "pixelRect \(rr) \(sc)")
        default:
            _ = doc.annotations.map { ($0.bounds, $0.isDegenerate, doc.stepNumber(of: $0)) }
        }
        if let s = doc.selectedID { check(doc.annotations.contains { $0.id == s }, "stale selection") }
        check(Set(doc.annotations.map(\.id)).count == doc.annotations.count, "duplicate ids")
        if doc.history.undoStates.count >= doc.history.limit { trimmed = true }
    }
    // Undo everything: back to the initial state, minus a pending text mark that undo drops.
    // undo() also drops a pending empty text mark, so call it at least once. Skip when the 200-step
    // history limit has discarded the oldest states at any point (later undos can bring the count back down).
    if trimmed { return 0 }
    repeat { doc.undo() } while doc.history.canUndo
    check(doc.state == initial, "undo-all did not restore initial state")
    return 0
}
