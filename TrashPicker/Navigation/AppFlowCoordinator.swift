// AppFlowCoordinator: Server-driven flow routing
// Single source of truth: SupabaseService.serverProfile
// Routing order: Auth → LoadingProfile → ProfileCapture → PhoneVerification → IntroShowcase → Loading → Main
// No local UserDefaults gating; all decisions based on server profile state

import Combine
import Foundation

@MainActor
final class AppFlowCoordinator: ObservableObject {
    enum Phase: Equatable {
        case launching
        case auth
        case loadingProfile
        case profileError
        case profileCapture
        case phoneVerification
        case introShowcase
        case loading
        case main
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var profileErrorMessage: String?
    @Published private(set) var captureMessage: String?

    private let supabase: SupabaseService
    private let boot: BootCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var hasMigratedLegacyFlags = false
    private var lastUserId: UUID?
    private let pushIntentStore = PushIntentStore()
    private var isConsumingPushIntent = false
    private var lastConsumedIntentKey: String?
    private var lastConsumedNotificationId: UUID?

    private var loadingTask: Task<Void, Never>?
    private var loadingStartedAt: Date?
    private let minimumLoadingDuration: TimeInterval = 2.7

    init(
        supabase: SupabaseService = .shared,
        bootCoordinator: BootCoordinator = .shared
    ) {
        self.supabase = supabase
        self.boot = bootCoordinator
        bind()
        evaluatePhase(reason: "init")
    }

    // Computed properties for DEBUG HUD only - real gating uses serverProfile
    var hasCompletedProfile: Bool {
        supabase.serverProfile?.isComplete ?? false
    }

    var hasCompletedIntro: Bool {
        supabase.serverProfile?.onboardingCompleted ?? false
    }

    func markProfileComplete() {
        // Profile completion is now determined by server profile fields
        // This method triggers re-evaluation after profile update
        Task {
            await supabase.fetchProfile()
            await MainActor.run {
                loadingTask?.cancel()
                loadingTask = nil
                loadingStartedAt = nil
                evaluatePhase(reason: "profileComplete")
            }
        }
    }

    func requireProfileCapture(message: String?) {
        captureMessage = message
        updatePhase(.profileCapture, reason: "requested:\(message ?? "missing")")
    }
    
    func requirePhoneVerification() {
        updatePhase(.phoneVerification, reason: "requestedPhoneVerification")
    }

    func retryProfileLoad() async {
        profileErrorMessage = nil
        updatePhase(.loadingProfile, reason: "profileRetry")
        await supabase.fetchProfile()
    }

    func markIntroComplete() async -> Bool {
        do {
            try await supabase.markOnboardingComplete()
            AppLogger.logFlow("Onboarding marked complete on server")
            await MainActor.run {
                evaluatePhase(reason: "introComplete")
            }
            return true
        } catch {
            AppLogger.logProfile("Failed to mark onboarding complete: \(error.localizedDescription)", level: .error)
            // Retry once after a short delay
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await supabase.markOnboardingComplete()
                await MainActor.run {
                    evaluatePhase(reason: "introComplete_retry")
                }
                return true
            } catch {
                await supabase.fetchProfile()
                if supabase.serverProfile?.onboardingCompleted == true {
                    evaluatePhase(reason: "introComplete_profileAlreadyComplete")
                    return true
                }
                AppLogger.logProfile("Retry failed to mark onboarding complete: \(error.localizedDescription)", level: .fault)
                return false
            }
        }
    }

    func resetIntroForCurrentUser() {
        Task {
            do {
                try await supabase.updateProfileWithOnboarding(onboardingCompleted: false)
                AppLogger.logFlow("Onboarding reset on server")
                await MainActor.run {
                    evaluatePhase(reason: "introReset")
                }
            } catch {
                AppLogger.logProfile("Failed to reset onboarding: \(error.localizedDescription)", level: .error)
            }
        }
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
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userId in self?.handleUserChange(userId) }
            .store(in: &cancellables)

