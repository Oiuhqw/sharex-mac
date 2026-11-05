import AppKit
import CoreGraphics
import ShareXCore

/// The y-down drawing helpers shared by the view and the exporter.
enum Imaging {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let maximumPixels = 64 * 1024 * 1024

    static func allocationBytes(width: Int, height: Int, maximumPixels: Int = Imaging.maximumPixels) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !areaOverflow, !byteOverflow, pixels <= maximumPixels else { return nil }
        return bytes
    }

    static func retainedBytes(of image: CGImage) -> Int? {
        let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return overflow || bytes <= 0 ? nil : bytes
    }

    static func accepts(_ image: CGImage) -> Bool {
        allocationBytes(width: image.width, height: image.height) != nil
            && retainedBytes(of: image).map { $0 <= maximumPixels * 4 } == true
    }

    static func pixelDimensions(size: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        guard scale.isFinite, scale > 0 else { return nil }
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        guard w.isFinite, h.isFinite, w >= 1, h >= 1,
              w <= CGFloat(maximumPixels), h <= CGFloat(maximumPixels),
              allocationBytes(width: Int(w), height: Int(h)) != nil else { return nil }
        return (Int(w), Int(h))
    }

    /// An RGBA8 premultiplied context. `flipped` gives y-down pixel coordinates.
    static func context(width: Int, height: Int, flipped: Bool) -> CGContext? {
        guard allocationBytes(width: width, height: height) != nil,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if flipped { ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1) }
        return ctx
    }

    /// Draws `image` upright into `rect` of a y-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    static func cgColor(_ c: RGBA, opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * opacity)
    }
}
