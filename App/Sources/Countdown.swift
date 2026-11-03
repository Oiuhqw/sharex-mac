import AppKit

/// The delay timer HUD. Never captured: sharingType is .none and it is closed before the freeze.
/// Esc cancels: a local monitor catches it while we are active, a global one while another app is
/// (the global monitor only delivers once Accessibility is granted, so a click on the HUD also cancels).
@MainActor
enum Countdown {
    /// Returns false when the user cancelled.
    static func run(seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        label.textColor = .white; label.alignment = .center
        let hint = NSTextField(labelWithString: "Esc or click to cancel")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .white.withAlphaComponent(0.8); hint.alignment = .center
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 140, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.hasShadow = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        panel.sharingType = .none
        label.frame = CGRect(x: 0, y: 30, width: 140, height: 60)
        hint.frame = CGRect(x: 0, y: 8, width: 140, height: 16)
        let click = ClickView(frame: CGRect(x: 0, y: 0, width: 140, height: 100))
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(hint)
        panel.contentView?.addSubview(click)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: s.frame.midX - 70, y: s.frame.midY - 50))
        }

        let flag = Flag()
        click.onClick = { flag.cancelled = true }
        let isEsc = { (e: NSEvent) in e.keyCode == 53 }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if isEsc(e) { Task { @MainActor in flag.cancelled = true }; return nil }
            return e
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            if isEsc(e) { Task { @MainActor in flag.cancelled = true } }
        }
        defer {
            if let local { NSEvent.removeMonitor(local) }
            if let global { NSEvent.removeMonitor(global) }
            panel.orderOut(nil)
        }

        panel.orderFrontRegardless()
        // Tick in 50 ms steps so a cancel lands at once instead of at the next second.
        for n in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(n)"
            for _ in 0..<20 {
                if flag.cancelled { return false }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if flag.cancelled { return false }
        panel.orderOut(nil)
        // Let the window server drop the panel before the frame is grabbed.
        try? await Task.sleep(for: .milliseconds(80))
        return !flag.cancelled
    }

    @MainActor private final class Flag { var cancelled = false }

    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}
