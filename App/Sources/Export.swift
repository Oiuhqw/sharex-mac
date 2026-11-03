import AppKit
import ImageIO
import ShareXCore
import UniformTypeIdentifiers

/// Flattens frame + annotations into the final image, decorates it, and writes the outputs.
@MainActor
enum Export {
    /// Renders the crop area at full frame resolution. `lasso` (frame points) makes outside pixels transparent.
    static func flatten(renderer: Renderer, doc: EditorDocument, crop: CGRect, lasso: [CGPoint]?) -> CGImage? {
        let s = renderer.scale
        guard let area = Geometry.pixelRect(crop, scale: s).clamped(width: renderer.frame.width, height: renderer.frame.height),
              let ctx = Imaging.context(width: area.w, height: area.h, flipped: true) else { return nil }
        ctx.translateBy(x: -CGFloat(area.x), y: -CGFloat(area.y))
        ctx.scaleBy(x: s, y: s)
        if let lasso, lasso.count >= 3 {
            ctx.beginPath(); ctx.addLines(between: lasso); ctx.closePath(); ctx.clip()
        }
        renderer.drawFrame(ctx)
        renderer.draw(doc, in: ctx)
        return ctx.makeImage()
    }

    /// Adds the border and drop shadow from the capture options (ShareX "image effects" subset).
    static func decorate(_ image: CGImage, options: CaptureOptions, scale: CGFloat) -> CGImage {
        let o = options.sanitized()   // never trust a width that could overflow the pixel maths
        let border = Int((CGFloat(o.borderWidth) * scale).rounded())
        guard border > 0 || o.shadow else { return image }
        let L = DecorationLayout(imageSize: CGSize(width: image.width, height: image.height), border: border, shadow: o.shadow, scale: scale)
        guard let ctx = Imaging.context(width: Int(L.canvas.width), height: Int(L.canvas.height), flipped: true) else { return image }
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
        return ctx.makeImage() ?? image
    }

    /// Clears the pasteboard and writes one item carrying PNG and TIFF. Returns false if nothing was written.
    @discardableResult
    static func copyToClipboard(_ image: CGImage, scale: CGFloat) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        // Point size = pixels / scale, so Retina captures paste at on-screen size (144 dpi at 2x).
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]), let tiff = rep.tiffRepresentation else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        return pb.writeObjects([item])
    }

    /// Writes the PNG with its real DPI (72 × scale) so a Retina capture opens at on-screen size.
    static func savePNG(_ image: CGImage, scale: CGFloat, folder: String) -> URL? {
        let dir = folder.isEmpty
            ? (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
               ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")).appendingPathComponent("ShareX")
            : URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = AppSettings.uniqueFileName(for: Date()) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}
