//
//  ReservationsView.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - New Data Contract

struct ReservationRow: Identifiable, Codable {
    let id: String
    let reservation: ReservationData
    let post: PostData
    
    struct ReservationData: Codable {
        let id: String
        let status: ReservationStatus
        let requestedAt: Date
        let approvedAt: Date?
        
        enum ReservationStatus: String, Codable, CaseIterable {
            case pending, active, canceled, picked, expired
        }
    }
    
    struct PostData: Codable {
        let id: String
        let mode: PostMode
        let condition: PostCondition
        let images: [PostImage]
        let distanceKm: Double?
        let exactLocation: LocationCoordinate?
        let approxLocation: LocationCoordinate?
        let owner: OwnerData
        let description: String?
        
        enum PostMode: String, Codable {
            case street, home
        }
        
        enum PostCondition: String, Codable {
            case bad, good, excellent
            
            var displayText: String {
                switch self {
                case .bad: return "Needs Fixing"
                case .good: return "Usable"
                case .excellent: return "Like New"
                }
            }
        }
        
        struct PostImage: Codable {
            let url: String
            let orderIndex: Int
        }
        
        struct LocationCoordinate: Codable {
            let lng: Double
            let lat: Double
            
            var coordinate: CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
        }
        
        struct OwnerData: Codable {
            let id: String
            let name: String
            let phone: String?
            let avatarUrl: String?
            let memberSince: Date?
            let pickupsCount: Int?
        }
    }
    
    // Computed properties for business logic
    var expiresAt: Date {
        Calendar.current.date(byAdding: .hour, value: 6, to: reservation.requestedAt) ?? reservation.requestedAt
    }
    
    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
    
    var primaryImage: String? {
        post.images.first(where: { $0.orderIndex == 0 })?.url
    }
}

// MARK: - ReservationsView

struct ReservationsView: View {
    @EnvironmentObject var svc: SupabaseService
    @State private var reservations: [ReservationRow] = []
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // UI State Management
    @State private var loadingReservations: Set<String> = []
    @State private var showToast = false
    @State private var toastMessage = ""
    
    // Overlay State
    @State private var selectedReservation: ReservationRow?
    @State private var showDetailOverlay = false
    @Namespace private var imageTransition
    
    // Design tokens

