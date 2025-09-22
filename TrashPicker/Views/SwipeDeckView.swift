//
//  SwipeDeckView.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//

import SwiftUI
import MapKit
import CloudKit

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
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager

    // Using CloudKit IDs so it matches your service
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
    
    // Camera and upload flow - unified with AppTabView
    @State private var showCamera = false
    @State private var showUploadForm = false
    @State private var capturedImage: UIImage?

    // Keep everything in CKTrashItem to match service
    private var visible: [CKTrashItem] {
        // If isMine(_:) exists, filter with it; otherwise just filter by hidden
        ck.feed.filter { !hidden.contains($0.id) && !(ck.isMine($0) ?? false) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GlassSegmented(selection: $seg)
                    .padding(.top, 8)


                GeometryReader { geo in

                    ZStack {
                        if visible.isEmpty {
                            EmptyFeedCTA(
                                refresh: { 
                                    Task { 
                                        await fetchFeedBridge()
                                        // Also clear hidden items to show refreshed content
                                        hidden.removeAll()
                                    } 
                                },
                                makePost: { showCamera = true }
                            )
                        } else {
                            DeckStack(
                                items: Array(visible.prefix(3)),
                                onReserve: { item in
                                    sheetItem = item
                                    sheetMode = .prompt
                                    withAnimation(.easeOut(duration: 0.18)) { showReserveSheet = true }
                                },
                                onPass: { item in
                                    hidden.insert(item.id)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }

                        // Reservation sheet
                        if showReserveSheet, let item = sheetItem {
                            ReserveSheet(
                                mode: sheetMode,
                                item: item,
                                confirm: {
                                    Task {
                                        try? await reserveBridge(item)
                                        await fetchFeedBridge()
                                        withAnimation(.easeOut(duration: 0.18)) { sheetMode = .info }
                                    }
                                },
                                openMaps: {
                                    let mi = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
                                    mi.name = item.title
                                    mi.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
                                },
                                close: {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        showReserveSheet = false
                                        sheetMode = .prompt
                                    }
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 16)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image("SwoopyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 28)
                        .accessibilityHidden(true)
                        .padding(.vertical, 4)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: seg) { newValue in
                if newValue == .map {
                    // Let the animation complete first, then show map
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showFeedMap = true
                    }
                }
            }
            .onChange(of: showFeedMap) { isPresented in
                if !isPresented {
                    // Reset pill when map is dismissed
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        seg = .feed
                    }
                }
            }
            .task {
                await fetchFeedBridge()
                // CloudKit expiry/maintenance should be done inside the service layer; removed here to avoid missing-member errors.
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { image in
                    if let image = image {
                        capturedImage = image
                        showUploadForm = true
                    }
                }
                .ignoresSafeArea(.all)
                .background(Color.black)
            }
            .fullScreenCover(isPresented: $showUploadForm) {
                NavigationStack {
                    UploadFindView(initialPhoto: capturedImage)
                        .environmentObject(svc)
                        .environmentObject(loc)
                }
                .onDisappear {
                    // Clean up after upload form dismisses
                    capturedImage = nil
                }
            }
            .fullScreenCover(isPresented: $showFeedMap) {
                FeedMapScreen()
                    .environmentObject(svc)
                    .environmentObject(loc)
                    .ignoresSafeArea()
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
        let items: [CKTrashItem]
        var onReserve: (CKTrashItem) -> Void
        var onPass: (CKTrashItem) -> Void
        
        var body: some View {
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    FeedCard(
                        item: item,
                        onReserve: { onReserve(item) },
                        onPass: { onPass(item) },
                        isTopCard: idx == 0 // Only the first card (top card) shows buttons
                    )
                    .zIndex(Double(100 - idx))
                    .scaleEffect(1 - CGFloat(idx) * 0.03)
                    .offset(y: CGFloat(idx) * 14)
                    .transition(.asymmetric(
                        insertion: .scale.combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: items.map(\.id))
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
        
        @State private var region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
            span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
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
                Map(coordinateRegion: $region, interactionModes: .all, showsUserLocation: true, annotationItems: streetPins) { item in
                    MapAnnotation(coordinate: item.exactCoordinate ?? item.approxCoordinate!) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .shadow(radius: 1)
                    }
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            recenter()
                        } label: {
                            Image(systemName: "location.circle.fill").font(.title2)
                        }
                    }
                }
                .task {
                    if loc.authorization == .notDetermined { loc.request() }
                    if let c = loc.userLocation?.coordinate {
                        region.center = c
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
                        self.region = MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
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
