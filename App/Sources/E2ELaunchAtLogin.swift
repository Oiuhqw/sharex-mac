#if SHAREX_E2E
import AppKit
import ServiceManagement

@MainActor
enum E2ELaunchAtLogin {
    /// Run in separate processes to verify that the OS registration and opt-out survive relaunch.
    static func run(_ step: String) {
        let login = LaunchAtLogin()
        var passed = false
        switch step {
        case "default":
            guard login.status == .notRegistered else { report(step, login, passed: false); return }
            LaunchAtLogin.e2eResetDefault()
            login.enableByDefaultIfNeeded()
            passed = login.status == .enabled
        case "relaunch-enabled":
            let before = login.status
            login.enableByDefaultIfNeeded()
            passed = before == .enabled && login.status == .enabled
        case "disable":
            login.setEnabled(false)
            passed = login.status == .notRegistered
        case "relaunch-disabled":
            let before = login.status
            login.enableByDefaultIfNeeded()
            passed = before == .notRegistered && login.status == .notRegistered
        case "enable":
            login.setEnabled(true)
            passed = login.status == .enabled
        case "system-disable":
            do { try SMAppService.mainApp.unregister(); passed = SMAppService.mainApp.status == .notRegistered }
            catch { passed = false }
            login.refresh()
        case "cleanup":
            login.setEnabled(false)
            LaunchAtLogin.e2eResetDefault()
            passed = login.status == .notRegistered
        default: break
        }
        report(step, login, passed: passed && login.errorMessage == nil)
    }

    private static func report(_ step: String, _ login: LaunchAtLogin, passed: Bool) {
        let result: [String: Any] = ["step": step, "pass": passed, "status": login.status.rawValue,
                                   "detail": login.detail, "error": login.errorMessage ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(passed ? 0 : 2)
    }
}
#endif
