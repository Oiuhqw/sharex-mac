#if SHAREX_E2E
import AppKit
import ShareXCore

extension E2E {
    static func snapshotImageLayers(_ root: NSView, scale: CGFloat, name: String? = nil, display: Bool = true) -> Bitmap? {
        if display { root.window?.displayIfNeeded() }
        CATransaction.flush()
        let size = root.bounds.size
        guard let ctx = Imaging.context(width: Int(size.width * scale), height: Int(size.height * scale), flipped: true) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Layer delegates normally draw into separate backing bitmaps. Isolate siblings here so
        // a transparent view's clear cannot erase the previous layer.
        for child in root.subviews where !child.isHidden {
            guard child is FrameView || child is AnnotationsView || child is LiveMarkView else { continue }
            guard let layer = child.layer,
                  let isolated = Imaging.context(width: ctx.width, height: ctx.height, flipped: true) else { return nil }
            isolated.scaleBy(x: scale, y: scale)
            isolated.translateBy(x: child.frame.minX - root.bounds.minX, y: child.frame.minY - root.bounds.minY)
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
