import Foundation

/// Persistent user preferences. Backed by `UserDefaults.standard`.
/// Add new keys as static `Key` constants + a typed property.
@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let showTouchRing = "sims.settings.showTouchRing"
    }

    /// Posted whenever any setting changes. Observers refresh their UI
    /// off this — saves wiring per-key notifications.
    static let didChange = Notification.Name("sims.settings.didChange")

    private init() {
        defaults.register(defaults: [
            Key.showTouchRing: false,
        ])
    }

    var showTouchRing: Bool {
        get { defaults.bool(forKey: Key.showTouchRing) }
        set {
            defaults.set(newValue, forKey: Key.showTouchRing)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
