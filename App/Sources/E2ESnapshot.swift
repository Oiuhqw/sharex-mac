#if SHAREX_E2E
import AppKit
@preconcurrency import ScreenCaptureKit
import ShareXCore

extension E2E {
    static func bindFailures(_ renderer: Renderer, committed: AnnotationsView? = nil, live: LiveMarkView) {
        renderer.redactionFailuresChanged = { [weak live] in live?.showFailedMasks($0) }
        renderer.redactionFailuresNeedDisplay = { [weak committed] rect in
            committed?.setNeedsDisplay(rect.integral)
            DispatchQueue.main.async { [weak committed] in committed?.setNeedsDisplay(rect.integral) }
        }
    }

    @discardableResult
    static func snapshotNativeView(_ view: NSView?, name: String) -> Bool {
        guard let view, let window = view.window, window.isVisible else {
            record(name, false, ["error": "native view is not visible"]); return false
        }
        guard !E2EEditing.views(view).contains(where: { $0 is FrameView }) else {
            record(name, false, ["error": "capture the editor window without redrawing its frozen frame"]); return false
        }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            record(name, false, ["error": "no native view bitmap"]); return false
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                record(name, false, ["error": "PNG encoding failed"]); return false
            }
            try png.write(to: out.appendingPathComponent("\(name).png"))
            let valid = bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0
            record(name, valid, ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "source": "AppKit cacheDisplay"])
            return valid
        } catch {
            record(name, false, ["error": error.localizedDescription]); return false
        }
    }

    static func windowImage(_ window: NSWindow) async throws -> CGImage {
        let sharing = window.sharingType
        window.sharingType = .readOnly
        defer { window.sharingType = sharing }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        await wait(40)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard window.isVisible, let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "E2EWindowSnapshot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "visible window is absent from ScreenCaptureKit"])
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
    }

    @discardableResult
    static func snapshotNativeWindow(_ window: NSWindow, name: String) async -> Bitmap? {
        do {
            let image = try await windowImage(window)
            E2EOrientation.writePNG(image, "\(name).png")
            let pixels = bitmap(image)
            let valid = pixels.w == Int(window.frame.width * window.backingScaleFactor)
                && pixels.h == Int(window.frame.height * window.backingScaleFactor)
            record(name, valid, ["width": pixels.w, "height": pixels.h, "source": "ScreenCaptureKit window capture"])
            return valid ? pixels : nil
        } catch {
            record(name, false, ["error": error.localizedDescription, "source": "ScreenCaptureKit window capture"])
            return nil
        }
    }

    static func snapshotImageLayers(_ root: NSView, scale: CGFloat, name: String? = nil, display: Bool = true,
                                    includeChrome: Bool = false) -> Bitmap? {
        if display { root.window?.displayIfNeeded() }
        CATransaction.flush()
        let size = root.bounds.size
        guard let ctx = Imaging.context(width: Int(size.width * scale), height: Int(size.height * scale), flipped: true) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Layer delegates normally draw into separate backing bitmaps. Isolate siblings here so
        // a transparent view's clear cannot erase the previous layer.
        for child in root.subviews where !child.isHidden {
            guard child is FrameView || child is AnnotationsView || child is LiveMarkView || (includeChrome && child is ChromeView) else { continue }
            guard let layer = child.layer,
                  let isolated = Imaging.context(width: ctx.width, height: ctx.height, flipped: true) else { return nil }
            if child is FrameView, layer.magnificationFilter == .nearest, layer.minificationFilter == .nearest {
                isolated.interpolationQuality = .none
            }
            isolated.scaleBy(x: scale, y: scale)
            isolated.translateBy(x: child.frame.minX - root.bounds.minX - child.bounds.minX,
                                 y: child.frame.minY - root.bounds.minY - child.bounds.minY)
            layer.render(in: isolated)
            guard let image = isolated.makeImage() else { return nil }
            Imaging.drawUpright(image, in: CGRect(origin: .zero, size: size), ctx: ctx)
        }
        guard let image = ctx.makeImage() else { return nil }
        if let name { E2EOrientation.writePNG(image, name) }
        return bitmap(image)
    }
}
#endif