        supabase.$didCheckSession
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluatePhase(reason: "didCheckSession") }
            .store(in: &cancellables)
        
        supabase.$serverProfile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluatePhase(reason: "serverProfileChanged") }
            .store(in: &cancellables)
        
        supabase.$profileLoadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluatePhase(reason: "profileLoadStateChanged") }
            .store(in: &cancellables)

        boot.$stage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluatePhase(reason: "bootStage") }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .pushIntentStored)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let reason = notification.userInfo?["reason"] as? String ?? "pushStored"
                self?.consumePendingPushIfPossible(trigger: reason)
            }
            .store(in: &cancellables)
    }

    private func handleAuthPhaseChange() {
        if supabase.phase != .signedIn {
            loadingTask?.cancel()
            loadingTask = nil
            loadingStartedAt = nil
            profileErrorMessage = nil
        }
        evaluatePhase(reason: "authPhase")
    }

    private func handleUserChange(_ userId: UUID?) {
        if userId != lastUserId {
            // Different user — wipe any locally cached onboarding form data so
            // the next user doesn't see the previous user's pre-filled phone/name.
            if lastUserId != nil {
                OnboardingViewModel.clearStoredData()
            }
            lastUserId = userId
            hasMigratedLegacyFlags = false
            profileErrorMessage = nil
        }
        // Fetch profile when user changes
        if supabase.phase == .signedIn, userId != nil {
            Task {
                await supabase.fetchProfile()
                if !hasMigratedLegacyFlags {
                    await migrateLegacyFlagsToServer()
                    hasMigratedLegacyFlags = true
                }
            }
        }
        evaluatePhase(reason: "userChange")
    }

    private func evaluatePhase(reason: String) {
        AppLogger.logFlow("evaluatePhase(reason: \(reason))")
        
        // Step 1: Check session
        guard supabase.didCheckSession else {
            updatePhase(.launching, reason: reason)
            return
        }

        guard supabase.phase == .signedIn else {
            updatePhase(.auth, reason: reason)
            return
        }

        // Step 2: Check profile load state
        switch supabase.profileLoadState {
        case .idle:
            // Profile not yet fetched, trigger fetch
            updatePhase(.loadingProfile, reason: reason)
            Task {
                await supabase.fetchProfile()
                if !hasMigratedLegacyFlags {
                    await migrateLegacyFlagsToServer()
                    hasMigratedLegacyFlags = true
                }
            }
            return
            
        case .loading:
            // Use cached profile while a refresh is in progress to avoid flashing the loading gate
            if supabase.serverProfile == nil {
                updatePhase(.loadingProfile, reason: reason)
                return
            }
            break // Proceed with cached profile
            
        case .failed(let error):
            AppLogger.logProfile("Profile load failed, showing retry gate", level: .error)
            profileErrorMessage = error.localizedDescription
            updatePhase(.profileError, reason: "profileLoadFailed")
            return
            
        case .loaded:
            break // Continue to gate checks
        }

        // Step 3: Gate on server profile
        guard let profile = supabase.serverProfile else {
            updatePhase(.loadingProfile, reason: "noProfile")
            return
        }

        // Step 4: Check profile completeness
        guard isProfileComplete(profile) else {
            // Don't regress from phoneVerification back to profileCapture during a
            // background profile refresh — the user just submitted the form and the
            // server hasn't returned the updated profile yet.
            if phase == .phoneVerification { return }
            updatePhase(.profileCapture, reason: "profileIncomplete")
            return
        }

        // Step 5: If onboarding not complete, require phone verification first
        if profile.onboardingCompleted == false {
            if profile.requiresPhoneVerification {
                updatePhase(.phoneVerification, reason: "phoneUnverified")
                return
            }
            updatePhase(.introShowcase, reason: "onboardingIncomplete")
            return
        }

        // Step 6: All gates passed, proceed to main
        if phase == .main {
            return
        }

        enterLoadingFlow(reason: reason)
    }

    /// One-time migration from local UserDefaults flags to server profile
    private func migrateLegacyFlagsToServer() async {
        guard let userId = supabase.userId?.uuidString else { return }
        guard let profile = supabase.serverProfile else { return }
        
        // Check if server onboarding_completed is false but local flag indicates completion
        if !profile.onboardingCompleted {
            let legacyKeys = [
                "onboarding_completed_v2:\(userId)",
                "onboardingComplete",
                "didFinishShowcase"
            ]
            
            let hasLocalCompletion = legacyKeys.contains { key in
                UserDefaults.standard.bool(forKey: key)
            }
            
            if hasLocalCompletion {
                do {
                    try await supabase.markOnboardingComplete()
                    AppLogger.logProfile("Migrated local onboarding flag to server", level: .notice)
                } catch {
                    AppLogger.logProfile("Failed to migrate onboarding flag: \(error.localizedDescription)", level: .error)
                }
            }
        }
        
        // Delete all legacy keys
        let allLegacyKeys = [
            "onboarding_completed_v2:\(userId)",
            "appflow.profileCompletionByUser",
            "appflow.introCompletionByUser",
            "onboardingComplete",
            "didFinishShowcase"
        ]
        
        for key in allLegacyKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        AppLogger.logStorage("Deleted legacy UserDefaults keys")
    }

    private func isProfileComplete(_ profile: ProfileDTO) -> Bool {
        let provider = supabase.authProvider.lowercased()
        let requiresName = provider != "apple" && provider != "google"
        #if DEBUG
        DLog("[PROFILE_GATE] provider=\(provider) requiresName=\(requiresName) hasName=\(profile.hasName) hasPhone=\(profile.hasPhone) hasAvatar=\(profile.hasAvatar)")
        #endif
        let hasRequiredName = requiresName ? profile.hasName : true
        return hasRequiredName && profile.hasPhone && profile.hasAvatar
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

        if newPhase != .profileError {
            profileErrorMessage = nil
        }

        if newPhase != .profileCapture {
            captureMessage = nil
        }

        AppLogger.logFlow("state \(phase) → \(newPhase) (reason: \(reason))")
        phase = newPhase
        if newPhase == .main {
            consumePendingPushIfPossible(trigger: "phaseMain")
        }
    }

    func consumePendingPushIfPossible(trigger: String) {
        guard let intent = pushIntentStore.get() else { return }
        if Date() > intent.expiresAt {
            pushIntentStore.clear()
            DLog("[PUSH_INTENT] expired dropped")
            return
        }
        guard phase == .main else {
            DLog("[PUSH] blocked phase=\(phase)")
            DLog("[PUSH_GATE] blocked phase=\(phase)")
            return
        }
        DLog("[PUSH_GATE] allowed phase=\(phase)")
        guard isConsumingPushIntent == false else {
            DLog("[PUSH_INTENT] deferred reason=consuming_in_progress")
            return
        }

        let intentKey = [
            intent.notificationId?.uuidString ?? "n/a",
            intent.reservationId?.uuidString ?? "n/a",
            intent.postId?.uuidString ?? "n/a",
            intent.intentType ?? "n/a"
        ].joined(separator: "|")

        if let notificationId = intent.notificationId,
           notificationId == lastConsumedNotificationId {
            pushIntentStore.clear()
            DLog("[PUSH_INTENT] ignored reason=duplicate notificationId=\(notificationId.uuidString)")
            return
        }
        if intentKey == lastConsumedIntentKey {
            pushIntentStore.clear()
            DLog("[PUSH_INTENT] ignored reason=duplicate intent=\(intentKey)")
            return
        }

        isConsumingPushIntent = true
        pushIntentStore.clear()
        lastConsumedIntentKey = intentKey
        lastConsumedNotificationId = intent.notificationId
        DLog("[PUSH] consumed trigger=\(trigger) \(intent.debugSummary)")
        DLog("[PUSH_GATE] consumed trigger=\(trigger) \(intent.debugSummary)")

        Task { [weak self] in
            PushIntentRouter.shared.refreshAfterPush(intent: intent, reason: "consume")
            await PushIntentRouter.shared.route(intent: intent)
            await MainActor.run {
                self?.isConsumingPushIntent = false
            }
        }
    }
}
