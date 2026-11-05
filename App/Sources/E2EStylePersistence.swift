#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EStylePersistence {
    static func run() {
        guard let image = E2E.checker(160, 120) else {
            E2E.record("style-persistence-fixture", false); return
        }
        let frozen = FrozenScreen(screen: E2E.screen, displayID: ScreenCapture.displayID(of: E2E.screen), image: image)
        var initial = AppSettings()
        initial.toolStyles = [.rectangle: ShapeStyle(color: .red, width: 4),
                              .pen: ShapeStyle(color: .yellow, width: 7)]

        func scenario(_ name: String, finish: Bool, change: (EditorView, EditorView) -> Void,
                      verify: ([ShapeKind: ShapeStyle]) -> Bool) {
            var saved: [ShapeKind: ShapeStyle]?
            var completed = 0
            var finished = false
            let controller = OverlayController(frozen: [frozen], mode: .rectangle, preset: nil, settings: initial,
                                               onStyles: { saved = $0 }) { outcome in
                completed += 1
                if case .finished = outcome { finished = true }
            }
            let surfaces = controller.e2eSurfaces
            guard let first = surfaces.first else { E2E.record(name, false); return }
            let a = first.view
            let b = EditorView(frame: a.bounds, session: a.session, viewport: a.viewport, image: image, showMagnifier: false)
            change(a, b)
            if finish { a.session.selectDesktop(); a.finish() }
            else { a.cancel() }
            E2E.record(name, completed == 1 && finished == finish && saved.map(verify) == true,
                       ["surfaces": surfaces.count, "fixtureOnly": true])
        }

        scenario("styles-first-screen-cancel", finish: false, change: { a, _ in
            a.setTool(.shape(.rectangle)); a.changeStyle { $0.color = .blue }
        }, verify: { $0[.rectangle]?.color == .blue && $0[.pen] == initial.toolStyles[.pen] })

        scenario("styles-first-screen-finish", finish: true, change: { a, _ in
            a.setTool(.shape(.rectangle)); a.changeStyle { $0.color = .blue; $0.width = 9 }
        }, verify: { $0[.rectangle]?.color == .blue && $0[.rectangle]?.width == 9 && $0[.pen] == initial.toolStyles[.pen] })

        scenario("styles-across-screens-keep-other-tools", finish: false, change: { a, b in
            a.setTool(.shape(.rectangle)); a.changeStyle { $0.color = .blue }
            b.setTool(.shape(.pen)); b.changeStyle { $0.width = 12 }
        }, verify: { $0[.rectangle]?.color == .blue && $0[.pen]?.width == 12 && $0[.pen]?.color == .yellow })

        scenario("styles-latest-edit-wins-not-screen-order", finish: false, change: { a, b in
            b.setTool(.shape(.rectangle)); b.changeStyle { $0.color = .blue }
            a.setTool(.shape(.rectangle)); a.changeStyle { $0.color = .green }
            b.setTool(.select) // Merely activating an older surface must not restore its stale style.
        }, verify: { $0[.rectangle]?.color == .green && $0[.pen] == initial.toolStyles[.pen] })

        scenario("styles-partial-edits-preserve-other-fields", finish: true, change: { a, b in
            a.setTool(.shape(.rectangle)); a.changeStyle { $0.color = .blue }
            b.setTool(.shape(.rectangle)); b.changeStyle { $0.width = 13 }
            a.changeStyle { $0.opacity = 0.5 }
        }, verify: { $0[.rectangle]?.color == .blue && $0[.rectangle]?.width == 13
            && $0[.rectangle]?.opacity == 0.5 && $0[.pen] == initial.toolStyles[.pen] })

        scenario("styles-no-edit-cancel-preserves-defaults", finish: false, change: { _, _ in },
                 verify: { $0 == initial.toolStyles })
    }
}
#endif
