import Foundation

final class PushIntentStore {
    private let defaults: UserDefaults
    private let key = "push.pendingIntent"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func set(_ intent: PendingPushIntent) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(intent) else { return }
        defaults.set(data, forKey: key)
    }

    func setIfNew(_ intent: PendingPushIntent) -> Bool {
        if let existing = get(),
           let existingId = existing.notificationId,
           let incomingId = intent.notificationId,
           existingId == incomingId,
           Date() <= existing.expiresAt {
            return false
        }
        set(intent)
        return true
    }

    func get() -> PendingPushIntent? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(PendingPushIntent.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
