> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# Validation review (CTO)
**Date:** 2026-11-03 · **Reviewer:** CTO · **Scope:** static review of `App/Sources/*.swift`, `project.yml`, `Base.xcconfig`, `Local.xcconfig.example`, and the `ShareXCore` capture types, checked against `plans/cto.md`. I compiled nothing: the box is Linux and has no macOS SDK. Prior reviews (macos-developer r1/r2, fixes r1/r2) were cross-checked against the code itself, not their own reports.

## Verdict: **needs fixes** (no confirmed ship-blocker; one likely compile error, one runtime hang)
The architecture matches the plan: ScreenCaptureKit only, macOS 14, freeze-frame per-screen overlays, KeyboardShortcuts (Carbon), PNG+TIFF on the pasteboard, and Developer ID with Hardened Runtime. What remains is a small set of compile and runtime risks that only a Mac build can settle. Do the first Xcode build before anything else.

## Findings

### 1. ScreenCaptureKit
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| **high** | `ScreenCapture.windows()`, `CGRect(dictionaryRepresentation: b)` with `b` cast `as? NSDictionary` | `CGRect(dictionaryRepresentation:)` takes a `CFDictionary`. I don't believe Swift converts NSDictionary to CFDictionary implicitly here (UNVERIFIED). The usual pattern is `as! CFDictionary` or `b as CFDictionary`. Fix: `let r = CGRect(dictionaryRepresentation: b as CFDictionary)`. | compile (likely) |
| low | `freeze` | `SCContentFilter(display:excludingApplications:ours, exceptingWindows:[])` plus `width/height = display.width/height × backingScaleFactor` plus `captureResolution = .best`. This follows the plan (§3, §6) and the known pattern. Our overlays are not on screen at freeze time, so excluding them is defense in depth. OK. | — |
| low | `freeze` | Displays are frozen one after another. With N displays the frames are tens of ms apart. Accepted (N3). | runtime |
| medium | `captureWindow` | `desktopIndependentWindow`, `pointPixelScale`, `ignoreShadowsSingleWindow = true`, and output sized `frame × scale` match the plan's intent. The real system shadow is replaced by the synthetic one, which diverges from §10 ("keep the system shadow"), but this is a reasonable interim step until shadow sizing is measured on a Mac (N-R2-1). | runtime, UNVERIFIED |
| low | `captureWindow` | `shareableContent()` uses `onScreenWindowsOnly: true`, so a window that gets minimised between pick and capture returns `.windowGone`, which shows an alert. Correct. | — |
| note | `freeze`, `captureWindow` | Non-Sendable `SCContentFilter` and `SCStreamConfiguration` are passed from MainActor into the nonisolated async `captureImage`. `@preconcurrency import ScreenCaptureKit` should downgrade the diagnostic to a warning. Confirm on the first build. | compile, UNVERIFIED |
| note | Retina / multi-display | `stitch` upsamples 1x displays to the maximum scale. That is acceptable, and test case §13 (mixed DPI) applies. | runtime |

### 2. Screen Recording permission
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| medium | `Permissions.requestScreenRecording` / `CaptureCoordinator.run` | The gate is `CGPreflight… || CGRequest…`. Preflight can stay `false` after the user grants access until the app relaunches, and the alert offers "Quit & Reopen", which matches plan §4. The reverse case exists too on Sequoia: preflight can be `true` while SCK refuses. `mapped()` turns `userDeclined` into the same alert, which is good. | runtime |
| low | `Permissions.showDeniedAlert` | The alert is modal (`runModal`), while the plan calls for a non-modal panel and a menu-bar warning badge. The badge is not implemented. This is a UX gap, not a fault. | — |
| low | `Permissions.relaunch` | `/bin/sh -c "sleep 1; open …"` followed by `terminate` works. A cleaner option is `NSWorkspace.openApplication(at:configuration:)` with `createsNewApplicationInstance = true`. | runtime |
| note | `openSettings` | The `Privacy_ScreenCapture` deep link is still UNVERIFIED on macOS 26 (plan §4). Test it. | runtime |

