import Foundation
import ShareXCore

/// UserDefaults-backed settings. All reads and writes go through `value` / `update`.
@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings.v1"
    private var writesEnabled = true
    @Published private(set) var value: AppSettings

    init() { value = AppSettings.decode(UserDefaults.standard.data(forKey: Self.key)) }

    func freezeWrites() { writesEnabled = false }

    func update(_ f: (inout AppSettings) -> Void) {
        guard writesEnabled else { return }
        f(&value)
        UserDefaults.standard.set(value.encoded(), forKey: Self.key)
    }
}
