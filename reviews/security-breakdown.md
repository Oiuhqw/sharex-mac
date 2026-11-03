# ShareX macOS: defensive hardening audit

Scope: read-only configuration and code-hygiene review of our own source (App/Sources, Packages/ShareXCore, .github/workflows, project.yml, Base.xcconfig). No source files were edited. Line numbers refer to the working tree reviewed (HEAD 7910f92 plus uncommitted edits, see the last section).

## Verdict: SIGN-WITH-CONDITIONS

The code is careful: no risky entitlements, the app's own windows are left out of captures, saves never overwrite existing files, and decoded settings are mostly clamped. Two things should be fixed before any public DMG. First, the shipped DMG is built with Hardened Runtime turned off and is ad-hoc signed, not notarized. Second, the `--e2e*` test hooks are compiled into Release builds and can be switched on from the command line. Neither is a remote risk, but both are gaps in the release posture we claim.

## Findings

| # | Sev | Area | file:line | Summary |
|---|-----|------|-----------|---------|
| F1 | High | Hardened Runtime / signing | .github/workflows/dmg.yml:21,27 | The DMG build passes `ENABLE_HARDENED_RUNTIME=NO`, then runs `codesign --force --deep --sign -` with no `--options runtime`. The shipped app has no Hardened Runtime, even though project.yml:44 enables it. |
| F2 | Medium | DMG distribution | dmg.yml:27, 39-47 | Ad-hoc signed and not notarized. The SHA-256 only goes to the job log and isn't published. |
| F3 | Medium | E2E hooks in Release | App/Sources/E2E.swift:12-20,97,102; App.swift:10,58; ScreenCapture.swift:45-47,132; CaptureCoordinator.swift:153; E2EPerf.swift | None of these are behind `#if DEBUG`. In Release, `--e2e <dir>` runs the self-test driver: it writes captures, results.json and the pasteboard PNGs to any chosen directory and can inject fixture frames. `--e2e-verify` and `--e2e-pattern` are also live. |
| F4 | Medium | CI supply chain | macos.yml:15,94,102,110; dmg.yml:8,48 | `actions/checkout@v4` and `actions/upload-artifact@v4` use tags, not SHAs. There are no `permissions:` blocks. `brew install xcodegen` is unpinned in both workflows. |
| F5 | Medium | SPM pinning | project.yml:10-12; .gitignore:1 | KeyboardShortcuts is pinned with `exactVersion: 2.3.0`, but no Package.resolved is committed (the .xcodeproj is git-ignored and regenerated). That means no revision hash is locked, so a moved tag would go unnoticed. UNVERIFIED whether anyone checks the resolved hash. |
| F6 | Low | Clipboard | App/Sources/Export.swift:75-82 | Captures go on the general pasteboard with no `org.nspasteboard.TransientType` or `ConcealedType`, so clipboard managers and Universal Clipboard keep every screenshot, including ones that show secrets. |
| F7 | Low | Save path | Export.swift:91-98, 101-104, 108-121 | Folder is taken as given (tilde-expanded). There's no standardize or resolve step, and a symlinked folder is followed. `savePNG` (CGImageDestination) doesn't use `.withoutOverwriting`, and its check-then-create on file existence can race. The filename is fixed (`ShareX_<date>.png`, Settings.swift:83-89), so it's safe to inject into. |
| F8 | Low | Settings decoding | Packages/ShareXCore/Sources/ShareXCore/Settings.swift:52-54 | `options` and `toolStyles` are clamped. `saveFolder` has no length or shape check, and `lastRegion` isn't validated on decode (it is clamped later in `resolve`, lines 16-19). Bad JSON safely falls back to defaults (lines 36-42). |
| F9 | Low | Logs | CaptureCoordinator.swift:158,176; E2E.swift:122,291,294; E2EPerf.swift:157 | `NSLog` prints the user's save-folder path and error text with no privacy markers. No image content is logged. |
| F10 | Low | Overlay sharingType | OverlayController.swift:67-72,109-114 | Overlay and editor windows keep the default `.readOnly` sharingType. Only the countdown HUD sets `.none` (Countdown.swift:20). Our own capture excludes our app through `SCContentFilter(excludingApplications: ours)` (ScreenCapture.swift:109,114), and window picking skips our PID (ScreenCapture.swift:166), but other recorders can still see the full-screen frozen overlay. |
| F11 | Info | Entitlements | (no .entitlements file in repo) | Disable-library-validation, allow-dyld-environment-variables, get-task-allow and allow-unsigned-executable-memory are all absent. Good. Debug builds under Xcode automatic signing get get-task-allow, which is expected. |
| F12 | Info | Temp files | E2EPerf.swift:134; E2E.swift:102 | Only the test hooks write temp files (`NSTemporaryDirectory()/perf`, default `/tmp/e2e`, which is world-readable). The production path writes no temp files. This becomes a non-issue once F3 is fixed. |
| F13 | Info | CI injection | workflows | No `pull_request_target`, no `${{ github.event.* }}` in `run:` steps, and no secrets are used. |

## Details and fixes

**F1 Hardened Runtime off in the shipped build.** dmg.yml:21 overrides the project setting, and the ad-hoc re-sign at line 27 has no `--options runtime`. So the DMG binary runs without library-validation and DYLD protections. That matters for an app that holds a Screen Recording grant.
*Fix:* Remove `ENABLE_HARDENED_RUNTIME=NO`. Sign with `codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" ShareX.app`, and stop using `--deep`: sign the nested pieces individually. Then check with `codesign -dv` that the flags read `runtime`.

