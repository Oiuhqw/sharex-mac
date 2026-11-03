import KeyboardShortcuts
import ShareXCore

/// Global shortcuts (Carbon RegisterEventHotKey underneath; no Accessibility permission).
/// Defaults avoid the system-owned ⌘⇧3/4/5.
extension KeyboardShortcuts.Name {
    static let region = Self("captureRegion", default: .init(.one, modifiers: [.control, .shift]))
    static let window = Self("captureWindowPicker", default: .init(.two, modifiers: [.control, .shift]))
    static let fullscreen = Self("captureFullscreen", default: .init(.three, modifiers: [.control, .shift]))
    static let activeMonitor = Self("captureActiveMonitor", default: .init(.four, modifiers: [.control, .shift]))
    static let freehand = Self("captureFreehand", default: .init(.five, modifiers: [.control, .shift]))
    static let activeWindow = Self("captureActiveWindow")
    static let monitorPicker = Self("captureMonitorPicker")
    static let lastRegion = Self("captureLastRegion")
}

enum Hotkeys {
    static let all: [(CaptureStyle, KeyboardShortcuts.Name)] = [
        (.region, .region), (.windowPicker, .window), (.fullscreen, .fullscreen), (.activeMonitor, .activeMonitor),
        (.freehand, .freehand), (.activeWindow, .activeWindow), (.monitorPicker, .monitorPicker), (.lastRegion, .lastRegion),
    ]

    @MainActor
    static func register(_ capture: @escaping @MainActor @Sendable (CaptureStyle) -> Void) {
        for (style, name) in all {
            // Key down, not key up: waiting for the release added the whole key-hold time to every capture.
            KeyboardShortcuts.onKeyDown(for: name) { Task { @MainActor in capture(style) } }
        }
    }
}
