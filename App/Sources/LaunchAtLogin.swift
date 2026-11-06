import AppKit
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLogin: ObservableObject {
    private static let configuredKey = "launchAtLogin.configured"
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var detail: String {
        if let errorMessage { return errorMessage }
        switch status {
        case .enabled: return "ShareX starts when you sign in. Your capture shortcuts are ready in the menu bar."
        case .requiresApproval: return "Allow ShareX in System Settings > General > Login Items to finish enabling startup."
        case .notRegistered: return "ShareX will not start automatically when you sign in."
        case .notFound: return "Move ShareX to Applications, then enable launch at login again."
        @unknown default: return "Check ShareX in System Settings > General > Login Items."
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func enableByDefaultIfNeeded() {
        refresh()
        guard !UserDefaults.standard.bool(forKey: Self.configuredKey) else { return }
        if status == .notRegistered || status == .notFound { setEnabled(true) }
        else { UserDefaults.standard.set(true, forKey: Self.configuredKey) }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        do {
            if enabled && !isRequested { try SMAppService.mainApp.register() }
            else if !enabled && isRequested { try SMAppService.mainApp.unregister() }
            // Apply the default once. Later launches respect changes made in either Settings app.
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
        } catch {
            errorMessage = "Could not change launch at login. \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    #if SHAREX_E2E
    static func e2eResetDefault() { UserDefaults.standard.removeObject(forKey: configuredKey) }
    #endif
}
