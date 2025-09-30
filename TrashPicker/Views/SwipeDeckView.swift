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
    @EnvironmentObject private var loc: LocationManager
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

    // Glass segmented control and map presentation
    fileprivate enum SegTab { case feed, map }
    @State private var seg: SegTab = .feed
    @State private var showMap = false
    @State private var showFeedMap = false

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
        NavigationStack {
            VStack(spacing: 0) {
                GlassSegmented(selection: $seg)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                
                GeometryReader { geo in
                    mainContentArea
                }
            }
            .toolbar { toolbarContent }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { handleViewAppear() }
            // INIT: create ApiService and gate the first fetch
            .task {
                if api == nil { api = ApiService(supabaseService: svc) }
                if svc.hasAuthToken {
                    // TEMP: Xcode Console Extraction
                    print("DEBUG TOKEN: \(svc.session?.accessToken ?? "No token")")
                }
                await maybeLoadFeed()
            }
            // When auth flips ready, fire once
            .onChange(of: svc.isAuthenticated) { _, _ in
                Task { await maybeLoadFeed() }
            }
            // Observe session/token as well to avoid races
            .onChange(of: svc.session) { _, _ in
                Task { await maybeLoadFeed() }
            }
            .onChange(of: seg) { oldValue, newValue in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    showFeedMap = (newValue == .map)
                }
            }
            .onChange(of: showFeedMap) { oldValue, newValue in
                if !newValue {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        seg = .feed
                    }
                }
            }
            .overlay { errorOverlay }
            .overlay { successOverlay }
            .fullScreenCover(isPresented: $showUploadForm, onDismiss: { handleUploadFormDismiss() }) {
                uploadFormView
            }
            .fullScreenCover(isPresented: $showFeedMap) {
                feedMapView
            }
        }
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
            
            Text(errorMessage ?? "Session expired. Please sign in again.")
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
                .environmentObject(loc)
                .environmentObject(draftStore)
        }
    }

    private var feedMapView: some View {
        FeedMapScreen()
            .environmentObject(svc)
            .environmentObject(loc)
            .ignoresSafeArea()
    }

    // MARK: - Action Handlers

    private func handleViewAppear() {
        if cameraService == nil {
            cameraService = CameraService(draftStore: draftStore)
        }
    }

    private func handleUploadFormDismiss() {
        seg = .feed
        showFeedMap = false
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
                errorMessage = "Session expired. Please sign in again."
                showAuthError = true
            case .notFound:
                errorMessage = "Post not found"
            case .backend(let msg):
                errorMessage = msg
            case .network:
                errorMessage = "Network error. Please try again."
            }
            showError = true
            
        } catch {
            dbg("ACTION", "reserve fail \(error.localizedDescription)")
            
            isReserving = false
            deckState.isActing = false
            
            errorMessage = "Failed to reserve item. Please try again."
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
    private func fetchFeedBridge() async {
        guard let userLocation = loc.userLocation?.coordinate else {
            errorMessage = "Location required to show nearby items"
            showError = true
            loc.request()
            return
        }
        guard let api else { return }
        
        // Load and reap expired hidden posts
        dismissedIds = HiddenPostsStore.shared.loadDismissed()
        reservedIds = HiddenPostsStore.shared.loadReserved()
        
        let totalHidden = dismissedIds.count + reservedIds.count
        dbg("FEED", "dismissed count=\(dismissedIds.count) reserved count=\(reservedIds.count) after reap=\(totalHidden)")
        
        isLoading = true
        showError = false
        showAuthError = false
        
        do {
            dbg("FEED", "request lat=\(userLocation.latitude) lng=\(userLocation.longitude) radius=10 limit=30")
            
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
            
            // Filter out own posts (case-insensitive)
            let myId = (svc.userId?.uuidString ?? "").lowercased()
            dbg("FEED", "self-id=\(myId.prefix(8))...") // No PII
            
            let filtered = fetchedPosts.filter { post in
                let ownerIdMatch = post.ownerId.lowercased() != myId
                let ownerMatch = post.owner?.id.lowercased() != myId
                return ownerIdMatch && ownerMatch
            }
            
            dbg("FEED", "self-filter removed=\(fetchedPosts.count - filtered.count)")
            
            // Track server payload for stray detection
            lastServerPayload = Set(filtered.map { $0.id })
            
            // Keep order as returned from API
            posts = filtered
            deckState.updateItems(visible)
            
            // Stray item detection: check if any visible post wasn't in server payload
            for post in visible {
                if !lastServerPayload.contains(post.id) {
                    dbg("FEED", "WARNING stray item \(post.id.prefix(8))")
                }
            }
            
            // After first successful feed, upgrade location accuracy for better follow-up interactions
            loc.upgradeToBestAccuracy()
            isLoading = false
        } catch {
            dbg("FEED", "error=\(error.localizedDescription)")
            
            posts = []
            deckState.updateItems([])
            isLoading = false
            
            // Check for auth-specific errors
            if error is AuthError || error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Session expired. Please sign in again."
                showAuthError = true
            } else {
                errorMessage = "Unable to load feed. Please try again."
                showError = true
            }
        }
    }
    
    // MARK: - Helper Functions

    @MainActor
    private func maybeLoadFeed() async {
        if api == nil { api = ApiService(supabaseService: svc) }
        guard svc.hasAuthToken, didKickOff == false else { return }
        didKickOff = true
        await fetchFeedBridge()
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
        @Binding var selection: SwipeDeckView.SegTab
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
        private func seg(_ title: String, _ tab: SwipeDeckView.SegTab) -> some View {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    selection = tab
                }
            } label: {
                Text(title)
                    .font(.headline)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 18) // <- controls ink width; increase if you want larger pill
                    .background(
                        Group {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 59, style: .continuous)
                                    .fill(green)
                                    .matchedGeometryEffect(id: "ink", in: ns)
                            }
                        }
                    )
                    .foregroundStyle(selection == tab ? .white : .primary)
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
            return u.formatted(date: Date.FormatStyle.DateStyle.omitted, time: Date.FormatStyle.TimeStyle.shortened)
        }
    }
    
    // MARK: - FeedMapScreen
    
    struct FeedMapScreen: View {
        @EnvironmentObject private var svc: SupabaseService
        @EnvironmentObject private var loc: LocationManager
        @Environment(\.dismiss) private var dismiss
        
        @State private var api: ApiService?
        
        @State private var streetPosts: [Post] = []
        
        @State private var cameraPosition: MapCameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )
        
        private var streetPins: [Post] {
            return streetPosts.filter { post in
                // Only show posts with valid exact location coordinates (street mode posts)
                return post.exactLocation?.coordinate != nil
            }
        }
        
        var body: some View {
            NavigationStack {
                Map(position: $cameraPosition) {
                    ForEach(streetPins, id: \.id) { post in
                        if let exactLoc = post.exactLocation,
                           let coord = exactLoc.coordinate {
                            MapKit.Annotation("", coordinate: coord) {
                                Button(action: {
                                    openInMaps(post: post, coord: coord)
                                }) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                        .shadow(radius: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // Add user location annotation with green circle
                    UserAnnotation()
                }
                .ignoresSafeArea(.all)
                .refreshable {
                    await fetchStreetPosts()
                }
                .onDisappear {
                    // Reset pill when map disappears
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        // This will be handled by the parent view
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: { 
                            dismiss() 
                        }) {
                            Image(systemName: "chevron.backward")
                                .font(.title3.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: recenter) {
                            Image(systemName: "location.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(AppTheme.ColorToken.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Center on my location")
                    }
                }
                .task {
                    if api == nil { api = ApiService(supabaseService: svc) }
                    // Request location permission if needed
                    if loc.authorization == .notDetermined { 
                        loc.request() 
                    }
                    
                    // Set initial camera position
                    if let c = loc.userLocation?.coordinate {
                        cameraPosition = .region(
                            MKCoordinateRegion(
                                center: c,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                        )
                    } else {
                        // Fallback to Barcelona if no location available
                        cameraPosition = .region(
                            MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                        )
                    }
                    
                    // Fetch street-only posts from API
                    await fetchStreetPosts()
                }
                .onChange(of: loc.userLocation) { _, newLocation in
                    // Update camera position and refresh posts when location changes
                    if let coordinate = newLocation?.coordinate {
                        Task { @MainActor in
                            // Only update if we don't already have a good position
                            if case .automatic = cameraPosition {
                                cameraPosition = .region(
                                    MKCoordinateRegion(
                                        center: coordinate,
                                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                                    )
                                )
                            }
                        }
                        
                        // Refresh street posts for new location
                        Task {
                            await fetchStreetPosts()
                        }
                    }
                }
            }
        }
        
        @MainActor
        private func fetchStreetPosts() async {
            guard let userLocation = loc.userLocation?.coordinate else {
                loc.request()
                return
            }
            guard let api else { return }
            
            do {
                let feedQuery = FeedQuery(
                    lng: userLocation.longitude,
                    lat: userLocation.latitude,
                    radiusKm: 10,
                    category: nil,
                    mode: "street", // Only fetch street posts
                    limit: 50
                )
                
                let fetchedPosts = try await fetchWithRetry(svc: svc) {
                    try await api.getFeed(query: feedQuery)
                }
                streetPosts = fetchedPosts
            } catch {
                streetPosts = []
            }
        }
        
        
        private func openInMaps(post: Post, coord: CLLocationCoordinate2D) {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            item.name = post.title
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
        }
        
        private func recenter() {
            // First request location permission if needed
            if loc.authorization == .notDetermined {
                loc.request()
                return
            }
            
            // Check if we have permission
            guard loc.authorization == .authorizedWhenInUse || loc.authorization == .authorizedAlways else {
                return
            }
            
            // If we already have a location, use it immediately
            if let currentLocation = loc.userLocation?.coordinate {
                withAnimation(.easeInOut(duration: 0.8)) {
                    cameraPosition = .region(
                        MKCoordinateRegion(
                            center: currentLocation,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        )
                    )
                }
                return
            }
            
            // Otherwise request a fresh location
            loc.requestOnce { coordinate in
                guard let coordinate = coordinate else {
                    return
                }
                
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.8)) {
                        self.cameraPosition = .region(
                            MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            )
                        )
                    }
                }
            }
        }
    }
    
    
}