    var body: some View {
        NavigationStack {
            Group {
                if activeReservations.isEmpty {
                    // Empty state with CTA
                    VStack(spacing: 16) {
                        Text("No active reservations yet.")
                            .font(.title2)
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                        
                        Text("Browse the feed to find items you'd like to reserve")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Go to Feed") {
                            // TODO: Navigate to feed tab
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 48)
                        .frame(minWidth: 120)
                        .background(AppTheme.ColorToken.primary)
                        .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Reservations list - OPTIMIZED
                    ScrollView {
                        LazyVStack(spacing: 12) { // REDUCED spacing
                            ForEach(activeReservations) { reservation in
                                ReservationCard(
                                    reservation: reservation,
                                    isLoading: loadingReservations.contains(reservation.id),
                                    imageTransition: imageTransition,
                                    onTap: {
                                        selectedReservation = reservation
                                        showDetailOverlay = true
                                    },
                                    onPickUp: { onPickup(reservationId: reservation.reservation.id) },
                                    onCancel: { onCancel(reservationId: reservation.reservation.id) },
                                    onDirections: { onDirections(post: reservation.post) },
                                    onContact: { onContact(post: reservation.post) }
                                )
                                .id(reservation.id) // EXPLICIT ID for better diffing
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.chromeSide)
                        .padding(.vertical, 12) // REDUCED padding
                    }
                    .scrollIndicators(.hidden) // HIDE scroll indicators
                }
            }
            .navigationTitle("Your reservations")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadReservations()
            }
            .overlay(
                // Toast overlay
                Group {
                    if showToast {
                        VStack {
                            Spacer()
                            Text(toastMessage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.black.opacity(0.8))
                                .clipShape(Capsule())
                                .padding(.horizontal, AppTheme.Spacing.chromeSide)
                                .padding(.bottom, 100)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.3), value: showToast)
                    }
                }
            )
            .overlay(
                // Detail overlay using BigCardOverlay
                Group {
                    if showDetailOverlay, let reservation = selectedReservation {
                        ZStack {
                            // Backdrop
                            Color.black.opacity(0.35)
                                .ignoresSafeArea(.all)
                                .onTapGesture {
                                    showDetailOverlay = false
                                    selectedReservation = nil
                                }
                                .zIndex(1)
                            
                            // Big card overlay
                            BigCardOverlay(
                                images: reservation.post.images.map { $0.url },
                                primaryInfo: primaryInfoText(for: reservation),
                                statusInfo: statusText(for: reservation),
                                statusColor: statusColor(for: reservation),
                                description: reservation.post.description,
                                mode: reservation.post.mode == .street ? .street : .home,
                                exactLocation: reservation.post.exactLocation?.coordinate,
                                ownerName: reservation.post.owner.name,
                                memberSince: reservation.post.owner.memberSince,
                                pickupsCount: reservation.post.owner.pickupsCount,
                                variant: reservationVariant(for: reservation),
                                onDismiss: {
                                    showDetailOverlay = false
                                    selectedReservation = nil
                                },
                                onPrimaryAction: {
                                    handlePrimaryAction(for: reservation)
                                },
                                onSecondaryAction: {
                                    onCancel(reservationId: reservation.reservation.id)
                                    showDetailOverlay = false
                                    selectedReservation = nil
                                },
                                onTertiaryAction: reservation.post.mode == .street ? {
                                    onDirections(post: reservation.post)
                                } : nil
                            )
                            .zIndex(2)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDetailOverlay)
                    }
                }
            )
        }
    }
    
    // MARK: - Computed Properties
    
    private var activeReservations: [ReservationRow] {
        reservations.filter { reservation in
            // Street: active and not expired, Home: pending or active
            (reservation.post.mode == .street ?
                (reservation.reservation.status == .active && !reservation.isExpired) :
                (reservation.reservation.status == .pending || reservation.reservation.status == .active)
            ) &&
            // Exclude canceled, picked, expired
            ![.canceled, .picked, .expired].contains(reservation.reservation.status)
        }
    }
    
    // MARK: - Actions
    
    private func loadReservations() async {
        // TODO: Load from backend
        // For now, using mock data that matches the spec
        await MainActor.run {
            reservations = createMockReservations()
        }
    }
    
    private func removeExpiredReservations() {
        let expiredIds = reservations.filter { $0.isExpired }.map { $0.id }
        if !expiredIds.isEmpty {
            reservations.removeAll { expiredIds.contains($0.id) }
            // TODO: Notify backend and return items to feed
        }
    }
    
    // MARK: - Backend Hooks
    
    private func onPickup(reservationId: String) {
        let alert = UIAlertController(
            title: "Picked up the item?",
            message: nil,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Not yet", style: .cancel))
        alert.addAction(UIAlertAction(title: "Yes", style: .default) { _ in
            Task { await handlePickup(reservationId: reservationId) }
        })
        
        presentAlert(alert)
    }
    
    private func onCancel(reservationId: String) {
        let alert = UIAlertController(
            title: "Cancel this reservation?",
            message: nil,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "No", style: .cancel))
        alert.addAction(UIAlertAction(title: "Yes", style: .destructive) { _ in
            Task { await handleCancel(reservationId: reservationId) }
        })
        
        presentAlert(alert)
    }
    
    private func onDirections(post: ReservationRow.PostData) {
        // Only for street mode
        guard post.mode == .street, let exactLoc = post.exactLocation else { return }
        
        let coordinate = exactLoc.coordinate
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = "Pickup Location"
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
    
    private func onContact(post: ReservationRow.PostData) {
        // Find the reservation to check status
        guard let reservation = reservations.first(where: { $0.post.id == post.id }) else { return }
        
        switch reservation.reservation.status {
        case .pending:
            // Show inline tip - no call
            showToastMessage("Waiting for giver's confirmation")
            
        case .active:
            // Open phone dialer
            guard let phoneNumber = post.owner.phone else {
                showToastMessage("No phone number available")
                return
            }
            
            let cleanNumber = phoneNumber.replacingOccurrences(of: " ", with: "")
            if let url = URL(string: "tel:\(cleanNumber)") {
                UIApplication.shared.open(url)
            }
            
        default:
            break
        }
    }
    
    // MARK: - Backend Actions
    
    @MainActor
    private func handlePickup(reservationId: String) async {
        // Add to loading state
        loadingReservations.insert(reservationId)
        
        do {
            // TODO: Implement actual backend call
            // await svc.updateReservationStatus(reservationId, status: .picked)
            
            // Simulate API call
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Remove from list on success
            reservations.removeAll { $0.reservation.id == reservationId }
            showToastMessage("Item marked as picked up")
            
        } catch {
            // Handle backend conflict or error
            showToastMessage("Failed to update reservation. Please try again.")
            await loadReservations() // Refresh list
        }
        
        // Remove from loading state
        loadingReservations.remove(reservationId)
    }
    
    @MainActor
    private func handleCancel(reservationId: String) async {
        // Add to loading state
        loadingReservations.insert(reservationId)
        
        do {
            // TODO: Implement actual backend call
            // await svc.updateReservationStatus(reservationId, status: .canceled)
            
            // Simulate API call
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Remove from list on success
            reservations.removeAll { $0.reservation.id == reservationId }
            showToastMessage("Reservation canceled")
            
        } catch {
            // Handle backend conflict or error
            showToastMessage("Failed to cancel reservation. Please try again.")
            await loadReservations() // Refresh list
        }
        
        // Remove from loading state
        loadingReservations.remove(reservationId)
    }
    
    // MARK: - BigCardOverlay Helper Methods
    
    private func primaryInfoText(for reservation: ReservationRow) -> String {
        switch reservation.post.mode {
        case .street:
            if let distance = reservation.post.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "From home (address hidden)"
        }
    }
    
    private func statusText(for reservation: ReservationRow) -> String {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            return "Pickup in: \(formatTimeRemaining(reservation.timeRemaining))"
        case (.home, .pending):
            return "Waiting for giver's confirmation"
        case (.home, .active):
            return "Confirmed! Contact the owner to pick it up"
        default:
            return "Posted \(formatRelativeTime(reservation.reservation.requestedAt)) ago"
        }
    }
    
    private func statusColor(for reservation: ReservationRow) -> Color {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .pending):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .active):
            return AppTheme.ColorToken.danger // #6AA54A
        default:
            return AppTheme.ColorToken.mutedGray
        }
    }
    
    private func reservationVariant(for reservation: ReservationRow) -> BigCardOverlay.Variant {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            return .reservations(.streetActive)
        case (.home, .pending):
            return .reservations(.homePending)
        case (.home, .active):
            return .reservations(.homeActive)
        default:
            return .reservations(.homePending)
        }
    }
    
    private func handlePrimaryAction(for reservation: ReservationRow) {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            onPickup(reservationId: reservation.reservation.id)
            showDetailOverlay = false
            selectedReservation = nil
        case (.home, .pending):
            onContact(post: reservation.post)
        case (.home, .active):
            onContact(post: reservation.post)
        default:
            break
        }
    }
    
    private func formatTimeRemaining(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) % 3600 / 60
        return "\(hours)h \(minutes)m"
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    // MARK: - Helper Methods
    
    private func presentAlert(_ alert: UIAlertController) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else { return }
        
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }
        
        topController.present(alert, animated: true)
    }
    
    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
        
        // Auto-hide after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showToast = false
        }
    }
    
    // MARK: - Mock Data
    
    private func createMockReservations() -> [ReservationRow] {
        [
            // Street reservation
            ReservationRow(
                id: "1",
                reservation: ReservationRow.ReservationData(
                    id: "res-1",
                    status: .active,
                    requestedAt: Date().addingTimeInterval(-3600), // 1 hour ago
                    approvedAt: Date().addingTimeInterval(-3500)
                ),
                post: ReservationRow.PostData(
                    id: "post-1",
                    mode: .street,
                    condition: .good,
                    images: [ReservationRow.PostData.PostImage(url: "https://picsum.photos/200/200?random=1", orderIndex: 0)],
                    distanceKm: 0.8,
                    exactLocation: ReservationRow.PostData.LocationCoordinate(lng: 2.1686, lat: 41.3874),
                    approxLocation: nil,
                    owner: ReservationRow.PostData.OwnerData(
                        id: "owner-1",
                        name: "John Doe",
                        phone: "+34123456789",
                        avatarUrl: nil,
                        memberSince: Date().addingTimeInterval(-86400 * 365),
                        pickupsCount: 15
                    ),
                    description: "Great condition chair, perfect for home office"
                )
            ),
            // Home reservation - pending
            ReservationRow(
                id: "2",
                reservation: ReservationRow.ReservationData(
                    id: "res-2",
                    status: .pending,
                    requestedAt: Date().addingTimeInterval(-7200), // 2 hours ago
                    approvedAt: nil
                ),
                post: ReservationRow.PostData(
                    id: "post-2",
                    mode: .home,
                    condition: .good,
                    images: [ReservationRow.PostData.PostImage(url: "https://picsum.photos/200/200?random=2", orderIndex: 0)],
                    distanceKm: 1.2,
                    exactLocation: nil,
                    approxLocation: ReservationRow.PostData.LocationCoordinate(lng: 2.1700, lat: 41.3900),
                    owner: ReservationRow.PostData.OwnerData(
                        id: "owner-2",
                        name: "Jane Smith",
                        phone: "+34987654321",
                        avatarUrl: nil,
                        memberSince: Date().addingTimeInterval(-86400 * 180),
                        pickupsCount: 8
                    ),
                    description: nil
                )
            ),
            // Home reservation - confirmed with contact
            ReservationRow(
                id: "3",
                reservation: ReservationRow.ReservationData(
                    id: "res-3",
                    status: .active,
                    requestedAt: Date().addingTimeInterval(-10800), // 3 hours ago
                    approvedAt: Date().addingTimeInterval(-9000)
                ),
                post: ReservationRow.PostData(
                    id: "post-3",
                    mode: .home,
                    condition: .excellent,
                    images: [ReservationRow.PostData.PostImage(url: "https://picsum.photos/200/200?random=3", orderIndex: 0)],
                    distanceKm: 2.1,
                    exactLocation: nil,
                    approxLocation: ReservationRow.PostData.LocationCoordinate(lng: 2.1650, lat: 41.3850),
                    owner: ReservationRow.PostData.OwnerData(
                        id: "owner-3",
                        name: "Maria Garcia",
                        phone: "+34555123456",
                        avatarUrl: nil,
                        memberSince: Date().addingTimeInterval(-86400 * 730),
                        pickupsCount: 23
                    ),
                    description: "Barely used, excellent condition"
                )
            )
        ]
    }
}

