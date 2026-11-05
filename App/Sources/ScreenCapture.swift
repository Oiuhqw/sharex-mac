import AppKit
@preconcurrency import ScreenCaptureKit

/// One display frozen at full pixel resolution.
struct FrozenScreen {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    let frame: CGRect
    let scale: CGFloat
    init(screen: NSScreen, displayID: CGDirectDisplayID, image: CGImage) {
        self.screen = screen; self.displayID = displayID; self.image = image
        frame = screen.frame; scale = screen.backingScaleFactor
    }
}

/// An on-screen window from the window server, in Cocoa global points.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let title: String
}

/// A single window captured live (not cropped from a display), so covered parts are included.
struct WindowShot {
    let image: CGImage
    let scale: CGFloat
    /// The screen the window is mostly on; the editor opens there.
    let screen: NSScreen
}

enum CaptureError: LocalizedError {
    case noDisplays, noPermission, windowGone, imageTooLarge, captureFailed(String)
    var errorDescription: String? {
        switch self {
        case .noDisplays: "No displays found."
        case .noPermission: "Screen Recording permission is off."
        case .windowGone: "The window closed before it could be captured."
        case .imageTooLarge: "This capture exceeds the 64 megapixel image limit. Select a smaller area or fewer displays."
        case .captureFailed(let m): "Capture failed: \(m)"
        }
    }
}

