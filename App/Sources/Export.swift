import AppKit
import ImageIO
import ShareXCore
import UniformTypeIdentifiers
import os

enum Log {
    static let export = Logger(subsystem: "com.sharexmac.ShareX", category: "export")
    static let capture = Logger(subsystem: "com.sharexmac.ShareX", category: "capture")
}

/// Flattens frame + annotations into the final image, decorates it, and writes the outputs.
@MainActor
enum Export {
    #if SHAREX_E2E
    static var e2eRejectClipboard = false
    static var e2eRejectFile = false
    #endif
    /// Renders the crop area at full frame resolution. `lasso` (frame points) makes outside pixels transparent.
    static func flatten(renderer: Renderer, doc: EditorDocument, crop: CGRect, lasso: [CGPoint]?) -> CGImage? {
        let s = renderer.scale
        guard let area = renderer.pixelArea(crop),
              let ctx = Imaging.context(width: area.w, height: area.h, flipped: true) else { return nil }
        ctx.translateBy(x: -CGFloat(area.x), y: -CGFloat(area.y))
        ctx.scaleBy(x: s, y: s)
        if let lasso, lasso.count >= 3 {
            ctx.beginPath(); ctx.addLines(between: lasso); ctx.closePath(); ctx.clip()
        }
        renderer.drawFrame(ctx, in: area.points(scale: s))
        renderer.draw(doc, in: ctx)
        return ctx.makeImage()
    }

    /// Adds the border and drop shadow from the capture options (ShareX "image effects" subset).
    static func decorate(_ image: CGImage, options: CaptureOptions, scale: CGFloat) -> CGImage? {
        decorateOffMain(image, options: options, scale: scale)
    }
    /// Pure CoreGraphics on a private context: safe off the main thread.
    nonisolated static func decorateOffMain(_ image: CGImage, options: CaptureOptions, scale: CGFloat) -> CGImage? {
        guard Imaging.accepts(image), scale.isFinite, scale > 0, scale <= CGFloat(Imaging.maximumPixels) else { return nil }
        let o = options.sanitized()   // never trust a width that could overflow the pixel maths
        let scaledBorder = (CGFloat(o.borderWidth) * scale).rounded()
        guard scaledBorder <= CGFloat(Imaging.maximumPixels) else { return nil }
        let border = Int(scaledBorder)
        guard border > 0 || o.shadow else { return image }
        let L = DecorationLayout(imageSize: CGSize(width: image.width, height: image.height), border: border, shadow: o.shadow, scale: scale)
        guard let dimensions = Imaging.pixelDimensions(size: L.canvas, scale: 1),
              let ctx = Imaging.context(width: dimensions.width, height: dimensions.height, flipped: true) else { return nil }
        let framed = L.image.insetBy(dx: -CGFloat(border), dy: -CGFloat(border))
        if o.shadow {
            ctx.saveGState()
            // Shadow offset is in base (y-up) space, so a negative y drops it downwards on screen.
            ctx.setShadow(offset: CGSize(width: 0, height: -L.shadowOffset), blur: L.shadowBlur,
                          color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(framed)
            ctx.restoreGState()
        }
        if border > 0 { ctx.setFillColor(Imaging.cgColor(o.borderColor)); ctx.fill(framed) }
        ctx.clear(L.image)
        Imaging.drawUpright(image, in: L.image, ctx: ctx)
        return ctx.makeImage()
    }

    /// PNG + TIFF bytes with the real DPI (72 × scale), so a Retina capture pastes and opens at on-screen size.
    /// ImageIO only (thread-safe), so this runs off the main thread.
    struct Encoded: Sendable { let png: Data; let tiff: Data }
    nonisolated static func encode(_ image: CGImage?, scale: CGFloat) -> Encoded? {
        guard let image, Imaging.accepts(image), scale.isFinite, scale > 0, scale <= CGFloat(Imaging.maximumPixels) else { return nil }
        let dpi = 72 * scale
        let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        func bytes(_ type: UTType) -> Data? {
            let d = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(d as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, props)
            return CGImageDestinationFinalize(dest) ? d as Data : nil
        }
        guard let png = bytes(.png), let tiff = bytes(.tiff) else { return nil }
        return Encoded(png: png, tiff: tiff)
    }

    /// Encodes on a background thread so the main thread (and the closing overlay) never waits on PNG compression.
    static func encodeOffMain(_ image: CGImage, scale: CGFloat) async -> Encoded? {
        let box = ImageBox(image: image)
        return await Task.detached(priority: .userInitiated) { encode(box.image, scale: scale) }.value
    }

    /// Clears the pasteboard and writes one item carrying PNG and TIFF. Returns false if nothing was written.
    @discardableResult
    static func write(_ e: Encoded) -> Bool {
        #if SHAREX_E2E
        if e2eRejectClipboard { return false }
        #endif
        let item = NSPasteboardItem()
        guard item.setData(e.png, forType: .png), item.setData(e.tiff, forType: .tiff) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([item])
    }

    @discardableResult
    static func copyToClipboard(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let e = encode(image, scale: scale) else { return false }
        return write(e)
    }

    /// Saves already-encoded PNG bytes (the same bytes as the clipboard) off the main thread.
    static func savePNGData(_ png: Data, folder: String) async -> URL? {
        #if SHAREX_E2E
        if e2eRejectFile { return nil }
        #endif
        return await Task.detached(priority: .utility) { writePNG(png, folder: folder) }.value
    }

    /// Only used after NSSavePanel has confirmed the destination (including any replacement).
    static func savePNGData(_ png: Data, to url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            do { try png.write(to: url, options: .atomic); return true }
            catch { Log.export.error("PNG save failed: \(error.localizedDescription, privacy: .public)"); return false }
        }.value
    }

