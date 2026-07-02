//
//  SwipeDeckView.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//

import SwiftUI
import MapKit
import Combine
import UIKit
import SmartlookAnalytics


private func postOptimisticReservationInsert(_ row: ReservationRow) {
    NotificationCenter.default.post(name: .reservationOptimisticInsert, object: row)
}

private func postOptimisticReservationRemove(_ reservationId: String) {
    NotificationCenter.default.post(name: .reservationOptimisticRemove, object: reservationId)
}


private let VERBOSE_LOGS = true

@inline(__always)
private func dbg(_ tag: String, _ items: Any...) {
#if DEBUG
    guard VERBOSE_LOGS else { return }
    let message = items.map { "\($0)" }.joined(separator: " ")
    DLog("[\(tag)] \(message)")
#endif
}

#if DEBUG
private let feedDebugISOFormatter: ISO8601DateFormatter = {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [
        .withFullDate,
        .withTime,
        .withTimeZone,
        .withFractionalSeconds,
        .withColonSeparatorInTime
    ]
    return fmt
}()

struct FeedDistanceDebugEntry: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D?
    let coordinateSource: String
    let serverDistanceKm: Double?
    let localDistanceKm: Double?
    let mode: String
}

struct FeedDistanceDebugContext: Identifiable {
    let id = UUID()
    let debugId: String
    let myLocation: CLLocation
    let requestRadiusKm: Double
    let locationSource: String
    let authorizationStatus: CLAuthorizationStatus
    let accuracyAuthorization: CLAccuracyAuthorization
    let preciseEnabled: Bool
    var entries: [FeedDistanceDebugEntry] = []
}

private struct FeedDebugContextKey: EnvironmentKey {
    static let defaultValue: FeedDistanceDebugContext? = nil
}

extension EnvironmentValues {
    var feedDebugContext: FeedDistanceDebugContext? {
        get { self[FeedDebugContextKey.self] }
        set { self[FeedDebugContextKey.self] = newValue }
    }
}
#endif

// MARK: - Hidden Posts Store (24h dismissed, 2h reserved)
class HiddenPostsStore {
    static let shared = HiddenPostsStore()
    private let dismissedKey = "feed.dismissed"
    private let reservedKey = "feed.reserved"
    private let dismissedTTL: TimeInterval = 24 * 3600 
    private let reservedTTL: TimeInterval = 2 * 3600  
    
    func saveDismissed(_ ids: Set<String>) {
        save(ids, key: dismissedKey, ttl: dismissedTTL)
    }

    func saveReserved(_ ids: Set<String>) {
        save(ids, key: reservedKey, ttl: reservedTTL)
    }

    /// Keep each id's ORIGINAL hide timestamp — re-saving the set must not
    /// reset the TTL clock, or hidden posts would never come back. IDs missing
    /// from `ids` were explicitly unhidden and are dropped.
    private func save(_ ids: Set<String>, key: String, ttl: TimeInterval) {
        let existing = (UserDefaults.standard.dictionary(forKey: key) as? [String: Date]) ?? [:]
        let now = Date()
        var dict: [String: Date] = [:]
        for id in ids {
            if let original = existing[id], now.timeIntervalSince(original) < ttl {
                dict[id] = original
            } else {
                dict[id] = now
            }
        }
        UserDefaults.standard.set(dict, forKey: key)
    }
    
    func loadDismissed() -> Set<String> {
        guard let dict = UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: Date] else {
            return []
        }
        return reapExpired(dict, ttl: dismissedTTL)
    }
    
    func loadReserved() -> Set<String> {
        guard let dict = UserDefaults.standard.dictionary(forKey: reservedKey) as? [String: Date] else {
            return []
        }
        return reapExpired(dict, ttl: reservedTTL)
    }
    
    private func reapExpired(_ dict: [String: Date], ttl: TimeInterval) -> Set<String> {
        let now = Date()
        let valid = dict.filter { now.timeIntervalSince($0.value) < ttl }
        return Set(valid.keys)
    }
    
    // Helper to check if a post ID is hidden (checks both sets with their respective TTLs)
    func isHidden(_ id: String) -> Bool {
        let dismissed = loadDismissed()
        let reserved = loadReserved()
        return dismissed.contains(id) || reserved.contains(id)
    }
}

private struct ViewSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let candidate = nextValue()
        if candidate.width > 0 && candidate.height > 0 {
            value = candidate
        }
    }
}

private struct SizeObserverModifier: ViewModifier {
    let onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ViewSizePreferenceKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(ViewSizePreferenceKey.self) { newSize in
                Task { @MainActor in
                    onChange(newSize)
                }
            }
    }
}

private extension View {
    func onSizeChange(_ perform: @escaping (CGSize) -> Void) -> some View {
        modifier(SizeObserverModifier(onChange: perform))
    }
}

private extension CGSize {
    func validOrDefault(fallback: CGSize) -> CGSize {
        guard width > 0 && height > 0 else { return fallback }
        return self
    }
}

struct SwipeDeckView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject private var ck: CKTrashService
    @EnvironmentObject private var svc: SupabaseService
    @EnvironmentObject private var draftStore: UploadDraftStore
    @EnvironmentObject private var feedVM: FeedViewModel

    // API Service for feed data
    @State private var api: ApiService?
    @State private var didKickOff = false
    @State private var lastServerPayload: Set<String> = [] // Track server IDs for stray detection

    // Deck state management - single source of truth
    @StateObject private var deckState = DeckState()
    @StateObject private var safetyFeedback = SafetySuccessFeedback.shared
    
    // Hidden posts tracking with 24h TTL
    @State private var dismissedIds: Set<String> = []
    @State private var reservedIds: Set<String> = []

    // Loading and error states
    @State private var isLoading = false
    @State private var isReserving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showAuthError = false
    @State private var successMessage: String?
    @State private var showSuccess = false
    
    // Single-flight tracking
    @State private var inFlightCoordKey: String?
    @State private var authStatusAtLastFetch: Int?
    @State private var lastGateFix: LocationFixResult?
    @State private var pendingBetterFixTask: Task<Void, Never>?
    @State private var lastFeedFetchAt: Date?

#if DEBUG
    @State private var feedDebugContext: FeedDistanceDebugContext?
#endif

    // Single source of truth for navigation state
    fileprivate enum NavigationState: Equatable {
        case feed
        case map
        
        var isFeed: Bool { self == .feed }
        var isMap: Bool { self == .map }
    }
    @State private var navState: NavigationState = .feed
    @State private var navStateWriteCount = 0 // Debug: detect thrashing
    // Removed direct boolean in favor of navState-derived binding

    // reserve sheet (two-step)
    @State private var showReserveSheet = false
    @State private var sheetMode: ReserveSheet.Mode = .prompt
    
    // Camera and upload flow - using draft store
    @State private var showUploadForm = false
    @State private var showCamera = false

    // Leaderboard page pushed from the top-left pill or a push notification
    @State private var showLeaderboard = false

    // Convert Post objects to visible feed items
    private var visible: [Post] {
        return feedVM.items.filter { post in
            !dismissedIds.contains(post.id) && !reservedIds.contains(post.id)
        }
    }

#if DEBUG
    private var activePostId: String? {
        if let post = deckState.activeCard as? Post {
            return post.id
        }
        return nil
    }
#endif

    // MARK: - Helpers
    private func markReserved(postId: String) {
        // Persist into 2h TTL set and remove card from deck
        reservedIds.insert(postId)
        HiddenPostsStore.shared.saveReserved(reservedIds)
        deckState.completeCardTransition()
    }

    private func trackReservationMade(post: Post) {
        guard ConsentManager.shared.analytics == .provided else { return }

        let userId = svc.userId?.uuidString ?? "unknown"
        let properties = Properties()
            .setProperty("postId", to: post.id)
            .setProperty("mode", to: post.mode.rawValue)
            .setProperty("userId", to: userId)

        Smartlook.instance.track(event: "ReservationMade", properties: properties)

        #if DEBUG
        DLog("[ANALYTICS] 📊 ReservationMade event tracked - postId: \(post.id)")
        #endif
    }

    // Use global helper on service: svc.hasAuthToken

    var body: some View {
        baseView
            .overlay { errorOverlay }
            .overlay { successOverlay }
            .overlay {
                if let msg = safetyFeedback.pending {
                    SafetySuccessCard(message: msg) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            safetyFeedback.clear()
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: safetyFeedback.pending != nil)
                }
            }
#if DEBUG
            .overlay(alignment: .topLeading) {
                if UserDefaults.standard.bool(forKey: "debug.distanceHUD"),
                   let context = feedDebugContext {
                    FeedDebugOverlayView(context: context, activePostId: activePostId)
                }
            }
