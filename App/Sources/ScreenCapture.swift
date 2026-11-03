import AppKit
@preconcurrency import ScreenCaptureKit

/// One display frozen at full pixel resolution.
struct FrozenScreen {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    var scale: CGFloat { screen.backingScaleFactor }
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
    case noDisplays, noPermission, windowGone, captureFailed(String)
    var errorDescription: String? {
        switch self {
        case .noDisplays: "No displays found."
        case .noPermission: "Screen Recording permission is off."
        case .windowGone: "The window closed before it could be captured."
        case .captureFailed(let m): "Capture failed: \(m)"
        }
    }
}

/// ScreenCaptureKit only (no CGWindowListCreateImage). Region, freehand and monitor styles crop frozen
/// displays; window styles capture the window itself with a desktop-independent filter.
@MainActor
enum ScreenCapture {
    /// E2E seam, set only by `--e2e` when Screen Recording cannot be granted: a synthetic frame of the given pixel size.
    static var e2eFixture: ((Int, Int) -> CGImage?)?

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Only the TCC refusal means "no permission"; anything else is a real failure worth reporting as such.
    private static func mapped(_ error: Error) -> CaptureError {
        if let e = error as? SCStreamError, e.code == .userDeclined { return .noPermission }
        return .captureFailed(error.localizedDescription)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw mapped(error) }
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
        if let fx = e2eFixture {
            return screens.compactMap { s in
                let sc = s.backingScaleFactor
                return fx(Int(s.frame.width * sc), Int(s.frame.height * sc)).map { FrozenScreen(screen: s, displayID: displayID(of: s), image: $0) }
            }
        }
        let content = try await shareableContent()
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var out: [FrozenScreen] = []
        for screen in screens {
            let id = displayID(of: screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            let config = baseConfig(showCursor: showCursor)
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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
        if let fx = e2eFixture, let s = NSScreen.screens.first {
            let sc = s.backingScaleFactor
            guard let img = fx(Int((info.frame.width * sc).rounded()), Int((info.frame.height * sc).rounded())) else { throw CaptureError.noDisplays }
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
        config.width = Int((w.frame.width * scale).rounded())
        config.height = Int((w.frame.height * scale).rounded())
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return WindowShot(image: image, scale: scale, screen: screen)
        } catch { throw mapped(error) }
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
