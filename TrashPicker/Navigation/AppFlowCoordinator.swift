import Combine
import Foundation

@MainActor
final class AppFlowCoordinator: ObservableObject {
    enum Phase: Equatable {
        case launching
        case auth
        case profileCapture
        case introShowcase
        case loading
        case main
    }

    @Published private(set) var phase: Phase = .launching

    private let supabase: SupabaseService
    private let boot: BootCoordinator
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    private var profileCompletionByUser: [String: Bool]
    private var introCompletionByUser: [String: Bool]
    private var currentUserKey: String?

    private var loadingTask: Task<Void, Never>?
    private var loadingStartedAt: Date?
    private let minimumLoadingDuration: TimeInterval = 0.45

    init(
        supabase: SupabaseService = .shared,
        bootCoordinator: BootCoordinator = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.supabase = supabase
        self.boot = bootCoordinator
        self.defaults = defaults
        self.profileCompletionByUser = defaults.dictionary(forKey: Keys.profileCompletion) as? [String: Bool] ?? [:]
        self.introCompletionByUser = defaults.dictionary(forKey: Keys.introCompletion) as? [String: Bool] ?? [:]
        self.currentUserKey = supabase.userId?.uuidString.lowercased()

        migrateLegacyFlagsIfNeeded(userKey: currentUserKey)
        bind()
        evaluatePhase(reason: "init")
    }

    var hasCompletedProfile: Bool {
        guard let key = currentUserKey else { return false }
        return profileCompletionByUser[key] == true
    }

    var hasCompletedIntro: Bool {
        guard let key = currentUserKey else { return false }
        return introCompletionByUser[key] == true
    }

    func markProfileComplete() {
        guard let key = currentUserKey else { return }
        let alreadyComplete = profileCompletionByUser[key] == true
        profileCompletionByUser[key] = true
        saveProfileFlags()

        if introCompletionByUser[key] != true {
            setIntroCompletion(false, for: key)
        }

        if alreadyComplete == false {
            loadingTask?.cancel()
            loadingTask = nil
            loadingStartedAt = nil
        }

        evaluatePhase(reason: "profileComplete")
    }

    func markIntroComplete() {
        guard let key = currentUserKey else {
            evaluatePhase(reason: "introComplete_noUser")
            return
        }

        if introCompletionByUser[key] == true {
            evaluatePhase(reason: "introComplete_existing")
            return
        }

        setIntroCompletion(true, for: key)
        evaluatePhase(reason: "introComplete_new")
    }

    func resetIntroForCurrentUser() {
        guard let key = currentUserKey else { return }
        setIntroCompletion(false, for: key)
        evaluatePhase(reason: "introReset")
    }

    private enum Keys {
        static let profileCompletion = "appflow.profileCompletionByUser"
        static let introCompletion = "appflow.introCompletionByUser"
        static let legacyProfile = "onboardingComplete"
        static let legacyIntro = "didFinishShowcase"
    }

    private func bind() {
        supabase.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleAuthPhaseChange() }
            .store(in: &cancellables)

        supabase.$userId
            .map { $0?.uuidString.lowercased() }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userKey in self?.handleUserChange(userKey) }
            .store(in: &cancellables)

        supabase.$didCheckSession
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluatePhase(reason: "didCheckSession") }
            .store(in: &cancellables)

        boot.$stage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluatePhase(reason: "bootStage") }
            .store(in: &cancellables)
    }

    private func handleAuthPhaseChange() {
        if supabase.phase != .signedIn {
            loadingTask?.cancel()
            loadingTask = nil
            loadingStartedAt = nil
        }
        evaluatePhase(reason: "authPhase")
    }

    private func handleUserChange(_ key: String?) {
        if currentUserKey == key { return }
        currentUserKey = key
        migrateLegacyFlagsIfNeeded(userKey: key)
        evaluatePhase(reason: "userChange")
    }

    private func migrateLegacyFlagsIfNeeded(userKey: String?) {
        guard let userKey else { return }
        let legacyProfile = defaults.object(forKey: Keys.legacyProfile) as? Bool
        let legacyIntro = defaults.object(forKey: Keys.legacyIntro) as? Bool

        if profileCompletionByUser[userKey] == nil, legacyProfile == true {
            profileCompletionByUser[userKey] = true
            saveProfileFlags()
        }

        if introCompletionByUser[userKey] == nil, legacyIntro == true {
            introCompletionByUser[userKey] = true
            saveIntroFlags()
        }

        if (legacyProfile ?? false) || (legacyIntro ?? false) {
            defaults.removeObject(forKey: Keys.legacyProfile)
            defaults.removeObject(forKey: Keys.legacyIntro)
        }
    }

    private func evaluatePhase(reason: String) {
        guard supabase.didCheckSession else {
            updatePhase(.launching, reason: reason)
            return
        }

        guard supabase.phase == .signedIn else {
            updatePhase(.auth, reason: reason)
            return
        }

        guard hasCompletedProfile else {
            updatePhase(.profileCapture, reason: reason)
            return
        }

        guard hasCompletedIntro else {
            updatePhase(.introShowcase, reason: reason)
            return
        }

        if phase == .main {
            return
        }

        enterLoadingFlow(reason: reason)
    }

    private func enterLoadingFlow(reason: String) {
        if phase != .loading {
            loadingStartedAt = Date()
            updatePhase(.loading, reason: reason)
        }
        scheduleTransitionToMain()
    }

    private func scheduleTransitionToMain() {
        guard phase == .loading else { return }

        loadingTask?.cancel()

        let remainingDelay: TimeInterval
        if let start = loadingStartedAt {
            remainingDelay = max(0, minimumLoadingDuration - Date().timeIntervalSince(start))
        } else {
            loadingStartedAt = Date()
            remainingDelay = minimumLoadingDuration
        }

        loadingTask = Task { [weak self] in
            if remainingDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
            }

            while true {
                if Task.isCancelled { return }
                let shouldContinue: Bool = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.boot.stage != .lazyScreens && self.supabase.phase == .signedIn
                }
                if !shouldContinue { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loadingStartedAt = nil
                self.updatePhase(.main, reason: "loadingComplete")
            }
        }
    }

    private func updatePhase(_ newPhase: Phase, reason: String) {
        guard phase != newPhase else { return }

        if phase == .loading && newPhase != .loading {
            loadingTask?.cancel()
            loadingTask = nil
            loadingStartedAt = nil
        }

        DLog("[AppFlow] \(phase) → \(newPhase) (\(reason))")

        phase = newPhase
    }

    private func saveProfileFlags() {
        defaults.set(profileCompletionByUser, forKey: Keys.profileCompletion)
    }

    private func saveIntroFlags() {
        defaults.set(introCompletionByUser, forKey: Keys.introCompletion)
    }

    private func setIntroCompletion(_ value: Bool, for key: String) {
        if value {
            introCompletionByUser[key] = true
        } else {
            introCompletionByUser.removeValue(forKey: key)
        }
        saveIntroFlags()
    }
}