#endif
            .fullScreenCover(isPresented: $showCamera) {
                CameraScreen(
                    onCaptured: { image in
                        presentUploadImmediately(with: image)
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCamera = false
                        }
                    }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showUploadForm, onDismiss: { handleUploadFormDismiss() }) {
                uploadFormView
            }
            .fullScreenCover(
                isPresented: Binding<Bool>(
                    get: { navState == .map },
                    set: { newValue in
                        Task { @MainActor in
                            if newValue {
                                animateNavState(to: .map)
                            } else {
                                animateNavState(to: .feed)
                            }
                        }
                    }
                ),
                onDismiss: handleMapDismiss
            ) {
                feedMapView
            }
    }
    
    private var baseView: some View {
        baseViewWithModifiers
    }

    private var baseViewWithModifiers: some View {
        navigationStackView
            .toolbar { toolbarContent }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { handleViewAppear() }
            .task {
                if api == nil { api = ApiService(supabaseService: svc) }
                await maybeLoadFeed()
            }
            .onChange(of: svc.isAuthenticated) { _, _ in
                Task { await maybeLoadFeed() }
            }
            .onChange(of: svc.session) { _, _ in
                Task { await maybeLoadFeed() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LocationAuthorizationChanged"))) { _ in
                handleLocationAuthChange()
            }
    }

    private var navigationStackView: some View {
        NavigationStack {
            contentView
                .navigationDestination(isPresented: $showLeaderboard) {
                    LeaderboardView()
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLeaderboard)) { _ in
            showLeaderboard = true
        }
        .onChange(of: navState) { oldValue, newValue in
            handleNavigationChange(from: oldValue, to: newValue)
        }
        .onChange(of: feedVM.items) { _, newItems in
            // Update deck when FeedViewModel finishes loading
            let visiblePosts = newItems.filter { post in
                !dismissedIds.contains(post.id) && !reservedIds.contains(post.id)
            }
            deckState.filterItems(visiblePosts)
        }
        .onChange(of: feedVM.isLoading) { _, loading in
            // Sync loading state with FeedViewModel, but never replace a
            // populated deck with a full-screen spinner — background refreshes
            // (post-reserve, post-upload) should be invisible.
            isLoading = loading && feedVM.items.isEmpty
        }
    }

    @MainActor
    private func handleMapDismiss() {
        DLog("🔵 [NAV] map_dismissed callback")
        dbg("NAV", "map_dismissed")
        // Animate pill immediately as map starts dismissing
        if navState.isMap {
            animateNavStateToFeed()
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            headerSegment
            
            GeometryReader { _ in
                mainContentArea
            }
        }
    }

    private var headerSegment: some View {
        GlassSegmented(selection: $navState)
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .zIndex(1000)
    }

    private func handleLocationAuthChange() {
        Task {
            let currentAuth = LocationService.shared.mgr.authorizationStatus.rawValue
            let lastAuth = authStatusAtLastFetch ?? -1
            if lastAuth != currentAuth && (currentAuth == 3 || currentAuth == 4) {
                authStatusAtLastFetch = Int(currentAuth)
                let now = Date()
                // The recent-fetch debounce only applies when we actually have
                // content — with an empty feed (first run, just granted
                // permission) this fetch IS the initial load.
                if let lastFetch = lastFeedFetchAt,
                   now.timeIntervalSince(lastFetch) < 1.5,
                   !feedVM.items.isEmpty {
                    #if DEBUG
                    DLog("[FEED gate] auth change ignored (recent fetch <1.5s)")
                    #endif
                    return
                }
                #if DEBUG
                DLog("[FEED gate] auth changed to authorized → refetch")
                #endif
                await loadFeedWithOneShotLocation(force: true)
            } else if currentAuth == 2 {
                // Denied: stop the first-run loading state so the empty-state
                // CTA shows instead of an endless spinner.
                await MainActor.run { isLoading = false }
            }
        }
    }

    private func handleNavigationChange(from oldValue: NavigationState, to newValue: NavigationState) {
        navStateWriteCount += 1
        let writeCount = navStateWriteCount
        
        DLog("🟡 [NAV] state_changed from=\(oldValue) to=\(newValue) writes=\(writeCount)")
        dbg("NAV", "state_changed from=\(oldValue) to=\(newValue) writes=\(writeCount)")
        
        // Detect thrashing: if we get >2 writes in 200ms, log warning
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if navStateWriteCount > writeCount + 1 {
                DLog("⚠️ [NAV] state_thrash detected writes=\(navStateWriteCount) in_200ms")
                dbg("NAV", "⚠️ state_thrash detected writes=\(navStateWriteCount) in_200ms")
            }
        }
        
        // Synchronize presentation state (navState is the single source of truth now).
        // Keep logs, avoid secondary boolean to prevent conflicts.
        switch newValue {
        case .feed:
            DLog("🔴 [NAV] showing_feed isPresented=false (derived)")
            dbg("NAV", "showing_feed (derived)")
        case .map:
            DLog("🟢 [NAV] presenting_map isPresented=true (derived)")
            dbg("NAV", "presenting_map (derived)")
        }
    }

    @MainActor
    private func animateNavState(to target: NavigationState) {
        guard navState != target else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            navState = target
        }
    }

    @MainActor
    private func animateNavStateToFeed() {
        animateNavState(to: .feed)
    }

    // MARK: - Fix: Break up the complex conditional into a separate view
    private var mainContentArea: some View {
        ZStack {
            mainContentConditional
            reservationSheetView
        }
    }

    private var mainContentConditional: some View {
        Group {
            if isLoading {
                loadingView
            } else if showAuthError {
                authErrorView
            } else if showError {
                errorView
            } else if visible.isEmpty {
                emptyStateView
            } else {
                feedContentView
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(AppTheme.ColorToken.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text(errorMessage ?? "Something went wrong")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
            
            Button("Try Again") {
                Task {
                    await fetchFeedBridge()
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(AppTheme.ColorToken.primary)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
    
    private var authErrorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundColor(AppTheme.ColorToken.danger)
            
            Text(errorMessage ?? "Can't reach the server right now. Please try again.")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
            
            Button("Sign In Again") {
                Task {
                    await svc.signOut()
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(AppTheme.ColorToken.primary)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var emptyStateView: some View {
        EmptyFeedCTA(
            refresh: {
                Task {
                    await fetchFeedBridge()
                }
            },
            makePost: { handleMakePost() }
        )
    }

    private var feedContentView: some View {
        VStack(spacing: 0) {
            Group {
#if DEBUG
                DeckStack(
                    deckState: deckState,
                    router: router,
                    isReserving: isReserving,
                    onPass: { Task { await handlePassAction() } },
                    onReserve: { Task { await handleReserveAction() } }
                )
                .environment(\.feedDebugContext, feedDebugContext)
#else
                DeckStack(
                    deckState: deckState,
                    router: router,
                    isReserving: isReserving,
                    onPass: { Task { await handlePassAction() } },
                    onReserve: { Task { await handleReserveAction() } }
                )
#endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.top, 18)
            .refreshable {
                await fetchFeedBridge()
            }
            
            ActionBar(
                deckState: deckState,
                onPass: { Task { await handlePassAction() } },
                onReserve: { Task { await handleReserveAction() } }
            )
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var reservationSheetView: some View {
        if showReserveSheet {
            ReserveSheet(
                mode: sheetMode,
                confirm: { Task { await handleReservationConfirm() } },
                openMaps: { handleOpenMaps() },
                close: { handleReservationClose() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Toolbar and Overlays

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            LeaderboardPill(isOpen: $showLeaderboard)
        }
        ToolbarItem(placement: .principal) {
            Image("SwoopyLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .accessibilityHidden(true)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if let errorMessage = deckState.errorMessage {
            VStack {
                Spacer()
                SwoopyToast(message: errorMessage, style: .error)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: deckState.errorMessage)
        }
    }

    @ViewBuilder
    private var successOverlay: some View {
        if showSuccess, let successMessage {
            VStack {
                Spacer()
                SwoopyToast(message: successMessage, style: .success)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSuccess)
        }
    }

    // MARK: - Full Screen Covers

    private var uploadFormView: some View {
        NavigationStack {
            UploadFindView()
                .environmentObject(svc)
                .environmentObject(draftStore)
        }
    }

    private var feedMapView: some View {
        FeedMapScreen(onBack: animateNavStateToFeed)
            .environmentObject(svc)
            .environmentObject(feedVM)
            .ignoresSafeArea()
    }

    // MARK: - Action Handlers

    private func handleViewAppear() {
        // View appeared - no camera service initialization needed
    }

    private func handleUploadFormDismiss() {
        navState = .feed
        Task { await fetchFeedBridge() }
    }

    @MainActor private func handleReservationConfirm() async {
        guard let post = deckState.activeCard as? Post else { return }
        guard let api else { return }

        let requestId = UUID().uuidString
        let tempId = "optimistic-\(requestId)"
        let placeholderRow = ReservationRow(optimisticFrom: post, reservationId: tempId)
        postOptimisticReservationInsert(placeholderRow)
        var didRemovePlaceholder = false

        do {
            let reservationId = try await fetchWithRetry(svc: svc) {
                try await api.reservePost(post.id, requestId: requestId)
            }

            if !didRemovePlaceholder {
                postOptimisticReservationRemove(tempId)
                didRemovePlaceholder = true
            }

            let optimisticRow = ReservationRow(optimisticFrom: post, reservationId: reservationId)
            postOptimisticReservationInsert(optimisticRow)
            NotificationCenter.default.post(name: .refreshReservations, object: reservationId)

            reservedIds.insert(post.id)
            HiddenPostsStore.shared.saveReserved(reservedIds)
            trackReservationMade(post: post)

            withAnimation(.easeOut(duration: 0.18)) {
                sheetMode = .info
            }
            Task { await fetchFeedBridge() }
        } catch {
            if !didRemovePlaceholder {
                postOptimisticReservationRemove(tempId)
            }
        }
    }

    private func handleOpenMaps() {
        guard let post = deckState.activeCard as? Post,
              let coord = post.exactCoordinate ?? post.approxCoordinate else { return }
        let mi = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        mi.name = post.title
        mi.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }

    private func handleReservationClose() {
        withAnimation(.easeOut(duration: 0.18)) {
            showReserveSheet = false
            sheetMode = .prompt
        }
    }

    // MARK: - Action Handlers
    
    @MainActor
    private func handlePassAction() async {
        guard let post = deckState.activeCard as? Post else { return }
        guard !isReserving else { return } // Prevent action during reserve
        
        dbg("ACTION", "pass \(post.id.prefix(8))")
        Haptics.play(.tabReselect) // light haptic for pass/swipe-left
        
        await deckState.triggerPass()
        
        // Pass: add to dismissed set with 24h TTL
        dismissedIds.insert(post.id)
        HiddenPostsStore.shared.saveDismissed(dismissedIds)
    }

    @MainActor
    private func handleReserveAction() async {
        guard let post = deckState.activeCard as? Post else { return }
        guard let api else { return }
        guard !isReserving else { return } // Prevent double-tap
        
        #if DEBUG || RESERVATIONS_DIAGNOSTICS
        let corr = Diag.generateCorrelationId()
        Diag.log(.action, "reserve.tap", fields: [
            "corr": corr,
            "postId": post.id,
            "mode": post.mode.rawValue,
            "condition": post.condition.rawValue
        ])
        
        Diag.log(.action, "reserve.preconditions", fields: [
            "corr": corr,
            "isReserving": isReserving,
            "onMain": Thread.isMainThread
        ])
        #endif
        
        dbg("ACTION", "reserve start \(post.id.prefix(8))")

        // Haptic feedback for primary action (reserve button tap)
        Haptics.play(.primaryAction)

        // Optimistic UI: advance the deck and confirm immediately; the network
        // call runs in the background and rolls back on failure. Blocking the
        // card animation on the round-trip is what made swipes feel frozen.
        isReserving = true

        let requestId = UUID().uuidString
        let tempId = "optimistic-\(requestId)"
        let placeholderRow = ReservationRow(optimisticFrom: post, reservationId: tempId)
        postOptimisticReservationInsert(placeholderRow)

        await deckState.triggerReserve()
        markReserved(postId: post.id)
        isReserving = false

        successMessage = "Reserved for 2 hours"
        showSuccess = true
        Haptics.play(.success)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSuccess = false
        }

        Task { @MainActor in
            do {
                let reservationId = try await fetchWithRetry(svc: svc) {
                    #if DEBUG || RESERVATIONS_DIAGNOSTICS
                    try await api.reservePost(post.id, requestId: requestId, corr: corr)
                    #else
                    try await api.reservePost(post.id, requestId: requestId)
                    #endif
                }

                dbg("ACTION", "reserve ok \(reservationId.prefix(8))")

                #if DEBUG || RESERVATIONS_DIAGNOSTICS
                Diag.log(.store, "reserve.success", fields: [
                    "corr": corr,
                    "reservationId": reservationId,
                    "postId": post.id
                ])
                Diag.assertMainThread(corr: corr, context: "reserve.state_update")
                #endif

                postOptimisticReservationRemove(tempId)
                let optimisticRow = ReservationRow(optimisticFrom: post, reservationId: reservationId)
                postOptimisticReservationInsert(optimisticRow)
                NotificationCenter.default.post(name: .refreshReservations, object: reservationId)

                // Analytics: ReservationMade (consent-gated)
                trackReservationMade(post: post)
            } catch {
                #if DEBUG || RESERVATIONS_DIAGNOSTICS
                Diag.log(.error, "reserve.failed", fields: [
                    "corr": corr,
                    "errorType": error is ReserveError ? "ReserveError" : "unknown",
                    "error": error.localizedDescription
                ])
                if case ReserveError.unauthorized = error {
                    Diag.logAuthStateChange(corr: corr, event: "auth.unauthorized", reason: "reserve failed with 401")
                }
                #endif
                rollbackOptimisticReserve(post: post, tempId: tempId, error: error)
            }
        }
    }

    /// Undo the optimistic reserve: drop the placeholder reservation and, when
    /// the item is still available (network/server hiccup), put the card back
    /// on top of the deck so the user can retry.
    @MainActor
    private func rollbackOptimisticReserve(post: Post, tempId: String, error: Error) {
        dbg("ACTION", "reserve fail \(error.localizedDescription)")

        postOptimisticReservationRemove(tempId)
        showSuccess = false
        Haptics.play(.error)

        let message: String
        var cardStillAvailable = false

        switch error as? ReserveError {
        case .ownPost:
            message = "You can't reserve your own post"
        case .alreadyReserved:
            message = "Already reserved by someone else"
        case .expired:
            message = "This post has expired"
        case .notFound:
            message = "Post not found"
        case .unauthorized:
            errorMessage = "Please sign in again to continue."
            showAuthError = true
            return
        case .backend(let msg):
            message = msg
            cardStillAvailable = true
        case .network:
            message = "Can't reach the server right now. Please try again."
            cardStillAvailable = true
        case nil:
            message = "Couldn't reserve this item. Please try again."
            cardStillAvailable = true
        }

        if cardStillAvailable {
            reservedIds.remove(post.id)
            HiddenPostsStore.shared.saveReserved(reservedIds)
            deckState.filterItems(visible)
            if let idx = (deckState.items as? [Post])?.firstIndex(where: { $0.id == post.id }) {
                deckState.activeIndex = idx
            }
        }

        deckState.errorMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if deckState.errorMessage == message {
                deckState.errorMessage = nil
            }
        }
    }
    
    private func handleMakePost() {
        showCamera = true
    }
    
    private func presentUploadImmediately(with image: UIImage) {
        draftStore.insertPrimary(image)
        
        // Dismiss camera and show upload in same transaction
// Transition directly to upload form without visible camera drop
CATransaction.begin()
CATransaction.setDisableActions(true)
withAnimation(.easeInOut(duration: 0.2)) {
    showCamera = false
    showUploadForm = true
}
CATransaction.commit()  
    }

    // MARK: - Feed Management

    @MainActor
    private func fetchFeed(using location: CLLocation) async {
        guard let api else { return }
        
        let coord = location.coordinate
        
        // Gate: validate coordinate is usable
        guard LocationReadiness.isUsable(coord) else {
            #if DEBUG
            DLog("[FEED gate] skip (reason=no-usable-location lat=\(coord.latitude) lng=\(coord.longitude))")
            #endif
            isLoading = false
            return
        }
        
        // Single-flight: check if already fetching this coordinate
        let coordKey = LocationReadiness.cacheKey(coord)
        if inFlightCoordKey == coordKey {
            #if DEBUG
            DLog("[FEED gate] skip (reason=already-in-flight key=\(coordKey))")
            #endif
            return
        }
        
        inFlightCoordKey = coordKey
        defer { inFlightCoordKey = nil }

        // This function now contains the core logic of the old `fetchFeedBridge`
        dismissedIds = HiddenPostsStore.shared.loadDismissed()
        reservedIds = HiddenPostsStore.shared.loadReserved()

        let userLocation = location.coordinate
        
        // Log coordinate source
        let age = max(0, Date().timeIntervalSince(location.timestamp))
        #if DEBUG
        let locationSource = age < 5.0 ? "fresh" : "cached"
        #endif
        if age < 5.0 {
            #if DEBUG
            DLog("[FEED gate] using fresh coord=(\(userLocation.latitude),\(userLocation.longitude)) hdop=\(location.horizontalAccuracy)")
            #endif
        } else {
            #if DEBUG
            DLog("[FEED gate] using cached coord=(\(userLocation.latitude),\(userLocation.longitude)) age=\(String(format: "%.1f", age))s")
            #endif
        }
        
        dbg("FEED", "request lat=\(userLocation.latitude) lng=\(userLocation.longitude) radius=10 limit=30")

        #if DEBUG
        feedDebugContext = nil
        #endif

        do {
            let q = FeedQuery(
                lng: userLocation.longitude,
                lat: userLocation.latitude,
                radiusKm: 10.0,
                category: nil,
                mode: nil,
                limit: 30
            )

            #if DEBUG
            let generatedDebugId = UUID().uuidString.lowercased()
            let authSnapshot = LocationService.shared.debugAuthorizationSnapshot()
            var localDebugContext = FeedDistanceDebugContext(
                debugId: generatedDebugId,
                myLocation: location,
                requestRadiusKm: q.radiusKm,
                locationSource: locationSource,
                authorizationStatus: authSnapshot.managerStatus,
                accuracyAuthorization: authSnapshot.accuracyAuthorization,
                preciseEnabled: authSnapshot.preciseEnabled
            )
            feedDebugContext = localDebugContext
            let isoTimestamp = feedDebugISOFormatter.string(from: location.timestamp)
            let accuracyMeters = Int(location.horizontalAccuracy.rounded())
            DLog("[DISTANCE REQ] debugId=\(generatedDebugId) my=(\(String(format: "%.5f", userLocation.latitude)),\(String(format: "%.5f", userLocation.longitude)) acc=\(accuracyMeters)m @\(isoTimestamp)) radius=\(String(format: "%.1f", q.radiusKm)) source=\(locationSource) auth=\(authSnapshot.managerStatus.rawValue) precise=\(authSnapshot.preciseEnabled ? "on" : "off"))")
            #endif

            let fetchedPosts = try await fetchWithRetry(svc: svc) {
                #if DEBUG
                try await api.getFeed(query: q, debugContext: FeedDebugContext(debugId: generatedDebugId))
                #else
                try await api.getFeed(query: q)
                #endif
            }

            dbg("FEED", "response count=\(fetchedPosts.count)")

            let myId = (svc.userId?.uuidString ?? "").lowercased()
            let filtered = fetchedPosts.filter { post in
                let ownerIdMatch = post.ownerId.lowercased() != myId
                let ownerMatch = post.owner?.id.lowercased() != myId
                return ownerIdMatch && ownerMatch
            }

            dbg("FEED", "self-filter removed=\(fetchedPosts.count - filtered.count)")

            lastServerPayload = Set(filtered.map { $0.id })
            feedVM.setBaseItems(filtered)
            let visiblePosts = visible
            deckState.updateItems(visiblePosts)

            #if DEBUG
            do {
                var context = localDebugContext
                let userCLLocation = location
                var entries: [FeedDistanceDebugEntry] = []
                let isoTs = feedDebugISOFormatter.string(from: userCLLocation.timestamp)
                let myCoordString = "\(String(format: "%.5f", userCLLocation.coordinate.latitude)),\(String(format: "%.5f", userCLLocation.coordinate.longitude))"
                let accuracyString = Int(userCLLocation.horizontalAccuracy.rounded())
                let coordinateForPost: (Post) -> (CLLocationCoordinate2D?, String) = { post in
                    if let exact = post.exactCoordinate {
                        return (exact, "exact")
                    }
                    if let approx = post.approxCoordinate {
                        return (approx, "approx")
                    }
                    return (nil, "none")
                }

                for post in visiblePosts {
                    let (postCoord, coordSource) = coordinateForPost(post)
                    let localDistanceKm: Double? = {
                        guard let postCoord else { return nil }
                        let postLocation = CLLocation(latitude: postCoord.latitude, longitude: postCoord.longitude)
                        return postLocation.distance(from: userCLLocation) / 1000.0
                    }()
                    let entry = FeedDistanceDebugEntry(
                        id: post.id,
                        coordinate: postCoord,
                        coordinateSource: coordSource,
                        serverDistanceKm: post.distance,
                        localDistanceKm: localDistanceKm,
                        mode: post.mode.rawValue
                    )
                    entries.append(entry)

                    let coordString = postCoord.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "n/a"
                    let serverString = post.distance.map { String(format: "%.3f", $0) } ?? "nil"
                    let localString = localDistanceKm.map { String(format: "%.3f", $0) } ?? "nil"
                    let source = post.distance != nil ? "server" : "local"
                    DLog("[DISTANCE TRACE] debugId=\(generatedDebugId) postId=\(post.id) coord=\(coordString) coordSource=\(coordSource) server=\(serverString)km ui=\(localString)km source=\(source)")
                }

                context.entries = entries
                feedDebugContext = context

                if let first = entries.first {
                    let coordString = first.coordinate.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "n/a"
                    let serverString = first.serverDistanceKm.map { String(format: "%.2f", $0) } ?? "nil"
                    let localString = first.localDistanceKm.map { String(format: "%.2f", $0) } ?? "nil"
                    let source = first.serverDistanceKm != nil ? "server" : "local"
                    DLog("DISTANCE-AUDIT debugId=\(generatedDebugId) my=(\(myCoordString) acc=\(accuracyString)m @\(isoTs)) post=\(coordString) server=\(serverString)km ui=\(localString)km source=\(source)")
                } else {
                    DLog("DISTANCE-AUDIT debugId=\(generatedDebugId) my=(\(myCoordString) acc=\(accuracyString)m @\(isoTs)) post=none server=nil ui=nil source=none")
                }
            }
            #endif

            isLoading = false
        } catch {
            dbg("FEED", "error=\(error.localizedDescription)")
            feedVM.items = []
            deckState.updateItems([])
            isLoading = false

            #if DEBUG
            let debugIdMessage: String
            if let context = feedDebugContext {
                debugIdMessage = context.debugId
            } else {
                debugIdMessage = "pending"
            }
            DLog("[DISTANCE REQ] debugId=\(debugIdMessage) error=\(error.localizedDescription)")
            feedDebugContext = nil
            #endif

            if error is AuthError || error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Please sign in again to continue."
                showAuthError = true
            } else {
                errorMessage = "Can't load items right now. Please try again."
                showError = true
            }
        }
    }

    @MainActor
    private func loadFeedWithOneShotLocation(force: Bool = false) async {
        guard !feedVM.isLoading else { return } // Don't re-fetch if FeedViewModel is already loading
        showError = false
        showAuthError = false

        // First run: request authorization so the permission dialog appears.
        // A location fix can't arrive until the user answers — firstFix would
        // just time out and we'd fetch with a garbage coordinate. Show loading
        // and let handleLocationAuthChange kick off the real fetch (or clear
        // loading on denial) once the user responds.
        if LocationService.shared.mgr.authorizationStatus == .notDetermined {
            isLoading = true
            LocationService.shared.requestWhenInUseIfNeeded()
            return
        }

        do {
            let fix = try await LocationService.shared.firstFix(preferFreshWithin: 1_000)
            let coord = fix.coordinate
            guard LocationReadiness.isUsable(coord) else {
                #if DEBUG
                DLog("[FEED gate] skip (reason=unusable coord lat=\(coord.latitude) lng=\(coord.longitude))")
                #endif
                return
            }
            #if DEBUG
            let sourceLabel = fix.source == .fresh ? "fresh" : "cached"
            DLog("[FEED gate] strategy=preferFreshWithin(1000ms) result=\(sourceLabel) age=\(String(format: "%.1f", fix.age))s hdop=\(String(format: "%.1f", fix.hdop))m")
            #endif
            if force {
                feedVM.forceRefresh(currentLocation: coord)
            } else {
                feedVM.refresh(currentLocation: coord)
            }
            lastFeedFetchAt = Date()
            lastGateFix = fix
            authStatusAtLastFetch = Int(LocationService.shared.mgr.authorizationStatus.rawValue)
            if fix.source == .cached {
                scheduleMaterialImprovementCheck(baseline: fix)
            } else {
                pendingBetterFixTask?.cancel()
                pendingBetterFixTask = nil
            }
        } catch {
            #if DEBUG
            DLog("[FEED gate] location unavailable (error=\(error.localizedDescription))")
            #endif
            // Only fetch with a real cached coordinate. The old hardcoded
            // (1.0, 1.0) fallback queried the middle of the Atlantic, returned
            // zero posts, and blocked the permission-grant refetch while in
            // flight — the "first load shows nothing" bug.
            if let fallback = LocationService.shared.lastKnownCoordinate,
               LocationReadiness.isUsable(fallback) {
                if force {
                    feedVM.forceRefresh(currentLocation: fallback)
                } else {
                    feedVM.refresh(currentLocation: fallback)
                }
            } else {
                isLoading = false
            }
        }
    }

    // MARK: - Helper Functions

    @MainActor
    private func fetchFeedBridge() async {
        // User-initiated (pull-to-refresh, retry, post-upload, post-reserve):
        // always hit the network, bypassing the same-location skip guard.
        await loadFeedWithOneShotLocation(force: true)
    }

    private func scheduleMaterialImprovementCheck(baseline: LocationFixResult) {
        pendingBetterFixTask?.cancel()
        pendingBetterFixTask = Task {
            defer { pendingBetterFixTask = nil }
            do {
                let freshLocation = try await LocationService.shared.firstFix(timeout: 5.0, forceFresh: true)
                let candidate = LocationFixResult(location: freshLocation, source: .fresh)
                await MainActor.run {
                    if let reason = materialImprovementReason(new: candidate, previous: baseline) {
                        #if DEBUG
                        DLog("[FEED gate] refetch reason=\(reason.reason) delta=\(String(format: "%.1f", reason.delta))")
                        #endif
                        feedVM.refresh(currentLocation: candidate.coordinate)
                        lastFeedFetchAt = Date()
                        lastGateFix = candidate
                    } else {
                        #if DEBUG
                        DLog("[FEED gate] refetch suppressed (no material improvement)")
                        #endif
                    }
                }
            } catch {
                // Ignore - no follow-up needed
            }
        }
    }
    
    private func materialImprovementReason(new: LocationFixResult, previous: LocationFixResult) -> (reason: String, delta: Double)? {
        let oldLocation = previous.location
        let newLocation = new.location
        let distanceDelta = oldLocation.distance(from: newLocation)
        if distanceDelta >= 150 {
            return ("distance", distanceDelta)
        }
        let hdopImprovement = previous.hdop - new.hdop
        if hdopImprovement >= 40 {
            return ("hdop", hdopImprovement)
        }
        if previous.age >= 600 && new.age <= 30 {
            return ("age", previous.age)
        }
        return nil
    }

    @MainActor
    private func maybeLoadFeed() async {
        if api == nil { api = ApiService(supabaseService: svc) }
        guard svc.hasAuthToken, didKickOff == false else { return }
        guard !didKickOff else { return }
        didKickOff = true
        // Restore the TTL'd hidden sets — without this, posts dismissed or
        // reserved in a previous session reappear (and the in-memory sets the
        // visible filter uses start out of sync with storage).
        dismissedIds = HiddenPostsStore.shared.loadDismissed()
        reservedIds = HiddenPostsStore.shared.loadReserved()
        await loadFeedWithOneShotLocation()
    }
}

private struct PulsingLeafBadge: View {
    @State private var pulse = false
    
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.green.opacity(0.25), .blue.opacity(0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.green, .white)
                .shadow(radius: 4)
        }
        .frame(width: 160, height: 160)
        .scaleEffect(pulse ? 1.05 : 0.95)
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                   value: pulse)
        .onAppear { pulse = true }
        .allowsHitTesting(false)
    }
}

#if DEBUG
private struct FeedDebugOverlayView: View {
    let context: FeedDistanceDebugContext
    let activePostId: String?

    private var activeEntry: FeedDistanceDebugEntry? {
        if let activePostId,
           let match = context.entries.first(where: { $0.id == activePostId }) {
            return match
        }
        return context.entries.first
    }

    var body: some View {
        let myCoord = context.myLocation.coordinate
        let iso = feedDebugISOFormatter.string(from: context.myLocation.timestamp)
        let accuracyMeters = Int(context.myLocation.horizontalAccuracy.rounded())
        VStack(alignment: .leading, spacing: 4) {
            Text("DIST-ID \(context.debugId)")
                .font(.caption.weight(.semibold))
            Text(String(format: "My: %.5f, %.5f acc=%dm %@", myCoord.latitude, myCoord.longitude, accuracyMeters, context.locationSource))
                .font(.caption2)
            Text(" @\(iso) auth=\(context.authorizationStatus.rawValue) precise=\(context.preciseEnabled ? "on" : "off")")
                .font(.caption2)
            if let entry = activeEntry {
                let coordString = entry.coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "n/a"
                let serverStr = entry.serverDistanceKm.map { String(format: "%.2f km", $0) } ?? "nil"
                let localStr = entry.localDistanceKm.map { String(format: "%.2f km", $0) } ?? "nil"
                Text("Post: \(coordString) (\(entry.coordinateSource))")
                    .font(.caption2)
                Text(" server=\(serverStr) ui=\(localStr)")
                    .font(.caption2)
            } else {
                Text("Post: n/a")
                    .font(.caption2)
            }
        }
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(radius: 4)
        .padding([.top, .leading], 12)
    }
}
#endif

extension SwipeDeckView {
    private struct EmptyFeedCTA: View {
        var refresh: () -> Void
        var makePost: () -> Void
        
        var body: some View {
            VStack(spacing: 18) {
                PulsingLeafBadge()
                    .frame(maxWidth: .infinity, alignment: .center)
                
                Text("You're all caught up")
                    .font(.title3.weight(.semibold))
                
                Text("No nearby items right now.\nGot something to give away?")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    Button(action: makePost) {
                        Label("Make a post", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SwoopyPrimaryButtonStyle(minHeight: 48))
                    
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SwoopyOutlineButtonStyle(minHeight: 48))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 20)
        }
    }
    
    //
    // MARK: - Stack of up to 3 cards
    //
    private struct DeckStack: View {
        @ObservedObject var deckState: DeckState
        let router: AppRouter
        let isReserving: Bool
        let onPass: () -> Void
        let onReserve: () -> Void
        
        var body: some View {
            ZStack {
                // Show active card and next card only
                if let activeCard = deckState.activeCard {
                    FeedCard(
                        item: activeCard,
                        deckState: deckState,
                        isActiveCard: true,
                        isReserving: isReserving,
                        onPass: onPass,
                        onReserve: onReserve
                    )
                    .id(cardIdentity(activeCard))
                    .zIndex(2)
                    .allowsHitTesting(!deckState.isAnimating && !isReserving)
                }
                
                if let nextCard = deckState.nextCard {
                    FeedCard(
                        item: nextCard,
                        deckState: deckState,
                        isActiveCard: false,
                        isReserving: false,
                        onPass: {},
                        onReserve: {}
                    )
                    .id(cardIdentity(nextCard))
                    .zIndex(1)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: deckState.activeIndex)
        }

        private func cardIdentity(_ item: Any) -> String {
            if let post = item as? Post {
                return post.id
            }
            if let ckItem = item as? CKTrashItem {
                return String(describing: ckItem.id)
            }
            return String(describing: ObjectIdentifier(type(of: item)))
        }
    }
    
    
    
    private struct GlassSegmented: View {
        @Binding var selection: SwipeDeckView.NavigationState
        private let green = Color(red: 0/255, green: 81/255, blue: 63/255)
        @Namespace private var ns
        
        var body: some View {
            HStack(spacing: 12) {
                seg("Feed", .feed)
                seg("Map",  .map)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
        }
        
        @ViewBuilder
        private func seg(_ title: String, _ state: SwipeDeckView.NavigationState) -> some View {
            Button {
                let reason = state == .map ? "map_button_tap" : "feed_button_tap"
                DLog("🔵 [\(reason)] IMMEDIATE tap registered current=\(selection) requested=\(state)")
                dbg("UI", "\(reason) current=\(selection) requested=\(state)")
                
                // Standard spring feel for pill movement
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    selection = state
                }
                DLog("🟢 [\(reason)] State updated to \(state)")
            } label: {
                Text(title)
                    .font(.headline)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 18)
                    .background(
                        Group {
                            if selection == state {
                                RoundedRectangle(cornerRadius: 59, style: .continuous)
                                    .fill(green)
                                    .matchedGeometryEffect(id: "ink", in: ns)
                            }
                        }
                    )
                    .foregroundStyle(selection == state ? .white : .primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    
    
    //
    // MARK: - Reserve sheet (two-step)
    //
    
    private struct ReserveSheet: View {
        enum Mode { case prompt, info }
        let mode: Mode
        var confirm: () -> Void
        var openMaps: () -> Void
        var close: () -> Void
        
        var body: some View {
            VStack(spacing: 14) {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: 40, height: 4).padding(.top, 8)
                
                if mode == .prompt {
                    Text("Reserve for the next 6 hours?").font(.headline)
                    Text("Others won’t see this spot while it’s reserved.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Not now", role: .cancel, action: close)
                        Spacer()
                        Button(action: confirm) {
                            Label("Reserve 6h", systemImage: "clock.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Reserved until \(reservedUntilString())").font(.headline)
                    HStack {
                        Label("Location", systemImage: "mappin.circle")
                        Spacer()
                        Button(action: openMaps) { Label("Open in Maps", systemImage: "map") }
                            .buttonStyle(.bordered)
                    }
                    Button("Close", action: close).padding(.top, 6)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 16).padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        
        private func reservedUntilString() -> String {
            let u = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
            let df = DateFormatter()
            df.timeStyle = .short
            df.dateStyle = .none
            return df.string(from: u)
        }
    }
    
    // MARK: - FeedMapScreen
    private struct FeedMapScreen: View {
        let onBack: @MainActor () -> Void
        @EnvironmentObject private var svc: SupabaseService
        @EnvironmentObject private var feedVM: FeedViewModel
        @StateObject private var loc = LocationService.shared

        @State private var api: ApiService?
        @State private var posts: [Post] = []
        @State private var isFetching = false
        @State private var mapError: String?
        @State private var fetchTask: Task<Void, Never>?
        @StateObject private var recenterHelper = MapRecenterHelper()

        @State private var region: MKCoordinateRegion = {
            // Try to get cached user location first
            if let userCoord = LocationService.shared.lastKnownCoordinate {
                #if DEBUG
                DLog("[MAP] init region from cached user location: \(userCoord.latitude), \(userCoord.longitude)")
                #endif
                return MKCoordinateRegion(
                    center: userCoord,
                    span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
            }
            // Fallback to Barcelona only if no cached location
            #if DEBUG
            DLog("[MAP] init region from fallback (Barcelona)")
            #endif
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }()
        @State private var didCenterFromDefault = false
        @State private var forceMapUpdate = false

        @State private var selectedPostID: UUID?
        @State private var calloutPhase: CalloutPhase = .none
        @State private var calloutAnchor: CGPoint?
        @State private var teaserSize: CGSize = .zero
        @State private var cardSize: CGSize = .zero
        @State private var refreshSuppressionUntil: Date?
        @State private var reserveInFlight = false
        @State private var presentedContext: PresentedPostContext?
        @State private var shouldRestoreTeaserOnDismiss = false
        @State private var shouldCollapseAfterGesture = false
        @State private var gestureCollapseTargetID: UUID?
        @State private var isUserPanning = false
        @State private var lastFetchedCoordKey: String?
        
        // Metrics tracking
        @State private var mapOpenTime: Date?
        @State private var fetchCountThisPan = 0

        private let refreshSuppressionSeconds: Double = 0.5

        private struct RegionSignature: Equatable {
            let lat: Double
            let lon: Double
            let dLat: Double
            let dLon: Double

            init(region: MKCoordinateRegion) {
                lat = region.center.latitude
                lon = region.center.longitude
                dLat = region.span.latitudeDelta
                dLon = region.span.longitudeDelta
            }
        }

        private enum CalloutPhase {
            case none
            case teaser
            case expanded
        }

        private enum CollapseReason: String {
            case gesture
            case tapOutside
            case dismiss
        }
        
        private struct PresentedPostContext: Identifiable {
            let post: Post
            let distanceText: String?
            
            var id: String { post.id }
        }

        var body: some View {
            let annotations = streetAnnotations
            GeometryReader { geo in
                ZStack {
                    CheapMapView(
                        region: $region,
                        forceUpdate: forceMapUpdate,
                        annotations: annotations,
                        selectedAnnotationID: $selectedPostID,
                        calloutAnchor: $calloutAnchor,
                        onAnnotationTapped: { id in
                            Task { @MainActor in selectPin(id: id) }
                        },
                        onAnnotationDeselected: {
                            Task { @MainActor in collapseAll(reason: .dismiss) }
                        },
                        onMapTap: { Task { @MainActor in handleMapTap() } },
                        onRegionWillChange: { userInitiated in
                            Task { @MainActor in handleRegionWillChange(userInitiated: userInitiated) }
                        },
                        onRegionDidChange: { newRegion, userInitiated in
                            Task { @MainActor in handleRegionDidChange(newRegion: newRegion, userInitiated: userInitiated) }
                        }
                    )
                    .ignoresSafeArea()

                    calloutOverlay(in: geo, annotations: annotations)

                    topControls
                    bannerOverlay
                }
            }
            .onAppear {
                setupAndFetch()
                // Track first frame time
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)  // wait 1 frame
                    if let start = mapOpenTime {
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        Metrics.firstMapFrameMs(ms)
                    }
                }
            }
            .onDisappear {
                dbg("MAP", "lifecycle onDisappear stopping_location")
                fetchTask?.cancel()
                loc.stopContinuous()
            }
            .onChange(of: loc.lastFix, handleLocationChange)
            .onChange(of: RegionSignature(region: region)) { _, _ in
                debouncedFetchPosts()
            }
            .fullScreenCover(item: $presentedContext, onDismiss: {
                Task { @MainActor in
                    if shouldRestoreTeaserOnDismiss {
                        restoreTeaserAfterOverlay()
                    }
                    shouldRestoreTeaserOnDismiss = false
                }
            }) { context in
                mapDetailOverlay(for: context)
            }
        }

        private var topControls: some View {
            VStack {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(AppTheme.ColorToken.brandDark)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: recenterOnUser) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(
                                Circle()
                                    .fill(AppTheme.ColorToken.brandDark)
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 72)  // Increased from 64 to ensure no overlap with map compass

                Spacer()
            }
            .safeAreaInset(edge: .bottom) {
                // Ensure legal text has ≥10pt from safe area bottom
                Color.clear.frame(height: 10)
            }
        }

        @ViewBuilder
        private var bannerOverlay: some View {
            VStack {
                if let mapError {
                    SwoopyToast(
                        message: mapError,
                        style: mapError.hasPrefix("Reserved") ? .success : .info
                    )
                    .padding(.top, 64)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
        }

        private var streetAnnotations: [StreetPinAnnotation] {
            posts.compactMap { post in
                guard post.mode == .street,
                      let uuid = UUID(uuidString: post.id),
                      let coordinate = post.exactCoordinate ?? post.approxCoordinate
                else { return nil }

                let thumbnail = post.images.sorted { $0.orderIndex < $1.orderIndex }.first?.url
                let distanceMeters = post.distance.map { $0 * 1_000 }
                return StreetPinAnnotation(
                    id: uuid,
                    rawId: post.id,
                    coordinate: coordinate,
                    title: post.title,
                    thumbnailURL: thumbnail,
                    distanceMeters: distanceMeters
                )
            }
        }

        @ViewBuilder
        private func calloutOverlay(in geo: GeometryProxy, annotations: [StreetPinAnnotation]) -> some View {
            if calloutPhase != .none,
               let selectedID = selectedPostID,
               let anchor = calloutAnchor,
               let annotation = annotations.first(where: { $0.id == selectedID }) {
                switch calloutPhase {
                case .teaser:
                    let size = teaserSize.validOrDefault(fallback: CGSize(width: 190, height: 96))
                    let placement = placement(for: size, anchor: anchor, in: geo)
                    if let post = posts.first(where: { $0.id == annotation.rawId }) {
                        StreetPinTeaser(
                            annotation: annotation,
                            distanceText: distanceText(for: annotation),
                            onExpand: {
                                Task { @MainActor in
                                    presentFullOverlay(post: post, annotation: annotation)
                                }
                            },
                            arrowOffset: placement.arrowX,
                            arrowYOffset: placement.arrowY
                        )
                        .onSizeChange { newSize in
                            teaserSize = newSize
                        }
                        .position(placement.position)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                case .expanded:
                    if let post = posts.first(where: { $0.id == annotation.rawId }) {
                        let expandedScale: CGFloat = 0.5
                        let size = cardSize.validOrDefault(fallback: CGSize(width: 320 * expandedScale, height: 360 * expandedScale))
                        let placement = placement(for: size, anchor: anchor, in: geo)
                        MapAttachedCard(
                            post: post,
                            isReserving: reserveInFlight,
                            onReserve: {
                                Task { await handleReserve(post: post) }
                            },
                            onPass: { collapseAll(reason: .dismiss) },
                            arrowOffset: placement.arrowX,
                            arrowYOffset: placement.arrowY
                        )
                        .onSizeChange { newSize in
                            cardSize = CGSize(width: newSize.width * expandedScale, height: newSize.height * expandedScale)
                        }
                        .position(placement.position)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                case .none:
                    EmptyView()
                }
            } else {
                EmptyView()
            }
        }

        @MainActor
        private func selectPin(id: UUID) {
            if selectedPostID == id {
                if calloutPhase == .none {
                    logPinSelect(id)
                    showTeaser(for: id, reason: "reselect")
                }
                return
            }
            selectedPostID = id
            logPinSelect(id)
            showTeaser(for: id, reason: "select")
        }

        @MainActor
        private func showTeaser(for id: UUID, reason: String) {
            withCalloutSpring {
                calloutPhase = .teaser
            }
            suppressRefresh(for: refreshSuppressionSeconds)
            shouldCollapseAfterGesture = false
            gestureCollapseTargetID = nil
            announceCalloutChange(.teaser)
            logCallout("[CALLOUT] show teaser id=\(id.uuidString) reason=\(reason)")
        }

        @MainActor
        private func collapseToTeaser(reason: CollapseReason) {
            guard calloutPhase == .expanded, let id = selectedPostID else { return }
            withCalloutSpring {
                calloutPhase = .teaser
            }
            suppressRefresh(for: refreshSuppressionSeconds)
            announceCalloutChange(.teaser)
            logCallout("[CALLOUT] collapse reason=\(reason.rawValue) stage=teaser id=\(id.uuidString)")
        }

        @MainActor
        private func collapseAll(reason: CollapseReason) {
            guard calloutPhase != .none || selectedPostID != nil else { return }
            let id = selectedPostID
            withCalloutSpring {
                calloutPhase = .none
                selectedPostID = nil
            }
            calloutAnchor = nil
            suppressRefresh(for: refreshSuppressionSeconds)
            announceCalloutChange(.none)
            if let id {
                logCallout("[CALLOUT] collapse reason=\(reason.rawValue) stage=none id=\(id.uuidString)")
            } else {
                logCallout("[CALLOUT] collapse reason=\(reason.rawValue) stage=none id=none")
            }
            shouldCollapseAfterGesture = false
            gestureCollapseTargetID = nil
        }

        @MainActor
        private func handleMapTap() {
            switch calloutPhase {
            case .expanded:
                collapseToTeaser(reason: .tapOutside)
            case .teaser:
                collapseAll(reason: .tapOutside)
            case .none:
                break
            }
        }

        @MainActor
        private func handleRegionWillChange(userInitiated: Bool) {
            guard userInitiated else { return }
            isUserPanning = true  // Mark gesture start
            fetchTask?.cancel()   // Cancel pending fetch
            fetchCountThisPan = 0  // Reset counter for new pan session
            gestureCollapseTargetID = selectedPostID
            if calloutPhase == .expanded {
                collapseToTeaser(reason: .gesture)
                shouldCollapseAfterGesture = true
            } else if calloutPhase == .teaser {
                collapseAll(reason: .gesture)
                shouldCollapseAfterGesture = false
            } else {
                shouldCollapseAfterGesture = false
            }
        }

        @MainActor
        private func handleRegionDidChange(newRegion: MKCoordinateRegion, userInitiated: Bool) {
            if userInitiated {
                isUserPanning = false  // Mark gesture end
                if shouldCollapseAfterGesture {
                    if gestureCollapseTargetID == nil || gestureCollapseTargetID == selectedPostID {
                        collapseAll(reason: .gesture)
                    }
                }
                shouldCollapseAfterGesture = false
                gestureCollapseTargetID = nil
            }
        }

        private func withCalloutSpring(_ updates: @escaping () -> Void) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                updates()
            }
        }

        private func placement(for size: CGSize, anchor: CGPoint, in geo: GeometryProxy) -> (position: CGPoint, arrowX: CGFloat, arrowY: CGFloat) {
            let padding: CGFloat = 16
            let verticalSpacing: CGFloat = 10
            let safeInsets = geo.safeAreaInsets
            let safeRect = CGRect(
                x: padding,
                y: safeInsets.top + padding,
                width: geo.size.width - padding * 2,
                height: geo.size.height - safeInsets.top - safeInsets.bottom - padding * 2
            )

            let desiredCenterX = anchor.x
            let desiredCenterY = anchor.y - size.height / 2 - verticalSpacing

            let clampedX = min(max(desiredCenterX, safeRect.minX + size.width / 2), safeRect.maxX - size.width / 2)
            let clampedY = min(max(desiredCenterY, safeRect.minY + size.height / 2), safeRect.maxY - size.height / 2)

            let arrowLimit = max(0, size.width / 2 - 28)
            let arrowX = max(-arrowLimit, min(arrowLimit, desiredCenterX - clampedX))
            let arrowY = verticalSpacing

            return (CGPoint(x: clampedX, y: clampedY), arrowX, arrowY)
        }

        private func distanceText(for annotation: StreetPinAnnotation) -> String? {
            guard let meters = annotation.distanceMeters else { return nil }
            if meters < 950 {
                let rounded = max(1, Int(meters.rounded()))
                return "\(rounded) m away"
            }
            return String(format: "%.1f km away", meters / 1_000)
        }
        
        @MainActor
        private func presentFullOverlay(post: Post, annotation: StreetPinAnnotation) {
            let distance = distanceText(for: annotation)
            presentedContext = PresentedPostContext(post: post, distanceText: distance)
            shouldRestoreTeaserOnDismiss = true
            announceCalloutChange(.expanded)
            logCallout("[CALLOUT] expand stage=detail id=\(annotation.id.uuidString)")
            dbg("MAP", "teaser_view_to_full post={\(post.id)}")
            suppressRefresh(for: refreshSuppressionSeconds)
            shouldCollapseAfterGesture = false
            gestureCollapseTargetID = nil
        }
        
        @MainActor
        private func restoreTeaserAfterOverlay() {
            guard let id = selectedPostID else { return }
            if calloutPhase != .teaser {
                withCalloutSpring {
                    calloutPhase = .teaser
                }
                announceCalloutChange(.teaser)
            }
            logCallout("[CALLOUT] detail dismissed id=\(id.uuidString)")
        }
        
        @MainActor
        private func dismissDetailToTeaser() {
            if presentedContext != nil {
                presentedContext = nil
            }
        }
        
        @MainActor
        private func startReserveFlow(for post: Post) {
            presentedContext = nil
            shouldRestoreTeaserOnDismiss = false
            Task { await handleReserve(post: post) }
        }
        
        @MainActor
        private func dismissDetailAndPass() {
            presentedContext = nil
            shouldRestoreTeaserOnDismiss = false
            collapseAll(reason: .dismiss)
        }
        
        @ViewBuilder
        private func mapDetailOverlay(for context: PresentedPostContext) -> some View {
            let post = context.post
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        Task { @MainActor in dismissDetailToTeaser() }
                    }
                
                BigCardOverlay(
                    postID: post.id,
                    images: imageURLs(for: post),
                    primaryInfo: primaryInfo(for: post, distanceText: context.distanceText),
                    statusInfo: statusInfo(for: post),
                    statusColor: Color(hex: "#00513F"),
                    description: post.description,
                    mode: locationMode(for: post),
                    exactCoordinate: post.exactCoordinate,
                    approxCoordinate: post.approxCoordinate,
                    ownerName: ownerName(for: post),
                    ownerAvatarUrl: post.owner?.avatarUrl,
                    ownerId: post.ownerId,
                    memberSince: post.createdAt,
                    pickupsCount: post.owner?.pickedCount,
                    variant: .feed,
                    onDismiss: {
                        Task { @MainActor in dismissDetailToTeaser() }
                    },
                    onPrimaryAction: {
                        Task { @MainActor in startReserveFlow(for: post) }
                    },
                    onSecondaryAction: {
                        Task { @MainActor in dismissDetailAndPass() }
                    },
                    onTertiaryAction: nil
                )
            }
        }
        
        private func imageURLs(for post: Post) -> [String] {
            post.images.sorted { $0.orderIndex < $1.orderIndex }.map { $0.url.absoluteString }
        }
        
        private func primaryInfo(for post: Post, distanceText: String?) -> String {
            if post.mode == .home { return "From home (address hidden)" }
            if let distanceText, !distanceText.isEmpty { return distanceText }
            if let distance = post.distance {
                return String(format: "%.1f km away", distance)
            }
            return "Available nearby"
        }
        
        private func statusInfo(for post: Post) -> String {
            guard let created = post.createdAt else { return "" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: created, relativeTo: Date())
            return relative.isEmpty ? "" : "Posted \(relative)"
        }
        
        private func locationMode(for post: Post) -> BigCardOverlay.LocationMode {
            post.mode == .home ? .home : .street
        }
        
        private func ownerName(for post: Post) -> String {
            post.owner?.fullName ?? "Anonymous User"
        }

        private func suppressRefresh(for duration: Double) {
            refreshSuppressionUntil = Date().addingTimeInterval(duration)
        }

        private func pruneSelectionIfNeeded() {
            guard let selectedID = selectedPostID else { return }
            if !streetAnnotations.contains(where: { $0.id == selectedID }) {
                collapseAll(reason: .dismiss)
            }
        }

        private func setupAndFetch() {
            mapOpenTime = Date()  // Track open time for metrics
            dbg("MAP", "lifecycle onAppear starting_location")
            if api == nil { api = ApiService(supabaseService: svc) }
            loc.startContinuous()
            
            // Check if we started with user location or fallback
            if let userCoord = LocationService.shared.lastKnownCoordinate {
                didCenterFromDefault = true
                dbg("MAP", "started centered on user: \(userCoord.latitude), \(userCoord.longitude)")
            } else {
                didCenterFromDefault = false
                dbg("MAP", "started with fallback, waiting for location fix")
            }

            Task { await fetchPosts() }
        }

        private func handleLocationChange(_: CLLocation?, newLocation: CLLocation?) {
            guard let newLocation else { return }
            if !didCenterFromDefault {
                dbg("MAP", "first location fix received, centering: \(newLocation.coordinate.latitude), \(newLocation.coordinate.longitude)")
                region = MKCoordinateRegion(
                    center: newLocation.coordinate,
                    span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
                didCenterFromDefault = true
                // Fetch pins for new region
                Task { await fetchPosts() }
            }
        }

        private func debouncedFetchPosts() {
            fetchTask?.cancel()
            fetchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await fetchPostsIfAllowed()
            }
        }

        @MainActor
        private func fetchPostsIfAllowed() async {
            if shouldDelayFetch() {
                fetchTask?.cancel()
                fetchTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    await fetchPostsIfAllowed()
                }
                return
            }
            await fetchPosts()
        }

        @MainActor
        private func shouldDelayFetch() -> Bool {
            if calloutPhase == .expanded { return true }
            if let until = refreshSuppressionUntil, until > Date() { return true }
            return false
        }

        private func logCallout(_ message: String) {
            #if DEBUG
            DLog(message)
            #endif
        }

        private func logPinSelect(_ id: UUID) {
            #if DEBUG
            let rawId = posts.first { UUID(uuidString: $0.id) == id }?.id ?? id.uuidString
            DLog("[PIN] select id=\(rawId)")
            #endif
        }

        private func announceCalloutChange(_ phase: CalloutPhase) {
            #if canImport(UIKit)
            guard UIAccessibility.isVoiceOverRunning else { return }
            let message: String?
            switch phase {
            case .teaser:
                message = "Post teaser shown"
            case .expanded:
                message = "Post details shown"
            case .none:
                message = "Callout hidden"
            }
            UIAccessibility.post(notification: .layoutChanged, argument: message)
            #endif
        }

        @MainActor
        private func fetchPosts() async {
            guard let api else { return }
            guard !isFetching else { return }

            let center = region.center
            let start = Date()
            
            // Single-flight: skip if already fetched this coord recently
            let coordKey = LocationReadiness.cacheKey(center)
            if let lastKey = lastFetchedCoordKey {
                // Check if moved >200m from last fetch
                let lastCoordParts = lastKey.split(separator: ",")
                if lastCoordParts.count == 2,
                   let lastLat = Double(lastCoordParts[0]),
                   let lastLng = Double(lastCoordParts[1]) {
                    let lastCoord = CLLocationCoordinate2D(latitude: lastLat, longitude: lastLng)
                    let currentLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
                    let lastLoc = CLLocation(latitude: lastCoord.latitude, longitude: lastCoord.longitude)
                    let distance = currentLoc.distance(from: lastLoc)
                    
                    if distance < 200 {
                        #if DEBUG
                        DLog("[FEED gate] skip (reason=moved-only-\(Int(distance))m key=\(coordKey))")
                        #endif
                        return
                    }
                }
            }

            fetchCountThisPan += 1
            isFetching = true
            defer {
                isFetching = false

                let ms = Int(Date().timeIntervalSince(start) * 1000)
                Metrics.avgFeedMs(ms)
                Metrics.fetchCountPerPan(fetchCountThisPan)
            }

            do {
                dbg("MAP", "fetching posts for region center: \(center.latitude), \(center.longitude)")
                let query = FeedQuery(
                    lng: center.longitude,
                    lat: center.latitude,
                    radiusKm: 10.0,
                    category: nil,
                    mode: "street",
                    limit: 40
                )

                var latestError: Error?
                let maxAttempts = 2

                for attempt in 1...maxAttempts {
                    do {
                        let result = try await withTimeout(seconds: 18.0) {
                            try await api.getFeed(query: query)
                        }
                        posts = result
                        feedVM.setBaseItems(result)
                        mapError = nil
                        // Only record the fetched coordinate on success so a
                        // cancelled fetch doesn't suppress the debounced retry.
                        lastFetchedCoordKey = coordKey
                        pruneSelectionIfNeeded()
                        dbg("MAP", "loaded \(result.count) posts")
                        return
                    } catch {
                        latestError = error

                        if error.isCancellationLike {
                            dbg("FEED", "map fetch cancelled/timeout - no retry")
                            throw error
                        }

                        dbg("FEED", "map fetch attempt \(attempt) failed: \(error.localizedDescription)")
                        if attempt < maxAttempts {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                    }
                }

                if let latestError {
                    throw latestError
                } else {
                    throw TimeoutError.timedOut
                }
            } catch {
                // A cancelled fetch (user panned/zoomed again before it finished)
                // is not a failure — the debounced follow-up fetch will refresh.
                let nsError = error as NSError
                if error is CancellationError
                    || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                    || Task.isCancelled {
                    dbg("MAP", "fetch cancelled (region changed) — staying silent")
                    return
                }

                dbg("MAP", "Failed to fetch posts: \(error.localizedDescription)")
                // Only show error if we have no posts to display
                if posts.isEmpty {
                    mapError = "Couldn't load items."
                } else {
                    mapError = "Couldn't refresh. Showing last results."
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    mapError = nil
                }
            }
        }

        private func recenterOnUser() {
            dbg("MAP", "recenter button tapped")
            forceMapUpdate = true

            recenterHelper.recenter(
                region: &region,
                locationService: loc,
                onPermissionDenied: { message in
                    dbg("MAP", "recenter denied: \(message)")
                    mapError = message
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if mapError == message {
                            mapError = nil
                        }
                    }
                },
                completion: {
                    Task { @MainActor in
                        dbg("MAP", "recenter complete, refreshing pins")
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        forceMapUpdate = false
                        // Refresh pins for new region
                        await fetchPosts()
                    }
                }
            )
        }

        @MainActor
        private func handleReserve(post: Post) async {
            guard let api else { return }
            guard !reserveInFlight else { return }

            reserveInFlight = true
            defer { reserveInFlight = false }

            let requestId = UUID().uuidString
            let tempId = "optimistic-\(requestId)"
            let placeholderRow = ReservationRow(optimisticFrom: post, reservationId: tempId)
            postOptimisticReservationInsert(placeholderRow)
            var didRemovePlaceholder = false

            do {
                let reservationId = try await fetchWithRetry(svc: svc) {
                    try await api.reservePost(post.id, requestId: requestId)
                }

                if !didRemovePlaceholder {
                    postOptimisticReservationRemove(tempId)
                    didRemovePlaceholder = true
                }
                let optimisticRow = ReservationRow(optimisticFrom: post, reservationId: reservationId)
                postOptimisticReservationInsert(optimisticRow)
                NotificationCenter.default.post(name: .refreshReservations, object: reservationId)
                let successMessage = "Reserved for 2 hours"
                mapError = successMessage
                collapseAll(reason: .dismiss)
                scheduleBannerDismiss(for: successMessage)
                await fetchPosts()
            } catch let authError as AuthError {
                if !didRemovePlaceholder {
                    postOptimisticReservationRemove(tempId)
                    didRemovePlaceholder = true
                }
                mapError = authError.localizedDescription
                scheduleBannerDismiss(for: authError.localizedDescription)
            } catch {
                if !didRemovePlaceholder {
                    postOptimisticReservationRemove(tempId)
                }
                let message = "Couldn't reserve right now. Please try again."
                mapError = message
                scheduleBannerDismiss(for: message)
            }
        }

        private func scheduleBannerDismiss(for message: String) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if mapError == message {
                    mapError = nil
                }
            }
        }
    }
}
