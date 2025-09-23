//
//  SwipeDeckView.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//

import SwiftUI
import MapKit

// MARK: - Backend bridge toggle (switch when BE is ready)
private enum BackendMode { case cloudKit, api, stub }
private let BACKEND_MODE: BackendMode = .cloudKit   // keep CloudKit as default

// Optional: configure API base when you flip to .api (left here for future)
private enum APIConfig {
    static let base = URL(string: "https://api.swoopy.eu/v1")!
    static let feedPath = "/feed"            // GET    /v1/feed
    static let reservePath = "/reservations" // POST   /v1/reservations
    static func headers() -> [String:String] { [:] }
}

struct SwipeDeckView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var draftStore: UploadDraftStore

    // Deck state management - single source of truth
    @StateObject private var deckState = DeckState()
    @State private var hidden: Set<CKRecord.ID> = []

    // Glass segmented control and map presentation
    fileprivate enum SegTab { case feed, map }
    @State private var seg: SegTab = .feed
    @State private var showMap = false
    @State private var showFeedMap = false

    // reserve sheet (two-step)
    @State private var showReserveSheet = false
    @State private var sheetMode: ReserveSheet.Mode = .prompt
    @State private var sheetItem: CKTrashItem?
    
    // Camera and upload flow - using draft store
    @State private var showUploadForm = false
    @State private var cameraService: CameraService?

    // Keep everything in CKTrashItem to match service
    private var visible: [CKTrashItem] {
        // Use inline sample data for testing, fallback to real feed
        let feedItems = ck.feed.isEmpty ? sampleFeedItems : ck.feed
        return feedItems.filter { !hidden.contains($0.id) && !ck.isMine($0) }
    }
    
    // Inline sample data for design testing
    private var sampleFeedItems: [CKTrashItem] {
        // Build items in smaller steps to help the type-checker
        let now = Date()
        let baseCity = "San Francisco"

        // Coordinates
        let coord1 = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let coord2 = CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4094)
        let coord3 = CLLocationCoordinate2D(latitude: 37.7649, longitude: -122.4294)
        let coord4 = CLLocationCoordinate2D(latitude: 37.7549, longitude: -122.4394)
        let coord5 = CLLocationCoordinate2D(latitude: 37.7449, longitude: -122.4494)

        // Photo URLs
        let url1 = URL(string: "https://picsum.photos/400/400?random=1")
        let url2 = URL(string: "https://picsum.photos/400/400?random=2")
        let url3 = URL(string: "https://picsum.photos/400/400?random=3")
        let url4 = URL(string: "https://picsum.photos/400/400?random=4")
        let url5 = URL(string: "https://picsum.photos/400/400?random=5")

        // Items
        let item1 = CKTrashItem(
            id: CKRecord.ID(),
            title: "Vintage Wooden Chair",
            category: "Furniture",
            photoURL: url1,
            coordinate: coord1,
            city: baseCity,
            createdAt: now.addingTimeInterval(-3600),
            expiresAt: now.addingTimeInterval(86400 * 6),
            status: "available",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: nil,
            pickedUpAt: nil,
            interestedCount: 3,
            desc: "Beautiful vintage wooden chair in great condition. Perfect for a home office or dining room.",
            condition: "good",
            mode: "street"
        )

        let item2 = CKTrashItem(
            id: CKRecord.ID(),
            title: "Kitchen Appliances Set",
            category: "Appliances",
            photoURL: url2,
            coordinate: coord2,
            city: baseCity,
            createdAt: now.addingTimeInterval(-7200),
            expiresAt: now.addingTimeInterval(86400 * 5),
            status: "available",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: nil,
            pickedUpAt: nil,
            interestedCount: 7,
            desc: "Microwave, toaster, and coffee maker. All working perfectly.",
            condition: "like new",
            mode: "home"
        )

        let item3 = CKTrashItem(
            id: CKRecord.ID(),
            title: "Books Collection",
            category: "Books",
            photoURL: url3,
            coordinate: coord3,
            city: baseCity,
            createdAt: now.addingTimeInterval(-10800),
            expiresAt: now.addingTimeInterval(86400 * 4),
            status: "available",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: nil,
            pickedUpAt: nil,
            interestedCount: 2,
            desc: "Mix of fiction and non-fiction books. Great for students or book lovers.",
            condition: "usable",
            mode: "street"
        )

        let item4 = CKTrashItem(
            id: CKRecord.ID(),
            title: "Exercise Equipment",
            category: "Sports",
            photoURL: url4,
            coordinate: coord4,
            city: baseCity,
            createdAt: now.addingTimeInterval(-14400),
            expiresAt: now.addingTimeInterval(86400 * 3),
            status: "available",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: nil,
            pickedUpAt: nil,
            interestedCount: 5,
            desc: "Yoga mat, resistance bands, and dumbbells. Perfect for home workouts.",
            condition: "needs fixing",
            mode: "home"
        )

        let item5 = CKTrashItem(
            id: CKRecord.ID(),
            title: "Art Supplies",
            category: "Art",
            photoURL: url5,
            coordinate: coord5,
            city: baseCity,
            createdAt: now.addingTimeInterval(-18000),
            expiresAt: now.addingTimeInterval(86400 * 2),
            status: "available",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: nil,
            pickedUpAt: nil,
            interestedCount: 1,
            desc: "Paints, brushes, canvases, and drawing supplies. Great for artists or students.",
            condition: "like new",
            mode: "street"
        )

        return [item1, item2, item3, item4, item5]
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
            .task { await fetchFeedBridge() }
            .onChange(of: seg) { newValue in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    showFeedMap = (newValue == .map)
                }
            }
            .onChange(of: showFeedMap) { newValue in
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
            if visible.isEmpty {
                emptyStateView
            } else {
                feedContentView
            }
            
            reservationSheetView
        }
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
        if showReserveSheet, let item = sheetItem {
            ReserveSheet(
                mode: sheetMode,
                item: item,
                confirm: { Task { await handleReservationConfirm(item) } },
                openMaps: { handleOpenMaps(for: item) },
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

    @MainActor private func handleReservationConfirm(_ item: CKTrashItem) async {
        do {
            try? await reserveBridge(item)
            await fetchFeedBridge()
            withAnimation(.easeOut(duration: 0.18)) {
                sheetMode = .info
            }
        }
    }

    private func handleOpenMaps(for item: CKTrashItem) {
        let mi = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
        mi.name = item.title
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
        guard let activeCard = deckState.activeCard else { return }
        
        await deckState.triggerPass()
        
        // Add to hidden set to remove from visible items
        hidden.insert(activeCard.id)
    }
    
    @MainActor
    private func handleReserve() async {
        guard let activeCard = deckState.activeCard else { return }
        
        do {
            try await deckState.triggerReserve()
            
            // Show reservation sheet
            sheetItem = activeCard
            sheetMode = .prompt
            withAnimation(.easeOut(duration: 0.18)) { 
                showReserveSheet = true 
            }
            
            // Complete the transition
            deckState.completeCardTransition()
            
        } catch {
            // Error handling is managed by DeckState
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

    // MARK: - Tiny bridge helpers (CloudKit / API / Stub)

    private func fetchFeedBridge() async {
        switch BACKEND_MODE {
        case .cloudKit:
            await ck.fetchFeed()
        case .api:
            // Fill when API is ready. Keep UI safe for now.
            await MainActor.run { ck.feed = [] }
        case .stub:
            await MainActor.run { ck.feed = [] }
        }
    }

    private func reserveBridge(_ item: CKTrashItem) async throws {
        switch BACKEND_MODE {
        case .cloudKit:
            try await ck.reserve(item) // matches your existing signature
        case .api:
            try await API.reserve(itemId: String(describing: item.id), holdHours: 6)
        case .stub:
            return
        }
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
        let item: CKTrashItem
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
                    Text("Reserved until \(reservedUntilString(item))").font(.headline)
                    HStack {
                        Label(item.city, systemImage: "mappin.circle")
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
        
        private func reservedUntilString(_ item: CKTrashItem) -> String {
            if let u = item.reservedUntil, u > Date() { return u.formatted(date: Date.FormatStyle.DateStyle.omitted, time: Date.FormatStyle.TimeStyle.shortened) }
            let u = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
            return u.formatted(date: Date.FormatStyle.DateStyle.omitted, time: Date.FormatStyle.TimeStyle.shortened)
        }
    }
    
    // MARK: - FeedMapScreen
    
    struct FeedMapScreen: View {
        @EnvironmentObject var svc: SupabaseService
        @EnvironmentObject var loc: LocationManager
        @Environment(\.dismiss) private var dismiss
        
        @State private var cameraPosition: MapCameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )
        
        private var streetPins: [TrashDTO] {
            let now = Date()
            return svc.feed.filter { item in
                // LIVE ONLY
                let live = (item.expiresAt > now)
                && (item.reservedUntil == nil || item.reservedUntil! <= now)
                && item.status.lowercased() == "available"
                // STREET ONLY
                let street = item.mode.lowercased() == "street"
                // HAS COORD
                let hasCoord = (item.exactCoordinate ?? item.approxCoordinate) != nil
                return live && street && hasCoord
            }
        }
        
        var body: some View {
            NavigationStack {
                Map(position: $cameraPosition) {
                    ForEach(streetPins, id: \.id) { item in
                        if let coord = item.exactCoordinate ?? item.approxCoordinate {
                            MapKit.Annotation("", coordinate: coord) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                                    .shadow(radius: 1)
                            }
                        }
                    }
                    
                    // Add user location annotation with green circle
                    UserAnnotation()
                }
                .ignoresSafeArea(.all)
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
                }
                .task {
                    if loc.authorization == .notDetermined { loc.request() }
                    if let c = loc.userLocation?.coordinate {
                        cameraPosition = .region(
                            MKCoordinateRegion(
                                center: c,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                        )
                    }
                }
            }
        }
        
        private func recenter() {
            // First request location permission if needed
            if loc.authorization == .notDetermined {
                loc.request()
            }
            
            // Try to get current location
            loc.requestOnce { coordinate in
                guard let coordinate = coordinate else {
                    print("Failed to get current location")
                    return
                }
                
                DispatchQueue.main.async {
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
    
    // MARK: - Minimal API client placeholder (kept for future .api mode)
    private enum API {
        struct ReservePayload: Encodable {
            let item_id: String
            let hold_hours: Int
        }
        
        static func reserve(itemId: String, holdHours: Int) async throws {
            var request = URLRequest(url: APIConfig.base.appending(path: APIConfig.reservePath))
            request.httpMethod = "POST"
            APIConfig.headers().forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ReservePayload(item_id: itemId, hold_hours: holdHours))
            let (_, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
    }
    
}
