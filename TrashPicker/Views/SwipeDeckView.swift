//
//  SwipeDeckView.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//

import SwiftUI
import MapKit

// Using real API service for feed data

struct SwipeDeckView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var draftStore: UploadDraftStore

    // API Service for feed data
    @State private var api: ApiService?
    @State private var posts: [Post] = []

    // Deck state management - single source of truth
    @StateObject private var deckState = DeckState()
    @State private var hidden: Set<String> = []

    // Loading and error states
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false

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
        return posts.filter { !hidden.contains($0.id) }
    }

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
            .task { 
                if api == nil { api = ApiService(supabaseService: svc) }
                await fetchFeedBridge() 
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
            .fullScreenCover(isPresented: $showUploadForm, onDismiss: { handleUploadFormDismiss() }) {
                uploadFormView
            }
            .fullScreenCover(isPresented: $showFeedMap) {
                feedMapView
            }
        }
    }


    // MARK: - Main Content Components

    private var mainContentArea: some View {
        ZStack {
            if isLoading {
                loadingView
            } else if showError {
                errorView
            } else if visible.isEmpty {
                emptyStateView
            } else {
                feedContentView
            }
            
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
                    hidden.removeAll()
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
                    hidden.removeAll()
                }
            },
            makePost: { handleMakePost() }
        )
    }

    private var feedContentView: some View {
        VStack(spacing: 0) {
            DeckStack(deckState: deckState, router: router)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, 18)
                .refreshable {
                    await fetchFeedBridge()
                    hidden.removeAll()
                }
            
            ActionBar(
                deckState: deckState,
                onPass: { Task { await handlePass() } },
                onReserve: { Task { await handleReserve() } }
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
            
            // Optimistically remove from feed
            hidden.insert(post.id)
            
            // Refresh feed and show success
            await fetchFeedBridge()
            withAnimation(.easeOut(duration: 0.18)) {
                sheetMode = .info
            }
        } catch {
            #if DEBUG
            print("Failed to reserve post: \(error.localizedDescription)")
            #endif
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
    private func handlePass() async {
        await deckState.triggerPass()
        
        // Pass: optimistically hide without API call
        if let post = deckState.activeCard as? Post { 
            hidden.insert(post.id) 
        }
    }
    
    @MainActor
    private func handleReserve() async {
        guard let post = deckState.activeCard as? Post else { return }
        guard let api else { return }
        
        do {
            try await deckState.triggerReserve()
            
            // Reserve: call real API
            _ = try await fetchWithRetry(svc: svc) {
                try await api.reservePost(post.id)
            }
            
            // Optimistically hide from feed
            hidden.insert(post.id)
            
            // Complete the transition
            deckState.completeCardTransition()
            
        } catch {
            // Error handling is managed by DeckState
            #if DEBUG
            print("Failed to reserve post: \(error.localizedDescription)")
            #endif
            
            // Show error to user
            await MainActor.run {
                if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                    errorMessage = "Session expired. Please sign in again."
                } else {
                    errorMessage = "Failed to reserve item. Please try again."
                }
                showError = true
            }
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
        
        isLoading = true
        showError = false
        
        do {
            let feedQuery = FeedQuery(
                lng: userLocation.longitude,
                lat: userLocation.latitude,
                radiusKm: 10,
                category: nil,
                mode: nil,
                limit: 20
            )
            
            let fetchedPosts = try await fetchWithRetry(svc: svc) { 
                try await api.getFeed(query: feedQuery)
            }
            
            posts = fetchedPosts
            deckState.updateItems(visible)
            isLoading = false
        } catch {
            #if DEBUG
            print("Failed to fetch feed: \(error.localizedDescription)")
            #endif
            posts = []
            deckState.updateItems([])
            isLoading = false
            
            if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Session expired. Please sign in again."
            } else {
                errorMessage = "Unable to load feed. Please try again."
            }
            showError = true
        }
    }
    
    // MARK: - Helper Functions
    

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
        let router:   AppRouter// Add router as a parameter to DeckStack
        
        var body: some View {
            ZStack {
                // Show active card and next card only
                if let activeCard = deckState.activeCard {
                    FeedCard(
                        item: activeCard,
                        deckState: deckState,
                        isActiveCard: true,
                        router: router
                    )
                    .zIndex(2)
                    .allowsHitTesting(!deckState.isAnimating)
                }
                
                if let nextCard = deckState.nextCard {
                    FeedCard(
                        item: nextCard,
                        deckState: deckState,
                        isActiveCard: false,
                        router: router
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
        @EnvironmentObject var svc: SupabaseService
        @EnvironmentObject var loc: LocationManager
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
                #if DEBUG
                print("Failed to fetch street posts: \(error.localizedDescription)")
                #endif
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
                #if DEBUG
                print("Location permission not granted")
                #endif
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
                    #if DEBUG
                    print("Failed to get current location")
                    #endif
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

