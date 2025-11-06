// AUDIT REPORT:
// After you run a DEBUG build and reproduce the issue, paste [FLOW]/[GATE]/[AUTH] logs here.
// Summary:
// - Single source of truth: AppFlowCoordinator.phase, driven by SupabaseService.phase & didCheckSession
// - Gating: hasCompletedProfile (per-user defaults), hasCompletedIntro (per-user defaults)
// - Next steps: capture logs around launch and first navigation decision
//
// Acceptance Criteria:
// - Returning user who finished onboarding goes straight to feed (Phase.main)
// - New user: profile capture → onboarding (once) → feed
// - Reinstalls/bundle ID changes don’t auto-skip unless using server-side flag (optional)

import Combine
import Foundation

@MainActor
final class AppFlowCoordinator: ObservableObject {
    enum Phase: Equatable {
        case launching
        case auth
        case loadingProfile
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
    private var profileLoadDone: Bool = false
    private var serverProfileHasName: Bool = false

    private var profileCompletionByUser: [String: Bool]
    private var introCompletionByUser: [String: Bool]
    private var currentUserKey: String?

    private var loadingTask: Task<Void, Never>?
    private var loadingStartedAt: Date?
    private let minimumLoadingDuration: TimeInterval = 2.7

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
        // AUDIT: gating variable read (onboarding completion, centralized)
        let v = OnboardingStorage.isComplete()
        AuditLog.gate("read onboarding_completed_v1 = \(v)")
        return v
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
        OnboardingStorage.markComplete()
        // AUDIT: onboarding completion set
        AuditLog.gate("onboarding_completed_v1 set → true")
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
            profileLoadDone = false
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
        // AUDIT: launch → decide
        AuditLog.flow("launch → decide (reason=\(reason))")
        let sessionOK = supabase.phase == .signedIn
        let profileOK = hasCompletedProfile
        let introOK = hasCompletedIntro
        AuditLog.gate("session=\(sessionOK) profile=\(profileOK) onboarding=\(introOK) didCheckSession=\(supabase.didCheckSession)")
        guard supabase.didCheckSession else {
            updatePhase(.launching, reason: reason)
            return
        }

        guard supabase.phase == .signedIn else {
            updatePhase(.auth, reason: reason)
            return
        }

        // Ensure profile info is loaded/checked before deciding capture
        if profileLoadDone == false {
            enterLoadingProfile(reason: reason)
            return
        }

        // Consider server metadata name as a signal of profile completeness
        let effectiveProfileComplete = hasCompletedProfile || serverProfileHasName
        guard effectiveProfileComplete else {
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

    private func enterLoadingProfile(reason: String) {
        if phase != .loadingProfile {
            updatePhase(.loadingProfile, reason: reason)
        }
        Task { [weak self] in
            guard let self else { return }
            // Read session metadata as current source of truth for profile name
            let nameMeta = supabase.session?.user.userMetadata["full_name"]?.description
                ?? supabase.session?.user.userMetadata["name"]?.description
                ?? ""
            let trimmed = nameMeta.trimmingCharacters(in: .whitespacesAndNewlines)
            self.serverProfileHasName = !trimmed.isEmpty
            self.profileLoadDone = true
            AuditLog.gate("profile fetch: name='\(trimmed)' → hasName=\(self.serverProfileHasName)")
            await MainActor.run { [weak self] in
                self?.evaluatePhase(reason: "profileLoaded")
            }
        }
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
        // Kept for legacy migration compatibility; now centralized in OnboardingStorage
        if value { introCompletionByUser[key] = true } else { introCompletionByUser.removeValue(forKey: key) }
        saveIntroFlags()
        AuditLog.gate("persist introCompletion[\(key)] = \(value)")
    }
}