### 3. Overlays across screens and Spaces
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| **high** | `OverlayController.init(canvas:)` `guard … else { return }`; `init(frozen:)` when every display is skipped | If context or image creation fails (for example a very large multi-display canvas), the controller has no surfaces. `show()` then displays nothing, and because `completion` never fires, `CaptureCoordinator.busy` stays `true`. **Every hotkey is then dead until relaunch.** Fix: make the inits failable (`init?`) or check `surfaces.isEmpty` in `show()` and call `close(.cancelled)`. | runtime |
| low | `init(frozen:)` | `.borderless`, `level = .screenSaver`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `hidesOnDeactivate = false`, and `canBecomeKey/Main = true` all match plan §6. `isOpaque = true` is fine because the view paints the frozen frame. `sharingType = .none` is not set, which is acceptable under freeze-frame (N6). | — |
| low | `show()` | The key window is chosen as the screen under the mouse, and `NSApp.activate()` is asynchronous, so the first keystroke can still go to the previous app. Accepted. | runtime |
| note | `init(canvas:)` | The canvas window uses `.floating` with `[.moveToActiveSpace, .fullScreenAuxiliary]`, a valid combination. `windowWillClose` re-entry is prevented because `close()` sets `delegate = nil` first. OK. | — |

### 4. KeyboardShortcuts
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| medium | `Hotkeys.register`: `KeyboardShortcuts.onKeyUp(for:) { Task { @MainActor in capture(style) } }` | `capture` is a non-Sendable `@MainActor` closure captured into a `Task`. Under Swift 6 with complete checking, this can produce "capture of non-Sendable" or "sending risks data race", depending on whether the KS `onKeyUp` action is `@MainActor` in the resolved version (UNVERIFIED). Fix: declare the parameter `@escaping @MainActor @Sendable (CaptureStyle) -> Void`. Also call it directly when KS already delivers on main: `MainActor.assumeIsolated { capture(style) }`. | compile, UNVERIFIED |
| medium | `project.yml` `KeyboardShortcuts from: 2.0.0`; `extension KeyboardShortcuts.Name { static let … }`, `Hotkeys.all` static tuple array | Swift 6 requires these static `let`s to be Sendable. Only newer 2.x releases mark `Name` as `Sendable` (UNVERIFIED which version). Pin a recent minimum (the latest 2.x) rather than `2.0.0`, so the resolver can't pick an old tag. | compile, UNVERIFIED |
| low | Hotkeys | Defaults are ⌃⇧1–5, which avoid ⌘⇧3/4/5, as the plan specifies. The **conflict warning** from plan §5 is not implemented. `KeyboardShortcuts.Recorder` in Settings gives rebinding with persistence. | — |

### 5. NSPasteboard
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| ok | `Export.copyToClipboard` | `clearContents()`, then one `NSPasteboardItem` with `.png` and `.tiff`, then `writeObjects([item])`. `rep.size` is set in points so the image pastes at 144 dpi on Retina. Runs on MainActor and synchronously. This exactly matches plan §7. | — |
| note | | The plan asks to check that `changeCount` increments. The code relies on the `writeObjects` result instead, which is adequate. Very large stitches mean a big TIFF, which the plan accepts. | — |

### 6. Swift 6 concurrency
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| medium | `Main.swift` file name + `@main enum Main` | `@main` is rejected in a file the compiler treats as `main.swift`. The file is `Main.swift` with a capital M. I believe the check is case-sensitive, so this should pass, but on a case-insensitive APFS volume I'm not certain (UNVERIFIED). Cheap fix: rename it to `ShareXApp.swift`. | compile, UNVERIFIED |
| low | `Imaging.colorSpace` static let (non-isolated enum) | A global `CGColorSpace` must be Sendable. Recent SDKs annotate CF types, but if this one isn't, you get an error under `complete`. Fallback: mark it `nonisolated(unsafe)`, or make `Imaging` `@MainActor`. | compile, UNVERIFIED |
| ok | `OverlayController.close` | `Task { @MainActor in … }` replaced `DispatchQueue.main.async`, so N-R2-5 is resolved. `CaptureCoordinator` keeps `Task { @MainActor }` with an implicit self, which is allowed for `Task`. `@MainActor` on `ScreenCapture`, `Export`, `Permissions` and `Countdown` is consistent. | — |
| note | `AppDelegate.captureItem` | `DispatchQueue.main.asyncAfter { [weak self] … }` touches MainActor state from a GCD closure. Swift 6 generally accepts the main queue as MainActor-isolated, but `Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); … }` is safer. | compile, UNVERIFIED |

