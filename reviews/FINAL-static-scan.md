# Final static scan — 2026-11-03 (UTC+8)

| Scan | Result |
|---|---|
| `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` (core, clean scratch dir) | **0 warnings, 0 errors** |
| `swift test` | **56 / 56 pass** |
| `swiftc -parse` on all 13 App/Sources files | **all parse** |
| SwiftLint 0.65.1, default rules | 442: identifier_name 343, line_length 76, switch_case_alignment 8, cyclomatic_complexity 6, trailing_comma 2, multiple_closures_with_trailing_closure 2, function_body_length 2, type/file length 2, large_tuple 1. All style, accepted (short math names like `r`, `px`; key-dispatch switches). |
| SwiftLint strict (force_unwrapping, force_try, force_cast, IUO, weak_delegate) | before: 4 findings → after: **1** (accepted, below) |
| semgrep 1.x, custom Swift rules (`try!`, `as!`, `fatalError`, `[0]`, postfix `!`, escaping closures capturing `self` strongly, `DispatchQueue.global`/threads) | 10 hits → triaged below; **0** strong-`self` escaping closures, **0** off-main UI |
| TODO / FIXME / XXX / HACK / stub / unimplemented grep | **0** |
| Dead code (symbols referenced only at their definition) | 14 hits: 12 are AppKit overrides and delegate callbacks (accepted). `EffectMath.blockStarts` is a test oracle for the pixelate grid (accepted). `EditorDocument.setCrop` is the undoable crop API that tests and the fuzzer use; the app goes through setCropLive+endDrag (accepted). |

## Findings and triage

| # | Where | Finding | Decision |
|---|---|---|---|
| 1 | Settings decode (core) | Values in a corrupt or hand-edited `settings.v1` were not range-checked. `borderWidth: Int.max` made `Export.decorate` trap converting Double→Int, and a negative or huge width or blur strength also got through | **Fixed.** `CaptureOptions/ShapeStyle/RGBA.sanitized()` clamp to the UI ranges and run inside `AppSettings.decode`. `Export.decorate` also sanitizes its input. Regression tests plus a 300k-iteration fuzz property |
| 2 | `CaptureOptions` / `ShapeStyle` Codable (core) | Synthesized decoding: one missing key reset the whole group. Settings saved before `borderColor` existed lost every capture option on upgrade | **Fixed.** Tolerant per-key `init(from:)`. Regression tests |
| 3 | Export.savePNG | Two captures in the same second overwrote each other's file | **Fixed.** `AppSettings.uniqueFileName` (`-2`, `-3`, …). Test added |
| 4 | CaptureCoordinator.deliver | A failed save was silently ignored (`_ =`) | **Fixed.** Beep + NSLog. The clipboard copy is unaffected |
| 5 | CaptureCoordinator:34, ScreenCapture captureWindow | `NSScreen.screens[0]` traps when no display is attached (for example clamshell with no screens) | **Fixed.** guard → `CaptureError.noDisplays` |
| 6 | CaptureCoordinator overlay `onStyles: saveStyles` | The method reference captured `self` strongly: a coordinator→overlay→closure cycle while the overlay is open | **Fixed.** `{ [weak self] in self?.saveStyles($0) }` |
| 7 | ToolbarView:56 `NSImage(systemSymbolName:)!` | Force unwrap | **Fixed.** `?? NSImage()` |
| 8 | ToolbarView:97 `editor.doc.selected!` | Force unwrap after a check | **Fixed.** Optional binding |
| 9 | Imaging:7 `CGColorSpace(name: .sRGB)!` | Force unwrap | **Fixed.** `?? CGColorSpaceCreateDeviceRGB()` |
| 10 | Export:65 `urls(for: .picturesDirectory)[0]` | Index on a possibly empty array | **Fixed.** `.first ?? ~/Pictures` |
| 11 | App.swift:46 `statusItem: NSStatusItem!` | IUO | Accepted. It is assigned on the first line of `applicationDidFinishLaunching`, before any use |
| 12 | EditorView:75, ToolbarView:79 `fatalError` | Inside `@available(*, unavailable) init?(coder:)` | Accepted. Unreachable |
| 13 | Annotation:125 `points[0]` | Guarded by `points.count == 1` | Accepted |
| 14 | Settings.swift:33 `try!` | Match inside a comment | False positive |
| 15 | Fuzz/*.swift `fatalError` | These are the invariant traps the fuzzers rely on | Intended |
| 16 | `ToolbarView unowned let editor` | The editor owns the toolbar, so it outlives it | Accepted |
| 17 | cyclomatic complexity / length (Renderer draw, EditorView mouse/key handlers, CaptureCoordinator.run) | Flat `switch` dispatch over kinds and keys | Accepted |

semgrep reported one parse error, at Annotation.swift:127 (`case .rectangle, .ellipse where …`). That is a limitation of semgrep's Swift parser: the file compiles, and SwiftLint and swiftc both cover it.
Rules: `reviews/semgrep-swift.yml`.