**F2 Distribution posture.** Ad-hoc plus no notarization means Gatekeeper blocks the app and users learn to right-click > Open. The signature also changes on every build, so macOS drops the TCC grant each time (Local.xcconfig.example says the same).
*Fix:* Sign with a Developer ID Application identity, store the credentials as GitHub encrypted secrets inside a protected `release` environment, run `xcrun notarytool submit --wait` and `xcrun stapler staple` on the DMG, sign the DMG itself, and publish `ShareX.dmg.sha256` next to the release asset. Until that's in place, label builds "unsigned dev build".

**F3 Test hooks compiled into Release.** The `E2E` enum and its switches are evaluated from `CommandLine.arguments` in every configuration. Anyone who can launch the binary gets dumps of captured screens and pasteboard PNGs into a directory of their choice, plus fixture frame injection. These run under our TCC grant.
*Fix:* Wrap E2E.swift, E2EPerf.swift, the static seams (`e2eFixture`, `e2eDisplayFixture`, `e2eForceWindowGone`, `suppressAlerts`) and the call sites (App.swift:10,58; CaptureCoordinator.swift:153) in `#if DEBUG` or a custom `SHAREX_E2E` compilation condition that's set only for the test scheme. perf.sh runs Release, so give it a separate `ReleasePerf` configuration with the flag set and keep shipped Release clean. Add a CI check that `strings ShareX | grep -c -- --e2e` returns 0 on the DMG binary.

**F4 Actions pinning and permissions.** *Fix:* Pin to full commit SHAs with a `# v4.x.y` comment and let Dependabot (github-actions ecosystem) bump them. Add top-level `permissions: contents: read` to both workflows. Pin xcodegen with a SHA-checked release download or `mint`.

**F5 SPM lock.** *Fix:* Commit a Package.resolved, or switch to `revision: <sha>` in project.yml for KeyboardShortcuts, and fail CI if the resolved revision changes.

**F6 Clipboard.** *Fix:* Add `item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))` so clipboard managers skip the capture. Consider a "Don't sync screenshots to clipboard history" setting that adds `ConcealedType`. Don't mark captures ConcealedType by default, because users usually want to paste them. Optionally clear the pasteboard after N minutes if `changeCount` hasn't moved.

**F7 Save path.** *Fix:* Resolve the folder once with `standardizedFileURL.resolvingSymlinksInPath()`. Check it's an existing directory owned by the user, and reject paths that aren't absolute after tilde expansion. Use an NSOpenPanel picker instead of a free-text field (SettingsView.swift:49). Write through `.withoutOverwriting`, or through open(O_CREAT|O_EXCL|O_NOFOLLOW), and retry on EEXIST instead of check-then-write. Have `savePNG` encode to Data and reuse `savePNGData`.

**F8 Settings.** *Fix:* Cap `saveFolder` at PATH_MAX (1024) and strip control characters. Drop `lastRegion` on decode if it isn't finite or has non-positive size. Unknown enum keys in `toolStyles` already fail decode and fall back to defaults. (Fuzz harness: Fuzz/SettingsFuzzer.swift, FuzzTests.)

**F9 Logs.** *Fix:* Move to `os.Logger` with `\(path, privacy: .private)`, and keep the E2E logging inside the debug-only flag.

**F10 sharingType.** *Fix:* Set `w.sharingType = .none` on the full-screen overlay (OverlayController.swift:67). It shows a frozen copy of the user's screen, so other recorders and screen shares shouldn't get it. Leave the editor window `.readOnly` if users want to screen-share it, or make it a setting. UNVERIFIED: on macOS 15 ScreenCaptureKit may ignore `.none` for some capture paths. Check at runtime.

**F11 Minimal entitlements.** Keep the current state: no .entitlements file and the Hardened Runtime defaults. The app needs no exceptions. Screen Recording is a TCC grant, not an entitlement. Unsandboxed is acceptable, but if sandboxing is ever adopted the minimal set is `com.apple.security.app-sandbox` plus `files.user-selected.read-write` (with the F7 picker and a security-scoped bookmark) and `files.pictures.read-write`. UNVERIFIED: no built Release binary was inspected (`codesign -d --entitlements -`).

## UNVERIFIED
- The entitlements actually embedded in the built and DMG binaries. Nothing was built here.
- Whether KeyboardShortcuts 2.3.0 resolves to the expected commit (F5).
- How ScreenCaptureKit treats `sharingType = .none` on the target macOS versions (F10).
- Gatekeeper and TCC behaviour of the ad-hoc DMG on a clean machine (F2).

## Reviewed tree state and recheck
- Start: HEAD `7910f924ec6bb3eb0fe7072c6aa56d218716383e`. `git status` showed modified App/Sources/App.swift, CaptureCoordinator.swift, Export.swift, Hotkeys.swift and ScreenCapture.swift (the concurrent perf pass). 252-line diff snapshot taken.
- End: the concurrent pass did land edits during the review. `git status` now also lists modified EditorView.swift and Renderer.swift, plus a new untracked EditorLayers.swift. That diff turns the editor into layer-backed views (FrameView/AnnotationsView/ChromeView, `refresh()` in place of `draw(_:)`). I rechecked every cited line in App.swift, CaptureCoordinator.swift, Export.swift and ScreenCapture.swift and none had moved. EditorLayers.swift creates no windows and touches no pasteboard, files or logs. **No finding changed.** If later commits touch Export.swift (F6/F7) or the E2E seams (F3), recheck them.