// MARK: - ReservationCard

private struct ReservationCard: View {
    let reservation: ReservationRow
    let isLoading: Bool
    let imageTransition: Namespace.ID
    let onTap: () -> Void
    let onPickUp: () -> Void
    let onCancel: () -> Void
    let onDirections: () -> Void
    let onContact: () -> Void
    
    @State private var timeRemaining: TimeInterval
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // Design tokens
  
    init(reservation: ReservationRow, isLoading: Bool = false, imageTransition: Namespace.ID, onTap: @escaping () -> Void, onPickUp: @escaping () -> Void, onCancel: @escaping () -> Void, onDirections: @escaping () -> Void, onContact: @escaping () -> Void) {
        self.reservation = reservation
        self.isLoading = isLoading
        self.imageTransition = imageTransition
        self.onTap = onTap
        self.onPickUp = onPickUp
        self.onCancel = onCancel
        self.onDirections = onDirections
        self.onContact = onContact
        self._timeRemaining = State(initialValue: reservation.timeRemaining)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed content only - tap opens overlay
            HStack(alignment: .top, spacing: 12) {
                // Thumbnail with matched geometry effect
                AsyncImage(url: URL(string: reservation.primaryImage ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(AppTheme.ColorToken.mutedGray.opacity(0.2))
                }
                .frame(width: AppSize.thumbnail, height: AppSize.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .matchedGeometryEffect(id: "image-\(reservation.id)", in: imageTransition)
                
                // Text content
                VStack(alignment: .leading, spacing: 12) {
                    // Condition line
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppTheme.ColorToken.accent)
                            .frame(width: 8, height: 8)
                        
                        Text(reservation.post.condition.displayText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.ColorToken.primary)
                        
                        Spacer()
                    }
                    
                    // Primary info line
                    Text(primaryInfoText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    // Status line
                    Text(statusText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(statusColor)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            
            // Buttons row
            buttonsRow
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .onTapGesture {
            onTap()
        }
        .onReceive(timer) { _ in
            if reservation.post.mode == .street {
                timeRemaining = reservation.timeRemaining
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var primaryInfoText: String {
        switch reservation.post.mode {
        case .street:
            if let distance = reservation.post.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "Home listing"
        }
    }
    
    private var expandedPrimaryInfoText: String {
        switch reservation.post.mode {
        case .street:
            if let distance = reservation.post.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "From home (address hidden)"
        }
    }
    
    private var statusText: String {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            return "Pickup in: \(formatTimeRemaining(timeRemaining))"
        case (.home, .pending):
            return "Waiting for confirmation"
        case (.home, .active):
            return "Confirmed! Contact owner"
        default:
            return ""
        }
    }
    
    private var statusColor: Color {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .pending):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .active):
            return AppTheme.ColorToken.danger // #6AA54A
        default:
            return .secondary
        }
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private var locationInfoView: some View {
        switch reservation.post.mode {
        case .street:
            if let exactLocation = reservation.post.exactLocation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact Location")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    // REMOVED expensive map preview - just show coordinates
                    Text("Lat: \(exactLocation.lat, specifier: "%.4f"), Lng: \(exactLocation.lng, specifier: "%.4f")")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
        case .home:
            Text("Location details are kept private for home pickups")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(AppTheme.ColorToken.mutedGray)
        }
    }
    
    @ViewBuilder
    private var sharedByRow: some View {
        HStack(spacing: 12) {
            // SIMPLIFIED avatar - no overlay to reduce draw calls
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.ColorToken.primary.opacity(0.15))
                .frame(width: 28, height: 28)
            
            VStack(alignment: .leading, spacing: 1) {
                Text("Shared by \(reservation.post.owner.name)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                if let pickupsCount = reservation.post.owner.pickupsCount {
                    Text("\(pickupsCount) pickups")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    // MARK: - Buttons Row
    
    @ViewBuilder
    private var buttonsRow: some View {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            // Street + active → Pick up (Primary filled), Cancel (White), Directions (Accent filled)
            HStack(spacing: 12) {
                Button(action: onPickUp) {
                    Text("Pick up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(AppTheme.ColorToken.primary)
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .overlay(
                    RoundedRectangle(cornerRadius: 29)
                        .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
                )
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
                
                Button(action: onDirections) {
                    Text("Directions")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.ColorToken.primary)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(AppTheme.ColorToken.accent)
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
            }
            
        case (.home, .pending):
            // Home + pending → Contact (disabled), Cancel (White)
            HStack(spacing: 12) {
                Button(action: onContact) {
                    Text("Contact")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(AppTheme.ColorToken.primary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .disabled(true)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .overlay(
                    RoundedRectangle(cornerRadius: 29)
                        .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
                )
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
            }
            
        case (.home, .active):
            // Home + approved → Contact (Primary filled), Cancel (White)
            HStack(spacing: 12) {
                Button(action: onContact) {
                    Text("Contact")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(AppTheme.ColorToken.primary)
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(height: AppSize.buttonHeight)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 29))
                .overlay(
                    RoundedRectangle(cornerRadius: 29)
                        .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
                )
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
            }
            
        default:
            EmptyView()
        }
    }
    
    private func formatTimeRemaining(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) % 3600 / 60
        return "\(hours)h \(minutes)m"
    }
}
