import XCTest
import Foundation
@testable import ShareXCore

/// Exhaustive / seeded property checks for the formal review.
final class PropertyTests: XCTestCase {
    /// Crop normalisation: for every drag on a grid, the result is nil or a rect inside bounds, ≥1pt,
    /// independent of drag direction.
    func testCropDragExhaustive() {
        let b = CGRect(x: 0, y: 0, width: 20, height: 15)
        let vals: [CGFloat] = [-3, -0.5, 0, 0.4, 1, 5.5, 10, 14.6, 15, 19, 20, 23]
        for ax in vals { for ay in vals { for bx in vals { for by in vals {
            let a = CGPoint(x: ax, y: ay), c = CGPoint(x: bx, y: by)
            let r = Geometry.cropDrag(from: a, to: c, in: b)
            XCTAssertEqual(r, Geometry.cropDrag(from: c, to: a, in: b))
            guard let r else { continue }
            XCTAssertTrue(b.contains(r), "\(r)")
            XCTAssertGreaterThanOrEqual(r.width, 1); XCTAssertGreaterThanOrEqual(r.height, 1)
            XCTAssertEqual(Geometry.clamp(r, to: b), r, "clamp idempotent")
        }}}}
    }

    /// Clamp result is always within both inputs.
    func testClampContainedInBoth() {
        var g = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            func v() -> CGFloat { CGFloat(Int.random(in: -50...50, using: &g)) / 2 }
            let r = CGRect(x: v(), y: v(), width: v(), height: v()), b = CGRect(x: v(), y: v(), width: abs(v()), height: abs(v()))
            if let c = Geometry.clamp(r, to: b) {
                XCTAssertTrue(b.contains(c)); XCTAssertTrue(r.standardized.contains(c))
            }
        }
    }

    /// Undo/redo are inverses: after n edits, undo k then redo k returns the same state; undo all returns initial.
    func testUndoRedoInverse() {
        for n in 1...8 { for k in 0...n {
            var d = EditorDocument()
            let s0 = d.state
            var states = [s0]
            for i in 0..<n {
                d.beginDrag()
                if i % 3 == 2 { d.setCropLive(CGRect(x: i, y: i, width: 10, height: 10)) }
                else { let id = d.addShape(i % 2 == 0 ? .rectangle : .arrow, at: CGPoint(x: i * 5, y: i * 5)); d.extendShape(id, to: CGPoint(x: i * 5 + 20, y: i * 5 + 20)) }
                d.endDrag()
                states.append(d.state)
            }
            let end = d.state
            for j in 0..<k { d.undo(); XCTAssertEqual(d.state, states[n - j - 1], "n=\(n) undo \(j + 1)") }
            for _ in 0..<k { d.redo() }
            XCTAssertEqual(d.state, end, "n=\(n) k=\(k)")
            for _ in 0..<n { d.undo() }
            XCTAssertEqual(d.state, s0)
            d.undo(); XCTAssertEqual(d.state, s0, "extra undo is a no-op")
        }}
    }
}
