import Foundation

public struct CapturePixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum CaptureGeometry {
    public static func validate(region: CaptureRegion, target: CaptureTarget) throws {
        guard target.kind == .display else { throw AgentFailure(.invalidRequest, "Regions require a display target.") }
        let components = [region.x, region.y, region.width, region.height, target.widthPoints, target.heightPoints]
        guard components.allSatisfy(\.isFinite), region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              region.x + region.width <= target.widthPoints, region.y + region.height <= target.heightPoints else {
            throw AgentFailure(.invalidRequest, "The region must fit inside the selected display in logical points.")
        }
    }

    public static func recordingSize(widthPixels: Int, heightPixels: Int) throws -> CapturePixelSize {
        guard widthPixels > 0, heightPixels > 0 else { throw AgentFailure(.invalidRequest, "The capture dimensions must be positive.") }
        let limits = CaptureLimits()
        let factor = min(1, min(Double(limits.maxWidthPixels) / Double(widthPixels), Double(limits.maxHeightPixels) / Double(heightPixels)))
        let width = Int(Double(widthPixels) * factor) / 2 * 2
        let height = Int(Double(heightPixels) * factor) / 2 * 2
        guard width >= 2, height >= 2 else { throw AgentFailure(.invalidRequest, "The selected region is too thin for H.264 video. Select a wider or taller region.") }
        return CapturePixelSize(width: width, height: height)
    }
}
