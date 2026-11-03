import Foundation

/// What the user picks before the shot. Mirrors ShareX's Capture menu, screenshot items only.
public enum CaptureStyle: String, Codable, CaseIterable, Sendable {
    case fullscreen, activeMonitor, monitorPicker, activeWindow, windowPicker, region, lastRegion, freehand

    public var title: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .activeMonitor: "Active Monitor"
        case .monitorPicker: "Monitor…"
        case .activeWindow: "Active Window"
        case .windowPicker: "Window…"
        case .region: "Region"
        case .lastRegion: "Last Region"
        case .freehand: "Freehand"
        }
    }

    /// The overlay interaction this style needs before the image exists. Every style opens the
    /// annotation editor afterwards, so this only describes how the area is chosen.
    public var selection: SelectionMode {
        switch self {
        case .fullscreen, .activeMonitor, .activeWindow, .lastRegion: .none
        case .monitorPicker: .pickMonitor
        case .windowPicker: .pickWindow
        case .region: .rectangle
        case .freehand: .lasso
        }
    }
}

public enum SelectionMode: Sendable, Equatable { case none, rectangle, lasso, pickWindow, pickMonitor }

public struct RGBA: Codable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    public static let red = RGBA(0.93, 0.18, 0.18), yellow = RGBA(1, 0.86, 0.1), black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1), blue = RGBA(0.16, 0.47, 0.98), green = RGBA(0.2, 0.75, 0.3)
    public static let palette: [RGBA] = [.red, .yellow, .green, .blue, .black, .white]

    /// Each component clamped to 0...1.
    public func sanitized() -> RGBA {
        func c(_ x: Double) -> Double { x.isFinite ? min(max(0, x), 1) : 1 }
        return RGBA(c(r), c(g), c(b), c(a))
    }
}

/// Options applied around a capture (ShareX "capture settings").
public struct CaptureOptions: Codable, Hashable, Sendable {
    public var delaySeconds: Int = 0
    public var showCursor = false
    public var showMagnifier = true
    public var borderWidth: Int = 0
    public var borderColor: RGBA = .black
    /// Window styles keep the system shadow; other styles get a drawn drop shadow.
    public var shadow = false
    public var openEditor = true
    public static let delayChoices = [0, 1, 2, 3, 5, 10]
    public static let maxBorderWidth = 20, maxDelaySeconds = 60
    public init() {}

    /// Missing or unreadable keys keep their defaults, so an option added later (borderColor was) does not
    /// reset the user's other options when old settings are read.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        let def = CaptureOptions()
        delaySeconds = v(.delaySeconds, def.delaySeconds); showCursor = v(.showCursor, def.showCursor)
        showMagnifier = v(.showMagnifier, def.showMagnifier); borderWidth = v(.borderWidth, def.borderWidth)
        borderColor = v(.borderColor, def.borderColor); shadow = v(.shadow, def.shadow); openEditor = v(.openEditor, def.openEditor)
    }

    /// Values a hand-edited or corrupt settings file could carry are brought back into the ranges the UI offers.
    /// An unbounded border width, for example, would overflow the pixel maths in the exporter.
    public func sanitized() -> CaptureOptions {
        var o = self
        o.delaySeconds = min(max(0, delaySeconds), Self.maxDelaySeconds)
        o.borderWidth = min(max(0, borderWidth), Self.maxBorderWidth)
        o.borderColor = borderColor.sanitized()
        return o
    }
}

public struct CaptureRequest: Sendable, Equatable {
    public var style: CaptureStyle
    public var options: CaptureOptions
    public init(style: CaptureStyle, options: CaptureOptions) { (self.style, self.options) = (style, options) }
}

/// Canvas layout for border + drop shadow post-processing, in pixels.
public struct DecorationLayout: Equatable, Sendable {
    public var canvas: CGSize
    /// Where the captured image is drawn, y-down.
    public var image: CGRect
    /// Shadow size in points; multiplied by the capture scale so it looks the same at 1x and 2x.
    public static let shadowBlurPoints: CGFloat = 24
    public static let shadowOffsetPoints: CGFloat = 8
    /// Shadow blur and offset for this layout, in pixels.
    public let shadowBlur: CGFloat
    public let shadowOffset: CGFloat

    /// `border` is already in pixels; `scale` converts the shadow from points.
    public init(imageSize s: CGSize, border: Int, shadow: Bool, scale: CGFloat = 1) {
        let b = CGFloat(max(0, border))
        shadowBlur = Self.shadowBlurPoints * scale
        shadowOffset = Self.shadowOffsetPoints * scale
        let pad = shadow ? shadowBlur + shadowOffset : 0
        canvas = CGSize(width: s.width + 2 * (b + pad), height: s.height + 2 * (b + pad))
        image = CGRect(x: b + pad, y: b + pad, width: s.width, height: s.height)
    }
}
