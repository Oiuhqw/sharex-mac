import AppKit

/// Screen Recording (TCC). There is no entitlement for it; it is a user grant.
@MainActor
enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts once per install. Returns whether access is granted right now.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        ScreenCapture.e2eFixture != nil || hasScreenRecording || CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shown when a capture is attempted without access. Never fail silently.
    static func showDeniedAlert() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Screen Recording is off"
        a.informativeText = "ShareX needs Screen Recording permission to take screenshots. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen ShareX."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Quit & Reopen")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: openSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
