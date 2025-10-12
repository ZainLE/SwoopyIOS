//
//  SwipeDeckView.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//

import SwiftUI
import MapKit
import Combine

// Using real API service for feed data

// MARK: - Debug Logging

/// Centralized debug logger with component tags
private let VERBOSE_LOGS = true

@inline(__always)
private func dbg(_ tag: String, _ items: Any...) {
#if DEBUG
    guard VERBOSE_LOGS else { return }
    let message = items.map { "\($0)" }.joined(separator: " ")
    print("[\(tag)] \(message)")
#endif
}

// MARK: - Hidden Posts Store (24h dismissed, 2h reserved)
private class HiddenPostsStore {
    static let shared = HiddenPostsStore()
    private let dismissedKey = "feed.dismissed"
    private let reservedKey = "feed.reserved"
    private let dismissedTTL: TimeInterval = 24 * 3600 // 24 hours
    private let reservedTTL: TimeInterval = 2 * 3600   // 2 hours
    
    func saveDismissed(_ ids: Set<String>) {
        let dict = ids.reduce(into: [String: Date]()) { $0[$1] = Date() }
        UserDefaults.standard.set(dict, forKey: dismissedKey)
    }
    
    func saveReserved(_ ids: Set<String>) {
        let dict = ids.reduce(into: [String: Date]()) { $0[$1] = Date() }
        UserDefaults.standard.set(dict, forKey: reservedKey)
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

struct SwipeDeckView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject private var ck: CKTrashService
    @EnvironmentObject private var svc: SupabaseService
    @EnvironmentObject private var draftStore: UploadDraftStore

    // API Service for feed data
    @State private var api: ApiService?
    @State private var didKickOff = false
    @State private var posts: [Post] = []
    @State private var lastServerPayload: Set<String> = [] // Track server IDs for stray detection

    // Deck state management - single source of truth
    @StateObject private var deckState = DeckState()
    
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
    @State private var cameraService: CameraService?

    // Convert Post objects to visible feed items
    private var visible: [Post] {
        return posts.filter { post in
            !dismissedIds.contains(post.id) && !reservedIds.contains(post.id)
        }
    }

    // MARK: - Helpers
    private func markReserved(postId: String) {
        // Persist into 2h TTL set and remove card from deck
        reservedIds.insert(postId)
        HiddenPostsStore.shared.saveReserved(reservedIds)
        deckState.completeCardTransition()
    }

    // Use global helper on service: svc.hasAuthToken

    var body: some View {
        baseView
            .overlay { errorOverlay }
            .overlay { successOverlay }
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
        NavigationStack {
            contentView
        }
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
        .onChange(of: navState) { oldValue, newValue in
            handleNavigationChange(from: oldValue, to: newValue)
        }
    }
    
    @MainActor
    private func handleMapDismiss() {
        print("🔵 [NAV] map_dismissed callback")
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
                #if DEBUG
                print("[FEED gate] auth changed to authorized → refetch")
                #endif
                await loadFeedWithOneShotLocation()
            }
        }
    }
    
    private func handleNavigationChange(from oldValue: NavigationState, to newValue: NavigationState) {
        navStateWriteCount += 1
        let writeCount = navStateWriteCount
        
        print("🟡 [NAV] state_changed from=\(oldValue) to=\(newValue) writes=\(writeCount)")
        dbg("NAV", "state_changed from=\(oldValue) to=\(newValue) writes=\(writeCount)")
        
        // Detect thrashing: if we get >2 writes in 200ms, log warning
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if navStateWriteCount > writeCount + 1 {
                print("⚠️ [NAV] state_thrash detected writes=\(navStateWriteCount) in_200ms")
                dbg("NAV", "⚠️ state_thrash detected writes=\(navStateWriteCount) in_200ms")
            }
        }
        
        // Synchronize presentation state (navState is the single source of truth now).
        // Keep logs, avoid secondary boolean to prevent conflicts.
        switch newValue {
        case .feed:
            print("🔴 [NAV] showing_feed isPresented=false (derived)")
            dbg("NAV", "showing_feed (derived)")
        case .map:
            print("🟢 [NAV] presenting_map isPresented=true (derived)")
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


    private var mainContentArea: some View {
        ZStack {
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

            // Present the reservation sheet within the same ZStack so the property returns a single view
            reservationSheetView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(AppTheme.ColorToken.primary)
            
            Text("Loading nearby items...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
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
                .foregroundColor(.red)
            
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
            DeckStack(
                deckState: deckState,
                router: router,
                isReserving: isReserving,
                onPass: { Task { await handlePassAction() } },
                onReserve: { Task { await handleReserveAction() } }
            )
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

    private var toolbarContent: some ToolbarContent {
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
                Text(errorMessage)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.easeInOut, value: deckState.errorMessage)
        }
    }
    
    @ViewBuilder
    private var successOverlay: some View {
        if showSuccess, let successMessage {
            VStack {
                Spacer()
                Text(successMessage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding()
                    .background(AppTheme.ColorToken.primary, in: RoundedRectangle(cornerRadius: 12))
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
            .ignoresSafeArea()
    }

    // MARK: - Action Handlers

    private func handleViewAppear() {
        if cameraService == nil {
            cameraService = CameraService(draftStore: draftStore)
        }
    }

    private func handleUploadFormDismiss() {
        navState = .feed
        Task { await fetchFeedBridge() }
    }

    @MainActor private func handleReservationConfirm() async {
        // Use the active card from deck state
        guard let post = deckState.activeCard as? Post else { return }
        guard let api else { return }
        
        do {
            // Call real API to reserve the post
            _ = try await fetchWithRetry(svc: svc) {
                try await api.reservePost(post.id)
            }
            
            // Add to reserved set
            reservedIds.insert(post.id)
            HiddenPostsStore.shared.saveReserved(reservedIds)
            
            // Refresh feed and show success
            await fetchFeedBridge()
            withAnimation(.easeOut(duration: 0.18)) {
                sheetMode = .info
            }
        } catch {
            // Handle error - could show an alert or error state
        }
    }

    private func handleOpenMaps() {
        guard let post = deckState.activeCard as? Post,
              let coord = post.exactLocation?.coordinate else { return }
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
        
        dbg("ACTION", "reserve start \(post.id.prefix(8))")
        
        // Haptic feedback for primary action (reserve button tap)
        Haptics.play(.primaryAction)
        
        isReserving = true
        deckState.isActing = true
        
        do {
            // Reserve: call real API
            let reservationId = try await fetchWithRetry(svc: svc) {
                try await api.reservePost(post.id)
            }
            
            dbg("ACTION", "reserve ok \(reservationId.prefix(8))")
            
            // Trigger card animation
            try await deckState.triggerReserve()
            
            // Mark locally (2h TTL) and remove card
            markReserved(postId: post.id)
            
            // Optional: background refresh; do not block UI
            Task { await fetchFeedBridge() }
            
            // Show success toast
            successMessage = "Reserved for 2h 🎉"
            showSuccess = true
            
            // Haptic feedback for successful reservation
            Haptics.play(.success)
            
            isReserving = false
            deckState.isActing = false
            
            // Hide success after 2 seconds
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showSuccess = false
            }
            
        } catch let error as ReserveError {
            dbg("ACTION", "reserve fail \(error.localizedDescription)")
            
            isReserving = false
            deckState.isActing = false
            
            // Map error to user-friendly message
            switch error {
            case .ownPost:
                errorMessage = "You can't reserve your own post"
            case .alreadyReserved:
                errorMessage = "Already reserved by someone else"
            case .expired:
                errorMessage = "This post has expired"
            case .unauthorized:
                errorMessage = "Please sign in again to continue."
                showAuthError = true
            case .notFound:
                errorMessage = "Post not found"
            case .backend(let msg):
                errorMessage = msg
            case .network:
                errorMessage = "Can't reach the server right now. Please try again."
            }
            
            // Haptic feedback for reservation errors
            Haptics.play(.error)
            
            showError = true
            
        } catch {
            dbg("ACTION", "reserve fail \(error.localizedDescription)")
            
            isReserving = false
            deckState.isActing = false
            
            errorMessage = "Couldn't reserve this item. Please try again."
            
            // Haptic feedback for generic error
            Haptics.play(.error)
            
            showError = true
        }
    }
    
    private func handleMakePost() {
        guard let cameraService = cameraService else { return }
        
        cameraService.ensureCameraPermission { granted in
            if granted {
                // Present camera with proper view controller
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootViewController = window.rootViewController {
                    
                    var topController = rootViewController
                    while let presented = topController.presentedViewController {
                        topController = presented
                    }
                    
                    cameraService.presentCamera(from: topController)
                }
            }
        }
    }

    // MARK: - Feed Management

    @MainActor
    private func fetchFeed(using location: CLLocation) async {
        guard let api else { return }
        
        let coord = location.coordinate
        
        // Gate: validate coordinate is usable
        guard LocationReadiness.isUsable(coord) else {
            #if DEBUG
            print("[FEED gate] skip (reason=no-usable-location lat=\(coord.latitude) lng=\(coord.longitude))")
            #endif
            isLoading = false
            return
        }
        
        // Single-flight: check if already fetching this coordinate
        let coordKey = LocationReadiness.cacheKey(coord)
        if inFlightCoordKey == coordKey {
            #if DEBUG
            print("[FEED gate] skip (reason=already-in-flight key=\(coordKey))")
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
        if age < 5.0 {
            #if DEBUG
            print("[FEED gate] using fresh coord=(\(userLocation.latitude),\(userLocation.longitude)) hdop=\(location.horizontalAccuracy)")
            #endif
        } else {
            #if DEBUG
            print("[FEED gate] using cached coord=(\(userLocation.latitude),\(userLocation.longitude)) age=\(String(format: "%.1f", age))s")
            #endif
        }
        
        dbg("FEED", "request lat=\(userLocation.latitude) lng=\(userLocation.longitude) radius=10 limit=30")

        do {
            let q = FeedQuery(
                lng: userLocation.longitude,
                lat: userLocation.latitude,
                radiusKm: 10.0,
                category: nil,
                mode: nil,
                limit: 30
            )
            let fetchedPosts = try await fetchWithRetry(svc: svc) {
                try await api.getFeed(query: q)
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
            posts = filtered
            deckState.updateItems(visible)

            isLoading = false
        } catch {
            dbg("FEED", "error=\(error.localizedDescription)")
            posts = []
            deckState.updateItems([])
            isLoading = false

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
    private func loadFeedWithOneShotLocation() async {
        guard !isLoading else { return } // Don't re-fetch if already loading
        isLoading = true
        showError = false
        showAuthError = false

        // Try cached coordinate first (instant)
        if let cached = LocationService.shared.lastKnownFromSystem() {
            let coord = cached.coordinate
            if LocationReadiness.isUsable(coord) {
                let age = max(0, Date().timeIntervalSince(cached.timestamp))
                #if DEBUG
                print("[FEED gate] using cached coord=(\(coord.latitude),\(coord.longitude)) age=\(String(format: "%.1f", age))s")
                #endif
                await fetchFeed(using: cached)
                
                // Optionally refetch with fresh fix in background if cache is old
                if age > 60 {
                    Task {
                        do {
                            let fresh = try await LocationService.shared.firstFix(timeout: 2.5)
                            if LocationReadiness.isUsable(fresh.coordinate) {
                                #if DEBUG
                                print("[FEED gate] refreshing with fresh coord=(\(fresh.coordinate.latitude),\(fresh.coordinate.longitude))")
                                #endif
                                await fetchFeed(using: fresh)
                            }
                        } catch {
                            // Silent fail - we already have cached data
                        }
                    }
                }
                return
            }
        }
        
        // No cached coordinate - wait for fresh fix
        do {
            let loc = try await LocationService.shared.firstFix(timeout: 2.5)
            if LocationReadiness.isUsable(loc.coordinate) {
                await fetchFeed(using: loc)
            } else {
                #if DEBUG
                print("[FEED gate] skip (reason=invalid-fix lat=\(loc.coordinate.latitude) lng=\(loc.coordinate.longitude))")
                #endif
                isLoading = false
            }
            return
        } catch {
            // No fix available - skip request
            #if DEBUG
            print("[FEED gate] skip (reason=no-usable-location error=\(error.localizedDescription))")
            #endif
            isLoading = false
            // Don't show error - just show empty state
        }
    }
    
    // MARK: - Helper Functions

    @MainActor
    private func fetchFeedBridge() async {
        await loadFeedWithOneShotLocation()
    }

    @MainActor
    private func maybeLoadFeed() async {
        if api == nil { api = ApiService(supabaseService: svc) }
        guard svc.hasAuthToken, didKickOff == false else { return }
        guard !didKickOff else { return }
        didKickOff = true
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
                
                Text("No nearby trash right now.\nGot something to give away?")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    Button(action: makePost) {
                        Label("Make a post", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryCTA())
                    
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OutlinePill())
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
                    .zIndex(1)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: deckState.activeIndex)
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
                print("🔵 [\(reason)] IMMEDIATE tap registered current=\(selection) requested=\(state)")
                dbg("UI", "\(reason) current=\(selection) requested=\(state)")
                
                // Standard spring feel for pill movement
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    selection = state
                }
                print("🟢 [\(reason)] State updated to \(state)")
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
        @StateObject private var loc = LocationService.shared
        
        @State private var api: ApiService?
        @State private var posts: [Post] = []
        @State private var isFetching = false
        @State private var mapError: String?
        @State private var fetchTask: Task<Void, Never>?
        @StateObject private var recenterHelper = MapRecenterHelper()
        
        @State private var region: MKCoordinateRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        @State private var didCenterFromDefault = false
        @State private var forceMapUpdate = false  // Toggle to force CheapMapView to bypass guards
        
        private struct RegionSignature: Equatable {
            let lat: Double
            let lon: Double
            let dLat: Double
            let dLon: Double

            init(region: MKCoordinateRegion) {
                self.lat = region.center.latitude
                self.lon = region.center.longitude
                self.dLat = region.span.latitudeDelta
                self.dLon = region.span.longitudeDelta
            }
        }
        
        var body: some View {
            CheapMapView(region: $region, forceUpdate: forceMapUpdate)
                .overlay(alignment: .topLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(AppTheme.ColorToken.brandDark)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                    .padding(.top, 64)
                }
                .overlay(alignment: .topTrailing) {
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
                    .padding(.trailing, 16)
                    .padding(.top, 64)
                }
                .overlay(alignment: .top) {
                    if let mapError {
                        Text(mapError)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.75))
                            .clipShape(Capsule())
                            .padding(.top, 64)
                    }
                }
                .ignoresSafeArea()
                .onAppear(perform: setupAndFetch)
                .onDisappear {
                    dbg("MAP", "lifecycle onDisappear stopping_location")
                    fetchTask?.cancel()
                    loc.stopContinuous()
                }
                .onChange(of: loc.lastFix, handleLocationChange)
                .onChange(of: RegionSignature(region: region)) { _, _ in
                    debouncedFetchPosts()
                }
        }
        
        private func setupAndFetch() {
            dbg("MAP", "lifecycle onAppear starting_location")
            if api == nil { api = ApiService(supabaseService: svc) }
            loc.startContinuous()
            
            if let initialLocation = loc.lastFix {
                region = MKCoordinateRegion(
                    center: initialLocation.coordinate,
                    span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
                didCenterFromDefault = true
                dbg("MAP", "lifecycle initial_region from_cache center=(\(initialLocation.coordinate.latitude),\(initialLocation.coordinate.longitude))")
            } else {
                dbg("MAP", "lifecycle initial_region using_fallback")
            }
            
            Task { await fetchPosts() }
        }
        
        private func handleLocationChange(_: CLLocation?, newLocation: CLLocation?) {
            guard let newLocation else { return }
            if !didCenterFromDefault {
                region = MKCoordinateRegion(
                    center: newLocation.coordinate,
                    span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
                didCenterFromDefault = true
            }
        }
        
        private func debouncedFetchPosts() {
            // Cancel previous fetch
            fetchTask?.cancel()
            
            // Wait 350ms before starting new fetch
            fetchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await fetchPosts()
            }
        }
        
        @MainActor
        private func fetchPosts() async {
            guard let api else { return }
            guard !isFetching else { return }
            
            let center = region.center
            
            isFetching = true
            defer { isFetching = false }
            
            do {
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
                        mapError = nil
                        return
                    } catch {
                        latestError = error
                        
                        // Don't retry on cancellation or timeout
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
                dbg("API", "Failed to fetch map posts: \(error.localizedDescription)")
                // Soft error: show banner, keep existing pins
                let message = "Couldn't load items. Showing last results."
                mapError = message
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if mapError == message {
                        mapError = nil
                    }
                }
                // Don't clear posts - keep last pins visible
            }
        }
        
        private func recenterOnUser() {
            // Toggle forceUpdate to bypass CheapMapView guards for user-initiated recenter
            forceMapUpdate = true
            
            recenterHelper.recenter(
                region: &region,
                locationService: loc,
                onPermissionDenied: { message in
                    mapError = message
                    // Auto-hide banner after 3 seconds
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if mapError == message {
                            mapError = nil
                        }
                    }
                },
                completion: {
                    // Reset forceUpdate after the map has been updated
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
                        forceMapUpdate = false
                    }
                }
            )
        }
        
        private func distanceBetween(_ first: CLLocationCoordinate2D, _ second: CLLocationCoordinate2D) -> CLLocationDistance {
            let a = CLLocation(latitude: first.latitude, longitude: first.longitude)
            let b = CLLocation(latitude: second.latitude, longitude: second.longitude)
            return a.distance(from: b)
        }
        
        private func openInMaps(post: Post, coord: CLLocationCoordinate2D) {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            item.name = post.title
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
        }
    }
}