/// ScreenCaptureKit only (no CGWindowListCreateImage). Region, freehand and monitor styles crop frozen
/// displays; window styles capture the window itself with a desktop-independent filter.
@MainActor
enum ScreenCapture {
#if SHAREX_E2E
    /// E2E seam, set only by `--e2e` when Screen Recording cannot be granted: a synthetic frame of the given pixel size.
    static var e2eFixture: ((Int, Int) -> CGImage?)?
    /// E2E seam: synthetic display frames only (window captures stay real ScreenCaptureKit).
    static var e2eDisplayFixture: ((Int, Int) -> CGImage?)?
    /// E2E seam: the next window capture fails as if the window closed, to drive the error-alert path.
    static var e2eForceWindowGone = false
    static var e2eCapturePixelLimit: Int?
    static var e2eFrozenResult: (@MainActor ([FrozenScreen]) async -> [FrozenScreen])?
    #else
    // Shipped builds: the seams are constant nil/false, so the compiler drops every test branch.
    static let e2eFixture: ((Int, Int) -> CGImage?)? = nil
    static let e2eDisplayFixture: ((Int, Int) -> CGImage?)? = nil
    static let e2eForceWindowGone = false
    #endif

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Only the TCC refusal means "no permission"; anything else is a real failure worth reporting as such.
    private static func mapped(_ error: Error) -> CaptureError {
        if let e = error as? CaptureError { return e }
        if let e = error as? SCStreamError, e.code == .userDeclined { return .noPermission }
        return .captureFailed(error.localizedDescription)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw mapped(error) }
    }

    /// Display/app lists change rarely; fetching SCShareableContent costs tens of ms per capture. It is prefetched
    /// at launch, refreshed after each capture and dropped on display changes. Window captures always fetch fresh.
    private static var cached: (content: SCShareableContent, at: Double)?
    private static var observing = false
    /// Bumped on every screen change; a fetch that started under an older generation is discarded.
    private static var generation = 0
    static func prefetch() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cached = nil; generation += 1 }
            }
        }
        guard e2eFixture == nil, CGPreflightScreenCaptureAccess() else { return }
        let gen = generation
        Task { @MainActor in
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true), gen == generation {
                cached = (c, Perf.now())
            }
        }
    }
    private static func displayContent(for ids: [CGDirectDisplayID]) async throws -> SCShareableContent {
        if let c = cached, Perf.now() - c.at < 60_000,
           ids.allSatisfy({ id in c.content.displays.contains { $0.displayID == id } }) { return c.content }
        let gen = generation
        let c = try await shareableContent()
        if gen == generation { cached = (c, Perf.now()) }
        return c
    }

    private static func baseConfig(showCursor: Bool) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.showsCursor = showCursor
        c.captureResolution = .best
        // Our contexts and the PNG are sRGB; ask SCK for sRGB so nothing shifts colour.
        c.colorSpaceName = CGColorSpace.sRGB
        return c
    }

    /// Freezes the given screens. Our own windows are excluded from the frame.
    static func freeze(_ screens: [NSScreen], showCursor: Bool) async throws -> [FrozenScreen] {
        #if SHAREX_E2E
        let maximumPixels = min(Imaging.maximumPixels, e2eCapturePixelLimit ?? Imaging.maximumPixels)
        #else
        let maximumPixels = Imaging.maximumPixels
        #endif
        var plannedBytes = 0
        for screen in screens {
            guard let dimensions = Imaging.pixelDimensions(size: screen.frame.size, scale: screen.backingScaleFactor),
                  let bytes = Imaging.allocationBytes(width: dimensions.width, height: dimensions.height),
                  bytes <= maximumPixels * 4 - plannedBytes else { throw CaptureError.imageTooLarge }
            plannedBytes += bytes
        }
        if let fx = e2eFixture ?? e2eDisplayFixture {
            var out: [FrozenScreen] = [], retained = 0
            for screen in screens {
                guard let dimensions = Imaging.pixelDimensions(size: screen.frame.size, scale: screen.backingScaleFactor),
                      let image = fx(dimensions.width, dimensions.height) else { throw CaptureError.captureFailed("The display image is unavailable.") }
                try admit(image, retained: &retained)
                out.append(FrozenScreen(screen: screen, displayID: displayID(of: screen), image: image))
            }
            if out.isEmpty { throw CaptureError.noDisplays }
            #if SHAREX_E2E
            if let e2eFrozenResult { return await e2eFrozenResult(out) }
            #endif
            return out
        }
        let sp = Perf.signposter.beginInterval("shareable-content")
        let content = try await displayContent(for: screens.map(displayID(of:)))
        Perf.signposter.endInterval("shareable-content", sp)
        defer { prefetch() }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var out: [FrozenScreen] = [], retained = 0
        for screen in screens {
            let id = displayID(of: screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            let config = baseConfig(showCursor: showCursor)
            let scale = screen.backingScaleFactor
            guard let dimensions = Imaging.pixelDimensions(size: CGSize(width: display.width, height: display.height), scale: scale),
                  let bytes = Imaging.allocationBytes(width: dimensions.width, height: dimensions.height),
                  bytes <= maximumPixels * 4 - retained else { throw CaptureError.imageTooLarge }
            config.width = dimensions.width
            config.height = dimensions.height
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try admit(image, retained: &retained)
                out.append(FrozenScreen(screen: screen, displayID: id, image: image))
            } catch { throw mapped(error) }
        }
        if out.isEmpty { throw CaptureError.noDisplays }
        return out
    }

    /// Captures one window by itself, including parts other windows cover, at exactly its frame in pixels.
    /// The system shadow is always dropped: how SCK sizes a kept shadow is unverified, so the app draws its own
    /// shadow (DecorationLayout) and the border wraps the window, not shadow padding. No cursor, as in ShareX.
    static func captureWindow(_ info: WindowInfo) async throws -> WindowShot {
        if e2eForceWindowGone {
            #if SHAREX_E2E
            e2eForceWindowGone = false
            #endif
            throw CaptureError.windowGone }
        if let fx = e2eFixture, let s = NSScreen.screens.first {
            let sc = s.backingScaleFactor
            guard let dimensions = Imaging.pixelDimensions(size: info.frame.size, scale: sc) else { throw CaptureError.imageTooLarge }
            guard let img = fx(dimensions.width, dimensions.height) else { throw CaptureError.noDisplays }
            var retained = 0
            try admit(img, retained: &retained)
            return WindowShot(image: img, scale: sc, screen: s)
        }
        let content = try await shareableContent()
        guard let w = content.windows.first(where: { $0.windowID == info.id }) else { throw CaptureError.windowGone }
        guard let screen = NSScreen.screens.max(by: { overlap($0.frame, info.frame) < overlap($1.frame, info.frame) })
        else { throw CaptureError.noDisplays }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = baseConfig(showCursor: false)
        config.ignoreShadowsSingleWindow = true
        // pointPixelScale is the window's backing scale; the frame size × scale gives exact pixels, no resampling.
        let scale = CGFloat(filter.pointPixelScale)
        guard let dimensions = Imaging.pixelDimensions(size: w.frame.size, scale: scale) else { throw CaptureError.imageTooLarge }
        config.width = dimensions.width
        config.height = dimensions.height
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            var retained = 0
            try admit(image, retained: &retained)
            return WindowShot(image: image, scale: scale, screen: screen)
        } catch { throw mapped(error) }
    }

    private static func admit(_ image: CGImage, retained: inout Int) throws {
        guard Imaging.accepts(image), let bytes = Imaging.retainedBytes(of: image),
              bytes <= Imaging.maximumPixels * 4 - retained else { throw CaptureError.imageTooLarge }
        retained += bytes
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Visible normal-layer on-screen windows front to back, excluding ours. Cocoa global coordinates.
    static func windows() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,   // invisible windows are not pickable
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let num = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 8, r.height > 8 else { return nil }
            // Window server bounds are top-left of the primary display; flip to Cocoa global.
            let cocoa = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            return WindowInfo(id: num, pid: pid, frame: cocoa, title: w[kCGWindowName as String] as? String ?? "")
        }
    }

    /// The frontmost window of the frontmost app.
    static func activeWindow() -> WindowInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return windows().first { $0.pid == pid }
    }
}