### 7. XcodeGen and signing
| Sev | Evidence | Finding | Compile/runtime |
|---|---|---|---|
| medium | `Base.xcconfig` comment ("ad-hoc signed until then") + `CODE_SIGN_STYLE: Automatic` + `CODE_SIGN_IDENTITY: Apple Development` | Without `Local.xcconfig`, automatic signing with an Apple Development identity and no `DEVELOPMENT_TEAM` makes Xcode fail with a "requires a development team" error. It does not fall back to ad-hoc signing, so the comment is wrong. Either fix the comment and README, or have Base set `CODE_SIGN_IDENTITY = -` when there is no team. | build |
| low | `project.yml` Release config | Release uses `Apple Development`. Archive → Developer ID export re-signs the app, so this works, but set `CODE_SIGN_IDENTITY[config=Release] = Developer ID Application` to make plan §8 explicit. | build |
| ok | deployment target | macOS 14.0 is set in options, settings, `LSMinimumSystemVersion`, and `Package.swift .macOS(.v14)`, which is consistent. `LSUIElement` is set, Hardened Runtime is ON, there is no sandbox, and there are no entitlements, all matching plan §8. There is no screen-capture entitlement or usage string, which is correct. | — |
| note | `#include? "Local.xcconfig"` | The optional include is valid xcconfig syntax. A stable bundle ID, `com.sharexmac.ShareX`, keeps the TCC grant across builds. | — |

## Fix checklist (priority order)
1. **[high, runtime]** Never leave `busy` stuck: if the `OverlayController` has no surfaces, `show()` must call `close(.cancelled)`, or the inits must be failable.
2. **[high, compile]** `CGRect(dictionaryRepresentation: b as CFDictionary)` in `ScreenCapture.windows()`.
3. **[medium, compile]** Make the `Hotkeys.register` closure `@MainActor @Sendable`, and pin KeyboardShortcuts to a recent 2.x minimum.
4. **[medium, build]** Fix the signing story when no `Local.xcconfig` exists (ad-hoc fallback, or correct the docs).
5. **[medium, compile]** Rename `Main.swift` to `ShareXApp.swift` (cheap insurance).
6. **[low]** `Imaging.colorSpace` isolation, plus the `asyncAfter` to `Task` change in `captureItem`.
7. **[low, plan gaps]** Hotkey conflict warning, menu-bar denied badge, non-modal denied panel, and Release Developer ID identity.
8. **[Mac test]** On the device, test system shadow sizing (N-R2-1), the deep link on macOS 26, and mixed-DPI stitch dimensions.

## Alignment with cto.md: **~85%**
- **Matches:** ScreenCaptureKit only, with no CGWindowListCreateImage; macOS 14 floor; freeze-frame per-screen overlays at the plan's level and collection behaviour; `desktopIndependentWindow` for window mode; CGWindowList used for metadata only; KeyboardShortcuts with the plan's defaults; PNG+TIFF on one pasteboard item with Retina DPI; TCC preflight/request, deep link, and Quit & Reopen; Hardened Runtime, Developer ID, no sandbox, no entitlements; delay HUD closed before the freeze.
- **Diverges:** synthetic shadow instead of the system shadow for windows (deliberate, pending measurement); modal denied alert with no menu badge; no hotkey-conflict warning; cross-display region not supported (documented as deferred, as the plan allows for M1); the editor is in scope even though the plan marked it optional.
