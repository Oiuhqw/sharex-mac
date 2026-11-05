import Combine
import Foundation
import KeyboardShortcuts
import ShareXCore

/// Global shortcuts (Carbon RegisterEventHotKey underneath; no Accessibility permission).
/// Defaults avoid the system-owned ⌘⇧3/4/5.
extension KeyboardShortcuts.Name {
    static let region = Self("captureRegion", initial: .init(.one, modifiers: [.control, .shift]))
    static let window = Self("captureWindowPicker", initial: .init(.two, modifiers: [.control, .shift]))
    static let fullscreen = Self("captureFullscreen", initial: .init(.three, modifiers: [.control, .shift]))
    static let activeMonitor = Self("captureActiveMonitor", initial: .init(.four, modifiers: [.control, .shift]))
    static let freehand = Self("captureFreehand", initial: .init(.five, modifiers: [.control, .shift]))
    static let activeWindow = Self("captureActiveWindow")
    static let monitorPicker = Self("captureMonitorPicker")
    static let lastRegion = Self("captureLastRegion")
}

@MainActor
enum Hotkeys {
    struct Command: Identifiable {
        let style: CaptureStyle
        let name: KeyboardShortcuts.Name
        let detail: String
        var id: String { style.rawValue }
        var title: String { style.title }
    }

    static let commands: [Command] = [
        .init(style: .region, name: .region, detail: "Select a rectangle on the screen."),
        .init(style: .windowPicker, name: .window, detail: "Choose a window to capture."),
        .init(style: .fullscreen, name: .fullscreen, detail: "Capture all connected displays."),
        .init(style: .activeMonitor, name: .activeMonitor, detail: "Capture the display under the pointer."),
        .init(style: .freehand, name: .freehand, detail: "Draw around an area to capture."),
        .init(style: .activeWindow, name: .activeWindow, detail: "Capture the frontmost window."),
        .init(style: .monitorPicker, name: .monitorPicker, detail: "Choose one display to capture."),
        .init(style: .lastRegion, name: .lastRegion, detail: "Capture the previous area again."),
    ]

    static func register(_ capture: @escaping @MainActor @Sendable (CaptureStyle) -> Void) {
        recoverStoredShortcuts()
        for command in commands {
            // Key down, not key up: waiting for the release added the whole key-hold time to every capture.
            let style = command.style
            KeyboardShortcuts.onKeyDown(for: command.name) { Task { @MainActor in capture(style) } }
        }
    }

    private static func recoverStoredShortcuts() {
        let defaults = UserDefaults.standard
        var invalid: [Command] = []
        for command in commands {
            let key = "KeyboardShortcuts_\(command.name.rawValue)"
            guard let value = defaults.object(forKey: key) else { continue }
            if let enabled = value as? Bool, !enabled { continue }
            if let encoded = value as? String, encoded.utf8.count <= 1024,
               let shortcut = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: Data(encoded.utf8)),
               UInt16(exactly: shortcut.carbonKeyCode) != nil,
               UInt32(exactly: shortcut.carbonModifiers) != nil {
                continue
            }
            defaults.set(false, forKey: key)
            invalid.append(command)
        }
        for command in invalid where conflict(for: command.name.initialShortcut, command: command) == nil {
            KeyboardShortcuts.reset([command.name])
        }
    }

    private static func conflict(for shortcut: KeyboardShortcuts.Shortcut?, command: Command) -> Command? {
        guard let shortcut else { return nil }
        return commands.first { $0.id != command.id && KeyboardShortcuts.getShortcut(for: $0.name) == shortcut }
    }

    @MainActor
    final class Editor: ObservableObject {
        enum Feedback {
            case saved(String)
            case conflict(String)

            var text: String {
                switch self { case .saved(let text), .conflict(let text): text }
            }
            var isConflict: Bool {
                if case .conflict = self { return true }
                return false
            }
        }

        @Published private(set) var feedback: Feedback?

        func validate(_ shortcut: KeyboardShortcuts.Shortcut, for command: Command) -> KeyboardShortcuts.ValidationResult {
            if let other = conflict(for: shortcut, command: command) {
                let reason = "That shortcut is used by \(other.title). Choose another shortcut."
                feedback = .conflict(reason)
                return .disallow(reason: reason)
            }
            return .allow
        }

        func recorded(_ shortcut: KeyboardShortcuts.Shortcut?, for command: Command) {
            feedback = .saved(shortcut == nil ? "\(command.title) shortcut cleared." : "\(command.title) shortcut saved.")
        }

        func clear(_ command: Command) {
            KeyboardShortcuts.setShortcut(nil, for: command.name)
            recorded(nil, for: command)
        }

        func restore(_ command: Command) {
            if let other = conflict(for: command.name.initialShortcut, command: command) {
                feedback = .conflict("The default shortcut is used by \(other.title). Clear or change that shortcut first.")
                return
            }
            KeyboardShortcuts.reset([command.name])
            feedback = .saved("\(command.title) default restored.")
        }

        func restoreAll() {
            KeyboardShortcuts.reset(commands.map(\.name))
            feedback = .saved("All eight shortcut defaults restored.")
        }
    }
}
