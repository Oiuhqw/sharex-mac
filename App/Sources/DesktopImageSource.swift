import AppKit
import ShareXCore

/// Immutable native tiles. Only samples and final crops allocate new pixels.
struct DesktopImageSource {
    struct Tile {
        let image: CGImage
        let rect: CGRect
        let scale: CGFloat
    }
    let bounds: CGRect
    let tiles: [Tile]
    let layout: DesktopLayout?
    var colorSpace: CGColorSpace { tiles.first?.image.colorSpace ?? Imaging.colorSpace }

    init(image: CGImage, scale: CGFloat) {
        bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        tiles = [Tile(image: image, rect: bounds, scale: scale)]
        layout = nil
    }

    init?(frozen: [FrozenScreen]) {
        guard frozen.allSatisfy({ Imaging.accepts($0.image) }),
              let map = DesktopLayout(displays: frozen.map {
                  .init(id: $0.displayID, frame: $0.frame, scale: $0.scale)
              }) else { return nil }
        self.init(layout: map, images: frozen.map(\.image))
    }

    init?(layout: DesktopLayout, images: [CGImage]) {
        guard images.count == layout.displays.count, images.allSatisfy(Imaging.accepts) else { return nil }
        self.layout = layout; bounds = layout.bounds
        tiles = zip(images, layout.displays).map { Tile(image: $0.0, rect: layout.placement($0.1), scale: $0.1.scale) }
    }

    func scale(for crop: CGRect) -> CGFloat? {
        tiles.filter { let r = $0.rect.intersection(crop); return !r.isNull && r.width > 0 && r.height > 0 }.map(\.scale).max()
    }

    func selection(_ crop: CGRect) -> CGRect? {
        guard [crop.minX, crop.minY, crop.maxX, crop.maxY].allSatisfy(\.isFinite) else { return nil }
        let r = crop.intersection(bounds)
        return !r.isNull && r.width > 0 && r.height > 0 && scale(for: r) != nil ? r : nil
    }

    func draw(in ctx: CGContext, area: CGRect) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.clip(to: area)
        for tile in tiles where tile.rect.intersects(area) {
            Imaging.drawUpright(tile.image, in: tile.rect, ctx: ctx)
        }
    }

    func sample(_ area: CGRect, scale: CGFloat, maximumPixels: Int) -> CGImage? {
        guard let size = Imaging.pixelDimensions(size: area.size, scale: scale),
              Imaging.allocationBytes(width: size.width, height: size.height, maximumPixels: maximumPixels) != nil,
              let ctx = Imaging.context(width: size.width, height: size.height, flipped: true) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.interpolationQuality = .none
        draw(in: ctx, area: area)
        return ctx.makeImage()
    }
}
