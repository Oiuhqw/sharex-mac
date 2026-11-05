import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A saved area relative to an anchor display, with optional participating display geometry.
public struct LastRegion: Codable, Equatable, Sendable {
    /// CGDirectDisplayID of the display the region was on.
    public var displayID: UInt32
    /// Anchor display top-left points.
    public var rect: CGRect
    public init(displayID: UInt32, rect: CGRect) { (self.displayID, self.rect) = (displayID, rect) }

    public struct Participant: Codable, Equatable, Sendable {
        public let id: UInt32
        public let relativeFrame: CGRect
    }
    /// Cocoa frames relative to the anchor. Nil is the original single-display format.
    public var participants: [Participant]?

    public init?(crop: CGRect, layout: DesktopLayout) {
        let touched = layout.participants(in: crop)
        guard let anchor = touched.first, let crop = layout.selection(crop) else { return nil }
        displayID = anchor.id
        let placement = layout.placement(anchor)
        rect = crop.offsetBy(dx: -placement.minX, dy: -placement.minY)
        participants = touched.map { Participant(id: $0.id, relativeFrame: $0.frame.offsetBy(dx: -anchor.frame.minX, dy: -anchor.frame.minY)) }
    }

    public func resolve(layout: DesktopLayout) -> CGRect? {
        guard isValid, let anchor = layout.displays.first(where: { $0.id == displayID }) else { return nil }
        let placement = layout.placement(anchor)
        if let participants {
            for saved in participants {
                guard let current = layout.displays.first(where: { $0.id == saved.id }),
                      current.frame.offsetBy(dx: -anchor.frame.minX, dy: -anchor.frame.minY) == saved.relativeFrame else { return nil }
            }
            let crop = rect.offsetBy(dx: placement.minX, dy: placement.minY)
            return layout.selection(crop)
        }
        return resolve(displays: [(anchor.id, anchor.frame.size)])?.rect.offsetBy(dx: placement.minX, dy: placement.minY)
    }

    var isValid: Bool {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                      rect.origin.x + rect.size.width, rect.origin.y + rect.size.height]
        if let participants {
            guard !participants.isEmpty, participants.count <= 64,
                  participants.contains(where: { $0.id == displayID }),
                  Set(participants.map(\.id)).count == participants.count,
                  participants.allSatisfy({ p in
                      [p.relativeFrame.minX, p.relativeFrame.minY, p.relativeFrame.maxX, p.relativeFrame.maxY].allSatisfy { $0.isFinite && abs($0) <= CGFloat(Int32.max) }
                          && p.relativeFrame.width > 0 && p.relativeFrame.height > 0
                  }) else { return false }
        }
        return values.allSatisfy { $0.isFinite && abs($0) <= CGFloat(Int32.max) }
            && rect.size.width > 0 && rect.size.height > 0
    }

    /// Resolves only on the saved display and clamps the region to its current point bounds.
    /// Returns nil when that display is absent or the region has no usable area.
    public func resolve(displays: [(id: UInt32, size: CGSize)]) -> (id: UInt32, rect: CGRect)? {
        guard isValid else { return nil }
        guard let d = displays.first(where: { $0.id == displayID }) else { return nil }
        guard let r = Geometry.clamp(rect, to: CGRect(origin: .zero, size: d.size)) else { return nil }
        return (d.id, r)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var options = CaptureOptions()
    public var toolStyles: [ShapeKind: ShapeStyle] = [:]
    public var lastRegion: LastRegion?
    public var saveToFile = true
    /// Folder path; empty means ~/Pictures/ShareX.
    public var saveFolder = ""
    public var playSound = true
    public init() {}

    static let maximumStoredBytes = 1_048_576

    /// Decodes stored settings. Unknown or corrupt data yields defaults, and missing keys keep
    /// their defaults, so adding a setting never wipes the user's others.
    public static func decode(_ data: Data?) -> AppSettings {
        // Validate with JSONSerialization first: swift-foundation's JSONDecoder traps (a `try!` inside
        // JSONDecoder.swift) on some malformed input, such as a raw control character in an object key,
        // instead of throwing. Found by FuzzTests; corrupt stored settings must never crash launch.
        guard let data, data.count <= maximumStoredBytes,
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) is [String: Any],
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        options = ((try? c.decodeIfPresent(CaptureOptions.self, forKey: .options)) ?? def.options).sanitized()
        toolStyles = ((try? c.decodeIfPresent([ShapeKind: ShapeStyle].self, forKey: .toolStyles)) ?? def.toolStyles)
        toolStyles = Dictionary(uniqueKeysWithValues: toolStyles.map { ($0.key, $0.value.sanitized(for: $0.key)) })
        lastRegion = try? c.decodeIfPresent(LastRegion.self, forKey: .lastRegion)
        if lastRegion?.isValid == false { lastRegion = nil }
        saveToFile = (try? c.decodeIfPresent(Bool.self, forKey: .saveToFile)) ?? def.saveToFile
        saveFolder = (try? c.decodeIfPresent(String.self, forKey: .saveFolder)) ?? def.saveFolder
        playSound = (try? c.decodeIfPresent(Bool.self, forKey: .playSound)) ?? def.playSound
    }

    /// The first of `ShareX_<time>.png`, `ShareX_<time>-2.png`, … that `exists` says is free, so two
    /// captures in the same second never overwrite each other.
    public static func uniqueFileName(for date: Date, timeZone: TimeZone = .current, exists: (String) -> Bool) -> String {
        let base = fileName(for: date, timeZone: timeZone)
        if !exists(base) { return base }
        let stem = base.dropLast(4)
        var n = 2
        while exists("\(stem)-\(n).png") { n += 1 }
        return "\(stem)-\(n).png"
    }

    /// File name for a saved capture, ShareX-style.
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "ShareX_\(f.string(from: date)).png"
    }
}
