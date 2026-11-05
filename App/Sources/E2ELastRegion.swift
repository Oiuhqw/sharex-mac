#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ELastRegion {
    private static let crop = CGRect(x: 137, y: 113, width: 96, height: 64)

    private static func layout() -> DesktopLayout? {
        DesktopLayout(displays: NSScreen.screens.map {
            .init(id: ScreenCapture.displayID(of: $0), frame: $0.frame, scale: $0.backingScaleFactor)
        })
    }

    private static func expected(on screen: NSScreen) -> E2E.Bitmap? {
        let scale = screen.backingScaleFactor
        guard let image = E2E.checker(Int(screen.frame.width * scale), Int(screen.frame.height * scale)),
              let region = image.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                                    width: crop.width * scale, height: crop.height * scale)) else { return nil }
        return E2E.bitmap(region)
    }

    private static func configure(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return false }
        for (id, origin) in origins {
            guard CGConfigureDisplayOrigin(configuration, id, Int32(origin.x), Int32(origin.y)) == .success else {
                CGCancelDisplayConfiguration(configuration); return false
            }
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
    }

    private static func move(_ id: CGDirectDisplayID, to origin: CGPoint) async -> Bool {
        let old = NSScreen.screens.first { ScreenCapture.displayID(of: $0) == id }?.frame
        guard configure([id: origin]) else { return false }
        return await E2E.until {
            CGDisplayBounds(id).origin == origin
                && NSScreen.screens.first { ScreenCapture.displayID(of: $0) == id }?.frame != old
        }
    }

    private static var countdownVisible: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.contentView.map { root in
                E2EEditing.views(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Esc or click to cancel" }
            } == true
        }
    }

    private static func restored(_ origins: [CGDirectDisplayID: CGPoint], frames: [CGDirectDisplayID: CGRect]) async {
        let configured = configure(origins)
        let settled = await E2E.until {
            origins.allSatisfy { CGDisplayBounds($0.key).origin == $0.value }
                && frames.allSatisfy { id, frame in NSScreen.screens.contains { ScreenCapture.displayID(of: $0) == id && $0.frame == frame } }
        }
        E2E.record("lastregion-restore-native-layout", configured && settled)
    }

    static func run() async {
        let fixtures = NSScreen.screens.filter {
            let id = ScreenCapture.displayID(of: $0)
            return CGDisplayVendorNumber(id) == 505 && CGDisplayModelNumber(id) == 0x5358
        }.sorted { $0.backingScaleFactor < $1.backingScaleFactor }
        guard fixtures.count >= 2, let map = layout(), await E2E.until({ !E2E.coord.busy }) else {
            E2E.record("lastregion-native-fixtures", false); return
        }
        let settings = E2E.app.settings.value, alerts = E2E.suppressAlerts
        let anchor = fixtures[0], other = fixtures[1], id = ScreenCapture.displayID(of: anchor)
        let origins = Dictionary(uniqueKeysWithValues: fixtures.map { (ScreenCapture.displayID(of: $0), CGDisplayBounds(ScreenCapture.displayID(of: $0)).origin) })
        let frames = Dictionary(uniqueKeysWithValues: fixtures.map { (ScreenCapture.displayID(of: $0), $0.frame) })
        defer {
            ScreenCapture.e2eFixture = nil; ScreenCapture.e2eCapturePixelLimit = nil; ScreenCapture.e2eFrozenResult = nil
            E2E.suppressAlerts = alerts; E2E.setOpts { $0 = settings }
            _ = configure(origins)
        }
        ScreenCapture.e2eFixture = E2E.checker; E2E.suppressAlerts = true
        E2E.setOpts {
            $0.options.delaySeconds = 0; $0.options.borderWidth = 0; $0.options.shadow = false
            $0.options.showCursor = false; $0.options.openEditor = false; $0.playSound = false; $0.saveToFile = false
        }
        guard let display = map.displays.first(where: { $0.id == id }), let expected = expected(on: anchor),
              let modern = LastRegion(crop: crop.offsetBy(dx: map.placement(display).minX, dy: map.placement(display).minY), layout: map) else {
            E2E.record("lastregion-source-fixture", false); return
        }
        let legacy = LastRegion(displayID: id, rect: crop)
        await admission(legacy: legacy, modern: modern, anchor: anchor, expected: expected)
        await delayedOrigin(modern, anchor: anchor, other: other, expected: expected)
        await restored(origins, frames: frames)

        guard let current = layout() else { E2E.record("lastregion-restored-layout", false); return }
        let ids = Set(fixtures.map(ScreenCapture.displayID(of:)))
        let participating = current.displays.filter { ids.contains($0.id) }
        let combined = participating.map(current.placement).reduce(CGRect.null) { $0.union($1) }
        guard let crossDisplay = LastRegion(crop: combined, layout: current) else {
            E2E.record("lastregion-participant-fixture", false); return
        }
        await freshSelection("missing-frozen-participant", saved: crossDisplay) { Array($0.dropLast()) }
        await freshSelection("invalid-frozen-layout", saved: crossDisplay) { tiles in
            guard let first = tiles.first else { return [] }
            return [first, first]
        }
        let otherID = ScreenCapture.displayID(of: other)
        let shifted = CGPoint(x: origins[otherID]!.x - 127, y: origins[otherID]!.y - 83)
        var changed = false
        await freshSelection("changed-after-freeze", saved: crossDisplay) { tiles in
            changed = await move(otherID, to: shifted)
            return tiles
        }
        E2E.record("lastregion-participant-moved-after-freeze", changed)
        await restored(origins, frames: frames)
        await delayedParticipant(crossDisplay, displayID: otherID, origin: shifted)
        await restored(origins, frames: frames)
    }

    private static func admission(legacy: LastRegion, modern: LastRegion, anchor: NSScreen, expected: E2E.Bitmap) async {
        let pixels = Int(anchor.frame.width * anchor.backingScaleFactor) * Int(anchor.frame.height * anchor.backingScaleFactor)
        ScreenCapture.e2eCapturePixelLimit = pixels
        var rejectsAll = false
        do { _ = try await ScreenCapture.freeze(NSScreen.screens, showCursor: false) }
        catch CaptureError.imageTooLarge { rejectsAll = true }
        catch {}
        E2E.record("lastregion-admission-fixture-rejects-all-displays", rejectsAll, ["captureBudgetPixels": pixels])
        for (name, saved) in [("legacy", legacy), ("participants", modern)] {
            for editor in [false, true] {
                let tag = "lastregion-target-only-\(name)-\(editor ? "editor" : "direct")"
                var targets: [[CGDirectDisplayID]] = []
                ScreenCapture.e2eFrozenResult = { targets.append($0.map(\.displayID)); return $0 }
                E2E.setOpts { $0.lastRegion = saved; $0.options.openEditor = editor }
                let mark = E2E.markClipboard()
                E2E.coord.capture(.lastRegion)
                let ready = await E2E.until { !E2E.coord.busy || E2E.coord.overlay != nil }
                var selected = true
                if editor {
                    let surfaces = E2E.coord.overlay?.e2eSurfaces ?? []
                    selected = surfaces.count == 1 && surfaces.first?.view.doc.state.crop == crop
                        && surfaces.first?.view.phase == .editing
                    if let surface = surfaces.first { E2E.postClick(surface.view.e2eToolbar.e2eDone) }
                }
                let delivered = await E2E.until { !E2E.coord.busy }
                let image = NSPasteboard.general.data(forType: .png).flatMap(E2E.decode).map(E2E.bitmap)
                E2E.record(tag, rejectsAll && ready && selected && delivered && NSPasteboard.general.changeCount != mark.change
                           && image?.px == expected.px && targets == [[saved.displayID]],
                           ["captureBudgetPixels": pixels, "capturedDisplayIDs": targets, "expectedPixels": [expected.w, expected.h]])
                E2E.coord.overlay?.e2eSurfaces.first?.view.cancel()
                _ = await E2E.until { !E2E.coord.busy }
            }
        }
        ScreenCapture.e2eCapturePixelLimit = nil; ScreenCapture.e2eFrozenResult = nil
    }

    private static func delayedOrigin(_ saved: LastRegion, anchor: NSScreen, other: NSScreen, expected: E2E.Bitmap) async {
        let otherID = ScreenCapture.displayID(of: other)
        let oldCrop = layout().flatMap { saved.resolve(layout: $0) }
        let left = NSScreen.screens.map { CGDisplayBounds(ScreenCapture.displayID(of: $0)).minX }.min() ?? 0
        let origin = CGPoint(x: left - other.frame.width - 127, y: CGDisplayBounds(otherID).minY)
        E2E.setOpts { $0.lastRegion = saved; $0.options.delaySeconds = 3; $0.options.openEditor = false }
        let mark = E2E.markClipboard()
        E2E.coord.capture(.lastRegion)
        let counting = await E2E.until { countdownVisible }
        let moved = await move(otherID, to: origin)
        let duringDelay = countdownVisible
        let newCrop = layout().flatMap { saved.resolve(layout: $0) }
        let anchorUnchanged = NSScreen.screens.contains { ScreenCapture.displayID(of: $0) == saved.displayID && $0.frame == anchor.frame }
        let finished = await E2E.until(8000) { !E2E.coord.busy }
        let image = NSPasteboard.general.data(forType: .png).flatMap(E2E.decode).map(E2E.bitmap)
        E2E.record("lastregion-resolves-after-countdown-origin-change", counting && moved && duringDelay && anchorUnchanged
                   && oldCrop != nil && newCrop != nil && oldCrop != newCrop && finished
                   && NSPasteboard.general.changeCount != mark.change && image?.px == expected.px,
                   ["oldCrop": oldCrop.map(NSStringFromRect) ?? "missing", "newCrop": newCrop.map(NSStringFromRect) ?? "missing",
                    "anchorFrameUnchanged": anchorUnchanged])
        E2E.coord.overlay?.e2eSurfaces.first?.view.cancel()
        _ = await E2E.until { !E2E.coord.busy }
        E2E.setOpts { $0.options.delaySeconds = 0 }
    }

    private static func isFreshSelection(since mark: (change: Int, files: [String])) -> Bool {
        let surfaces = E2E.coord.overlay?.e2eSurfaces ?? []
        return surfaces.count == NSScreen.screens.count && !surfaces.isEmpty
            && surfaces.allSatisfy { $0.window.isVisible && $0.view.phase == .selecting(.rectangle) && $0.view.doc.state.crop == nil }
            && NSPasteboard.general.changeCount == mark.change && E2E.savedFiles() == mark.files
    }

    private static func freshSelection(_ name: String, saved: LastRegion,
                                       transform: @escaping @MainActor ([FrozenScreen]) async -> [FrozenScreen]) async {
        E2E.setOpts { $0.lastRegion = saved; $0.options.openEditor = false; $0.options.delaySeconds = 0 }
        var captures = 0
        ScreenCapture.e2eFrozenResult = { tiles in
            captures += 1
            if captures == 1 { return await transform(tiles) }
            return tiles
        }
        let mark = E2E.markClipboard()
        E2E.coord.capture(.lastRegion)
        let ready = await E2E.until(8000) { E2E.coord.overlay != nil || !E2E.coord.busy }
        E2E.record("lastregion-\(name)-selects-fresh-region", ready && captures == 2 && isFreshSelection(since: mark), ["captures": captures])
        E2E.coord.overlay?.e2eSurfaces.first?.view.cancel()
        _ = await E2E.until { !E2E.coord.busy }
        ScreenCapture.e2eFrozenResult = nil
    }

    private static func delayedParticipant(_ saved: LastRegion, displayID: CGDirectDisplayID, origin: CGPoint) async {
        E2E.setOpts { $0.lastRegion = saved; $0.options.delaySeconds = 3; $0.options.openEditor = false }
        let mark = E2E.markClipboard()
        E2E.coord.capture(.lastRegion)
        let counting = await E2E.until { countdownVisible }
        let moved = await move(displayID, to: origin)
        let duringDelay = countdownVisible
        let ready = await E2E.until(8000) { E2E.coord.overlay != nil || !E2E.coord.busy }
        E2E.record("lastregion-participant-changed-during-countdown-selects-fresh-region",
                   counting && moved && duringDelay && ready && isFreshSelection(since: mark))
        E2E.coord.overlay?.e2eSurfaces.first?.view.cancel()
        _ = await E2E.until { !E2E.coord.busy }
        E2E.setOpts { $0.options.delaySeconds = 0 }
    }
}
#endif
