import Foundation
import OneSignalFramework

@MainActor
final class PushRegistrationManager {
    static let shared = PushRegistrationManager()

    private let store = PushRegistrationStore()
    private var api: ApiService?
    private var supabase: SupabaseService?

    private var pendingRegisterTask: Task<Void, Never>?
    private var pendingUnregisterTask: Task<Void, Never>?
    private var lastAttemptedKey: String?
    private var lastAttemptAt: Date?
    private var lastUnregisterKey: String?
    private var lastUnregisterAt: Date?
    private var isRegistering = false
    private var isUnregistering = false

    private let debounceInterval: TimeInterval = 1.5
    private let attemptCooldown: TimeInterval = 20

    private init() {}

    func configure(api: ApiService, supabase: SupabaseService = .shared) {
        self.api = api
        self.supabase = supabase
    }

    func syncRegistration(trigger: String) {
        scheduleRegister(trigger: trigger)
    }

    func handleSubscriptionChange(trigger: String = "subscriptionChange") {
        scheduleRegister(trigger: trigger)
    }

    func unregisterForSignOut(trigger: String) async {
        await unregisterIfPossible(trigger: trigger, force: true)
    }

    private func scheduleRegister(trigger: String) {
        pendingRegisterTask?.cancel()
        pendingRegisterTask = Task { [weak self] in
            let delay = (self?.debounceInterval ?? 1.5) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(delay))
            await self?.registerIfNeeded(trigger: trigger)
        }
    }

    private func scheduleUnregister(trigger: String) {
        pendingUnregisterTask?.cancel()
        pendingUnregisterTask = Task { [weak self] in
            let delay = (self?.debounceInterval ?? 1.5) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(delay))
            await self?.unregisterIfPossible(trigger: trigger, force: false)
        }
    }

    private func registerIfNeeded(trigger: String) async {
        guard let api else {
            DLog("[PUSH_REG] skip reason=missing_api trigger=\(trigger)")
            return
        }

        let supabase = self.supabase ?? .shared
        guard supabase.phase == .signedIn, let userId = supabase.userId?.uuidString else {
            DLog("[PUSH_REG] skip reason=not_signed_in trigger=\(trigger)")
            return
        }

        let subscription = OneSignal.User.pushSubscription
        guard let subscriptionId = subscription.id, subscriptionId.isEmpty == false else {
            DLog("[PUSH_REG] skip reason=missing_subscription trigger=\(trigger)")
            return
        }
        let optedIn = subscription.optedIn

        let attemptKey = "\(userId)|\(subscriptionId)"
        if lastAttemptedKey == attemptKey,
           let lastAttemptAt,
           Date().timeIntervalSince(lastAttemptAt) < attemptCooldown {
            DLog("[PUSH_REG] skip reason=cooldown trigger=\(trigger)")
            return
        }

        if let state = store.get(),
           state.userId == userId,
           state.subscriptionId == subscriptionId {
            DLog("[PUSH_REG] skip reason=already_registered trigger=\(trigger)")
            return
        }

        if isRegistering {
            DLog("[PUSH_REG] skip reason=in_flight trigger=\(trigger)")
            return
        }

        lastAttemptedKey = attemptKey
        lastAttemptAt = Date()
        isRegistering = true
        DLog("[PUSH_REG] start trigger=\(trigger) subscriptionId=\(subscriptionId) optedIn=\(optedIn)")
        defer { isRegistering = false }

        do {
            try await api.registerPush(
                playerId: subscriptionId,
                subscriptionId: subscriptionId,
                deviceToken: subscription.token
            )
            store.set(
                PushRegistrationState(
                    userId: userId,
                    subscriptionId: subscriptionId,
                    registeredAt: Date()
                )
            )
            DLog("[PUSH_REG] ok subscriptionId=\(subscriptionId)")
        } catch {
            DLog("[PUSH_REG] fail error=\(error.localizedDescription)")
        }
    }

    private func unregisterIfPossible(trigger: String, force: Bool) async {
        guard let api else {
            DLog("[PUSH_UNREG] skip reason=missing_api trigger=\(trigger)")
            return
        }

        guard let state = store.get() else {
            DLog("[PUSH_UNREG] skip reason=missing_state trigger=\(trigger)")
            return
        }

        if isUnregistering {
            DLog("[PUSH_UNREG] skip reason=in_flight trigger=\(trigger)")
            return
        }

        let attemptKey = "\(state.userId)|\(state.subscriptionId)"
        if force == false,
           lastUnregisterKey == attemptKey,
           let lastUnregisterAt,
           Date().timeIntervalSince(lastUnregisterAt) < attemptCooldown {
            DLog("[PUSH_UNREG] skip reason=cooldown trigger=\(trigger)")
            return
        }

        lastUnregisterKey = attemptKey
        lastUnregisterAt = Date()
        isUnregistering = true
        DLog("[PUSH_UNREG] start trigger=\(trigger) subscriptionId=\(state.subscriptionId)")
        defer { isUnregistering = false }

        do {
            try await api.unregisterPush(playerId: state.subscriptionId)
            store.clear()
            DLog("[PUSH_UNREG] ok subscriptionId=\(state.subscriptionId)")
        } catch {
            DLog("[PUSH_UNREG] fail error=\(error.localizedDescription)")
        }
    }
}

private struct PushRegistrationState: Codable {
    let userId: String
    let subscriptionId: String
    let registeredAt: Date
}

private final class PushRegistrationStore {
    private let defaults: UserDefaults
    private let key = "push.registration.state"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func set(_ state: PushRegistrationState) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func get() -> PushRegistrationState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(PushRegistrationState.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