    /// Writes the PNG with its real DPI (72 × scale) so a Retina capture opens at on-screen size.
    static func savePNG(_ image: CGImage, scale: CGFloat, folder: String) -> URL? {
        encode(image, scale: scale).flatMap { writePNG($0.png, folder: folder) }
    }

    /// The save folder as a real directory: tilde expanded, symlinks resolved, created if missing (only then),
    /// and rejected if the resolved path is not a directory. Nil means "don't save".
    nonisolated static func resolveFolder(_ folder: String, create: Bool = true) -> URL? {
        let fm = FileManager.default
        let raw = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (raw as NSString).expandingTildeInPath
        // URL(fileURLWithPath:) makes relative paths absolute; validate the input before constructing it.
        guard raw.isEmpty || expanded.hasPrefix("/") else { return nil }
        let base = raw.isEmpty
            ? (fm.urls(for: .picturesDirectory, in: .userDomainMask).first
               ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")).appendingPathComponent("ShareX")
            : URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: base.path) {
            if !create { return base }   // Settings preview: it will be created on first save
            do { try fm.createDirectory(at: base, withIntermediateDirectories: true) } catch { return nil }
        }
        let dir = base.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir.path) else { return nil }
        return dir
    }

    /// Exclusive create (O_CREAT|O_EXCL via .withoutOverwriting): never replaces or follows an existing file;
    /// a name taken between the check and the write gets the next free name.
    nonisolated static func writePNG(_ png: Data, folder: String) -> URL? {
        guard let dir = resolveFolder(folder) else {
            Log.export.error("save folder rejected: \(folder, privacy: .private)"); return nil
        }
        for _ in 0..<5 {
            let name = AppSettings.uniqueFileName(for: Date()) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            let url = dir.appendingPathComponent(name)
            do { try png.write(to: url, options: .withoutOverwriting); return url }
            catch CocoaError.fileWriteFileExists { continue }
            catch { Log.export.error("save failed at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"); return nil }
        }
        return nil
    }
}

/// CGImage is immutable; this only carries it across the detached-task boundary.
struct ImageBox: @unchecked Sendable { let image: CGImage }
