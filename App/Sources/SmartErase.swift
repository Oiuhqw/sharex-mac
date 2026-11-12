import AppKit
import ShareXCore

enum SmartErase {
    private typealias RGB = SIMD3<Double>
    private struct Sample {
        let x: Double, y: Double
        let color: RGB
    }
    private struct Plane {
        let origin: RGB, dx: RGB, dy: RGB
        func at(_ x: Double, _ y: Double) -> RGB { origin + dx * x + dy * y }
    }

    static func samplingArea(_ rect: PixelRect, scale: CGFloat, width: Int, height: Int) -> PixelRect {
        let halo = max(4, Int(min(32, ceil(12 * scale))))
        let x = max(0, rect.x - halo), y = max(0, rect.y - halo)
        return PixelRect(x: x, y: y, w: min(width, rect.maxX + halo) - x, h: min(height, rect.maxY + halo) - y)
    }

    /// The four texel centers lie on the output corners.
    static func imageRect(for rect: CGRect) -> CGRect { rect.insetBy(dx: -rect.width / 2, dy: -rect.height / 2) }

    static func patch(source: DesktopImageSource, scale: CGFloat, output: PixelRect,
                      sample: PixelRect, exclusions: [PixelRect]) -> CGImage? {
        guard let reader = Imaging.context(width: 1, height: 1, flipped: false), let data = reader.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let outputPoints = output.points(scale: scale), samplePoints = sample.points(scale: scale)
        let excludedPoints = exclusions.map { $0.points(scale: scale) }
        let bands = [
            PixelRect(x: sample.x, y: sample.y, w: sample.w, h: output.y - sample.y),
            PixelRect(x: sample.x, y: output.maxY, w: sample.w, h: sample.maxY - output.maxY),
            PixelRect(x: sample.x, y: output.y, w: output.x - sample.x, h: output.h),
            PixelRect(x: output.maxX, y: output.y, w: sample.maxX - output.maxX, h: output.h)
        ]
        var samples: [Sample] = []
        samples.reserveCapacity(512)
        reader.interpolationQuality = .none
        reader.setBlendMode(.copy)
        for band in bands where band.w > 0 && band.h > 0 {
            let columns = min(band.w, min(128, max(1, Int(sqrt(128 * Double(band.w) / Double(band.h))))))
            let rows = min(band.h, max(1, 128 / columns))
            for row in 0..<rows { for column in 0..<columns {
                let x = band.x + Int((Double(column) + 0.5) * Double(band.w) / Double(columns))
                let y = band.y + Int((Double(row) + 0.5) * Double(band.h) / Double(rows))
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                guard let tile = source.tiles.last(where: { $0.rect.contains(point) }) else { continue }
                let sx = floor((point.x - tile.rect.minX) * tile.scale), sy = floor((point.y - tile.rect.minY) * tile.scale)
                let footprint = CGRect(x: tile.rect.minX + sx / tile.scale, y: tile.rect.minY + sy / tile.scale,
                                       width: 1 / tile.scale, height: 1 / tile.scale)
                guard samplePoints.contains(footprint), !outputPoints.intersects(footprint),
                      !excludedPoints.contains(where: { $0.intersects(footprint) }),
                      let pixel = tile.image.cropping(to: CGRect(x: sx, y: sy, width: 1, height: 1)) else { continue }
                reader.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                guard bytes[3] == 255 else { continue }
                samples.append(Sample(x: Double((footprint.midX - outputPoints.midX) / outputPoints.width) * 2,
                                      y: Double((footprint.midY - outputPoints.midY) / outputPoints.height) * 2,
                                      color: RGB(Double(bytes[0]), Double(bytes[1]), Double(bytes[2])) / 255))
            } }
        }
        guard let plane = fit(samples) else { return nil }
        var pixels: [UInt8] = []
        for y in [-1.0, 1.0] { for x in [-1.0, 1.0] {
            let color = plane.at(x, y)
            for channel in 0..<3 { pixels.append(UInt8((max(0, min(1, color[channel])) * 255).rounded())) }
            pixels.append(255)
        } }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                       space: Imaging.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func residual(_ sample: Sample, _ plane: Plane) -> Double {
        let d = sample.color - plane.at(sample.x, sample.y)
        return max(abs(d.x), max(abs(d.y), abs(d.z)))
    }

    private static func fit(_ samples: [Sample]) -> Plane? {
        guard samples.count >= 12 else { return nil }
        let constant = Plane(origin: RGB(median(samples.map { $0.color.x }), median(samples.map { $0.color.y }),
                                         median(samples.map { $0.color.z })), dx: .zero, dy: .zero)
        var weights = [Double](repeating: 1, count: samples.count)
        var plane = solve(samples, weights: weights) ?? constant
        for _ in 0..<4 {
            let residuals = samples.map { residual($0, plane) }
            let cutoff = max(3.0 / 255, median(residuals) * 4.685)
            weights = residuals.map { value in
                let ratio = value / cutoff
                return ratio < 1 ? pow(1 - ratio * ratio, 2) : 0
            }
            plane = solve(samples, weights: weights) ?? constant
        }
        let residuals = samples.map { residual($0, plane) }
        guard median(residuals) <= 6.0 / 255,
              residuals.filter({ $0 <= 12.0 / 255 }).count * 5 >= samples.count * 3 else { return nil }
        return plane
    }

    private static func solve(_ samples: [Sample], weights: [Double]) -> Plane? {
        var matrix = [Double](repeating: 0, count: 9), rhs = [RGB](repeating: .zero, count: 3)
        for (sample, weight) in zip(samples, weights) where weight > 0 {
            let basis = [1, sample.x, sample.y]
            for row in 0..<3 {
                rhs[row] += sample.color * (weight * basis[row])
                for column in 0..<3 { matrix[row * 3 + column] += weight * basis[row] * basis[column] }
            }
        }
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(matrix[$0 * 3 + column]) < abs(matrix[$1 * 3 + column]) }!
            guard abs(matrix[pivot * 3 + column]) > 1e-8 else { return nil }
            if pivot != column {
                for k in 0..<3 { matrix.swapAt(pivot * 3 + k, column * 3 + k) }
                rhs.swapAt(pivot, column)
            }
            let divisor = matrix[column * 3 + column]
            for k in column..<3 { matrix[column * 3 + k] /= divisor }
            rhs[column] /= divisor
            for row in 0..<3 where row != column {
                let factor = matrix[row * 3 + column]
                for k in column..<3 { matrix[row * 3 + k] -= factor * matrix[column * 3 + k] }
                rhs[row] -= rhs[column] * factor
            }
        }
        guard rhs.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        return Plane(origin: rhs[0], dx: rhs[1], dy: rhs[2])
    }
}
