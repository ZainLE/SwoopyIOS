////
////  ReservationsView.swift
////  TrashPicker
////
//
//import SwiftUI
//import MapKit
//import CoreLocation
//
//// MARK: - Supporting Types
//
//enum ReservationStatus: String, CaseIterable {
//    case pending = "pending"
//    case active = "active"
//    case picked = "picked"
//    case canceled = "canceled"
//    case expired = "expired"
//}
//
//// MARK: - Flat UI Model for Reservations
//
//struct ReservationRow: Identifiable {
//    // identity
//    let id: String
//
//    // post basics
//    let title: String
//    let description: String?
//
//    // post meta
//    let condition: ItemCondition
//    let mode: ItemMode
//    let distanceKm: Double?
//    let primaryImageURL: URL?
//
//    // owner (uploader)
//    let ownerName: String
//    let ownerPhone: String?
//
//    // reservation state
//    let status: ReservationStatus
//    let requestedAt: Date
//    let approvedAt: Date?
//
//    // locations
//    let exactCoordinate: CLLocationCoordinate2D?   // for street
//    
//    // Computed properties for business logic
//    var expiresAt: Date {
//        Calendar.current.date(byAdding: .hour, value: 6, to: requestedAt) ?? requestedAt
//    }
//
//    // Fire once when auth is ready
//    @MainActor private func maybeLoadReservations() async {
//        if api == nil { api = ApiService(supabaseService: svc) }
//        guard svc.hasAuthToken, didKickOff == false else { return }
//        didKickOff = true
//        await loadReservations()
//    }
//
//    var isExpired: Bool {
//        Date() > expiresAt
//    }
//    
//    var timeRemaining: TimeInterval {
//        max(0, expiresAt.timeIntervalSinceNow)
//    }
//}
//
//// Nice helpers you can use directly in the View:
//extension ReservationRow {
//    var statusText: String {
//        switch status {
//        case .pending:  return "Pending confirmation"
//        case .active:   return "Active"
//        case .picked:   return "Completed"
//        case .canceled: return "Canceled"
//        case .expired:  return "Expired"
//        }
//    }
//}
//
//extension ReservationRow {
//    init(_ r: Reservation) {
//        let p = r.post
//
//        id = r.id
//        title = p.title
//        description = p.description
//        condition = p.condition
//        mode = p.mode
//        distanceKm = p.distance
//        primaryImageURL = p.primaryImageURL
//
//        ownerName = p.owner?.fullName ?? "Unknown"
//        ownerPhone = p.owner?.phone
//
//        // status + dates
//        status = ReservationStatus(rawValue: r.status) ?? .pending
//        let iso = ISO8601DateFormatter()
//        requestedAt = iso.date(from: r.requestedAt) ?? Date()
//        approvedAt = r.approvedAt.flatMap { iso.date(from: $0) }
//
//        // street coordinate (using Location.coordinate extension)
//        exactCoordinate = p.exactLocation?.coordinate
//    }
//}
//
//// MARK: - ReservationsView
//
//struct ReservationsView: View {
//    @EnvironmentObject var svc: SupabaseService
//    @Environment(\.dismiss) private var dismiss
//    // Optional callback injected by parent to switch tabs to Feed
//    var onGoToFeed: (() -> Void)? = nil
//    @State private var api: ApiService?
//    @State private var didKickOff = false
//    @State private var reservations: [ReservationRow] = []
//    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
//    
//    // UI State Management
//    @State private var loadingReservations: Set<String> = []
//    @State private var showToast = false
//    @State private var toastMessage = ""
//    @State private var isLoading = false
//    @State private var errorMessage: String?
//    @State private var showError = false
//    
//    // Overlay State
//    @State private var selectedReservation: ReservationRow?
//    @State private var showDetailOverlay = false
//    @Namespace private var imageTransition
//    
//    // Design tokens
//
//    var body: some View {
//        NavigationStack {
//            Group {
//                if isLoading {
//                    // Loading state
//                    VStack(spacing: 16) {
//                        ProgressView()
//                            .scaleEffect(1.2)
//                            .tint(AppTheme.ColorToken.primary)
//                        
//                        Text("Loading your reservations...")
//                            .font(.system(size: 16, weight: .medium))
//                            .foregroundColor(.secondary)
//                    }
//                    .frame(maxWidth: .infinity, maxHeight: .infinity)
//                } else if showError {
//                    // Error state
//                    VStack(spacing: 16) {
//                        Image(systemName: "exclamationmark.triangle")
//                            .font(.system(size: 48))
//                            .foregroundColor(.orange)
//                        
//                        Text(errorMessage ?? "Failed to load reservations")
//                            .font(.system(size: 16, weight: .medium))
//                            .foregroundColor(.primary)
//                            .multilineTextAlignment(.center)
//                        
//                        Button("Try Again") {
//                            Task {
//                                await loadReservations()
//                            }
//                        }
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.white)
//                        .padding(.horizontal, 24)
//                        .padding(.vertical, 12)
//                        .background(AppTheme.ColorToken.primary)
//                        .clipShape(Capsule())
//                    }
//                    .frame(maxWidth: .infinity, maxHeight: .infinity)
//                    .padding(.horizontal, 32)
//                } else if activeReservations.isEmpty {
//                    // Empty state with CTA
//                    VStack(spacing: 16) {
//                        Text("No active reservations yet.")
//                            .font(.title2)
//                            .foregroundColor(AppTheme.ColorToken.mutedGray)
//                        
//                        Text("Browse the feed to find items you'd like to reserve")
//                            .font(.body)
//                            .foregroundColor(.secondary)
//                            .multilineTextAlignment(.center)
//                        
//                        Button("Go to Feed") {
//                            goToFeed()
//                        }
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.white)
//                        .frame(height: 48)
//                        .frame(minWidth: 120)
//                        .background(AppTheme.ColorToken.primary)
//                        .clipShape(Capsule())
//                    }
//                    .frame(maxWidth: .infinity, maxHeight: .infinity)
//                } else {
//                    // Reservations list - OPTIMIZED
//                    ScrollView {
//                        LazyVStack(spacing: 12) { // REDUCED spacing
//                            ForEach(activeReservations) { reservation in
//                                ReservationCard(
//                                    reservation: reservation,
//                                    isLoading: loadingReservations.contains(reservation.id),
//                                    imageTransition: imageTransition,
//                                    onTap: {
//                                        selectedReservation = reservation
//                                        showDetailOverlay = true
//                                    },
//                                    onPickUp: { onPickup(reservationId: reservation.id) },
//                                    onCancel: { onCancel(reservationId: reservation.id) },
//                                    onDirections: { onDirections(reservation: reservation) },
//                                    onContact: { onContact(reservation: reservation) }
//                                )
//                                .id(reservation.id) // EXPLICIT ID for better diffing
//                            }
//                        }
//                        .padding(.horizontal, AppTheme.Spacing.chromeSide)
//                        .padding(.vertical, 12) // REDUCED padding
//                    }
//                    .refreshable {
//                        await loadReservations()
//                    }
//                    .scrollIndicators(.hidden) // HIDE scroll indicators
//                }
//            }
//            .navigationTitle("Your reservations")
//            .navigationBarTitleDisplayMode(.inline)
//            .task {
//                if api == nil { api = ApiService(supabaseService: svc) }
//                await maybeLoadReservations()
//            }
//            .onChange(of: svc.isAuthenticated) { _, _ in
//                Task { await maybeLoadReservations() }
//            }
//            .onChange(of: svc.session) { _, _ in
//                Task { await maybeLoadReservations() }
//            }
//            .overlay(
//                // Toast overlay
//                Group {
//                    if showToast {
//                        VStack {
//                            Spacer()
//                            Text(toastMessage)
//                                .font(.system(size: 14, weight: .medium))
//                                .foregroundColor(.white)
//                                .padding(.horizontal, 16)
//                                .padding(.vertical, 12)
//                                .background(Color.black.opacity(0.8))
//                                .clipShape(Capsule())
//                                .padding(.horizontal, AppTheme.Spacing.chromeSide)
//                                .padding(.bottom, 100)
//                        }
//                        .transition(.move(edge: .bottom).combined(with: .opacity))
//                        .animation(.easeInOut(duration: 0.3), value: showToast)
//                    }
//                }
//            )
//            .overlay(
//                // Detail overlay using BigCardOverlay
//                Group {
//                    if showDetailOverlay, let reservation = selectedReservation {
//                        ZStack {
//                            // Backdrop
//                            Color.black.opacity(0.35)
//                                .ignoresSafeArea(.all)
//                                .onTapGesture {
//                                    showDetailOverlay = false
//                                    selectedReservation = nil
//                                }
//                                .zIndex(1)
//                            
//                            // Big card overlay
//                            BigCardOverlay(
//                                images: reservation.primaryImageURL != nil ? [reservation.primaryImageURL!.absoluteString] : [],
//                                primaryInfo: primaryInfoText(for: reservation),
//                                statusInfo: statusText(for: reservation),
//                                statusColor: statusColor(for: reservation),
//                                description: reservation.description,
//                                mode: reservation.mode == .street ? .street : .home,
//                                exactLocation: reservation.exactCoordinate,
//                                ownerName: reservation.ownerName,
//                                memberSince: nil, // Not available in simplified model
//                                pickupsCount: nil, // Not available in simplified model
//                                variant: reservationVariant(for: reservation),
//                                onDismiss: {
//                                    showDetailOverlay = false
//                                    selectedReservation = nil
//                                },
//                                onPrimaryAction: {
//                                    handlePrimaryAction(for: reservation)
//                                },
//                                onSecondaryAction: {
//                                    onCancel(reservationId: reservation.id)
//                                    showDetailOverlay = false
//                                    selectedReservation = nil
//                                },
//                                onTertiaryAction: reservation.mode == .street ? {
//                                    onDirections(reservation: reservation)
//                                } : nil
//                            )
//                            .zIndex(2)
//                        }
//                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
//                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDetailOverlay)
//                    }
//                }
//            )
//        }
//    }
//    
//    // Use global svc.hasAuthToken helper
//    
//    // MARK: - Computed Properties
//    
//    private var activeReservations: [ReservationRow] {
//        reservations.filter { reservation in
//            // Street: active and not expired, Home: pending or active
//            (reservation.mode == .street ?
//                (reservation.status == .active && !reservation.isExpired) :
//                (reservation.status == .pending || reservation.status == .active)
//            ) &&
//            // Exclude canceled, picked, expired
//            ![.canceled, .picked, .expired].contains(reservation.status)
//        }
//    }
//    
//    // MARK: - Actions
//    
//    @MainActor
//    private func loadReservations() async {
//        guard let api else { return }
//        isLoading = true
//        showError = false
//        
//        do {
//            let apiReservations = try await fetchWithRetry(svc: svc) {
//                try await api.getMyReservations()
//            }
//            await MainActor.run {
//                reservations = apiReservations.map(ReservationRow.init)
//                isLoading = false
//            }
//        } catch {
//            #if DEBUG
//            print("Failed to load reservations: \(error.localizedDescription)")
//            #endif
//            reservations = []
//            isLoading = false
//            
//            if error is AuthError || error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
//                errorMessage = "Session expired. Please sign in again."
//            } else {
//                errorMessage = "Failed to load reservations. Please try again."
//            }
//            showError = true
//        }
//    }
//    
//    @MainActor
//    private func removeExpiredReservations() {
//        let expiredIds = reservations.filter { $0.isExpired }.map { $0.id }
//        if !expiredIds.isEmpty {
//            reservations.removeAll { expiredIds.contains($0.id) }
//            // TODO: Notify backend and return items to feed
//        }
//    }
//    
//    // MARK: - Backend Hooks
//    
//    private func onPickup(reservationId: String) {
//        let alert = UIAlertController(
//            title: "Picked up the item?",
//            message: nil,
//            preferredStyle: .alert
//        )
//        
//        alert.addAction(UIAlertAction(title: "Not yet", style: .cancel))
//        alert.addAction(UIAlertAction(title: "Yes", style: .default) { _ in
//            Task { await handlePickup(reservationId: reservationId) }
//        })
//        
//        presentAlert(alert)
//    }
//    
//    private func onCancel(reservationId: String) {
//        let alert = UIAlertController(
//            title: "Cancel this reservation?",
//            message: nil,
//            preferredStyle: .alert
//        )
//        
//        alert.addAction(UIAlertAction(title: "No", style: .cancel))
//        alert.addAction(UIAlertAction(title: "Yes", style: .destructive) { _ in
//            Task { await handleCancel(reservationId: reservationId) }
//        })
//        
//        presentAlert(alert)
//    }
//    
//    private func onDirections(reservation: ReservationRow) {
//        // Only for street mode
//        guard reservation.mode == .street, let exactCoord = reservation.exactCoordinate else { return }
//        
//        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: exactCoord))
//        mapItem.name = reservation.title
//        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
//    }
//    
//    private func onContact(reservation: ReservationRow) {
//        switch reservation.status {
//        case .pending:
//            // Show inline tip - no call
//            showToastMessage("Waiting for giver's confirmation")
//            
//        case .active:
//            // Open phone dialer
//            guard let phoneNumber = reservation.ownerPhone else {
//                showToastMessage("No phone number available")
//                return
//            }
//            
//            let cleanNumber = phoneNumber.replacingOccurrences(of: " ", with: "")
//            if let url = URL(string: "tel:\(cleanNumber)") {
//                UIApplication.shared.open(url)
//            }
//            
//        default:
//            break
//        }
//    }
//    
//    // MARK: - Backend Actions
//    
//    @MainActor
//    private func handlePickup(reservationId: String) async {
//        guard let api else { return }
//        // Add to loading state
//        loadingReservations.insert(reservationId)
//        
//        do {
//            // Call API to complete the reservation with retry
//            try await fetchWithRetry(svc: svc) {
//                try await api.completeReservation(reservationId)
//            }
//            
//            // Remove from list on success
//            reservations.removeAll { $0.id == reservationId }
//            showToastMessage("Item marked as picked up")
//            
//        } catch {
//            // Handle backend conflict or error
//            if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
//                showToastMessage("Session expired. Please sign in again.")
//            } else {
//                showToastMessage("Failed to update reservation. Please try again.")
//                await loadReservations() // Refresh list
//            }
//        }
//        
//        // Remove from loading state
//        loadingReservations.remove(reservationId)
//    }
//    
//    @MainActor
//    private func handleCancel(reservationId: String) async {
//        guard let api else { return }
//        // Add to loading state
//        loadingReservations.insert(reservationId)
//        
//        // Find the reservation
//        guard let reservation = reservations.first(where: { $0.id == reservationId }) else {
//            loadingReservations.remove(reservationId)
//            showToastMessage("Reservation not found.")
//            return
//        }
//        
//        do {
//            // Call API to cancel the reservation using reservation ID with retry
//            try await fetchWithRetry(svc: svc) {
//                try await api.cancelReservation(reservationId)
//            }
//            
//            // Remove from list on success
//            reservations.removeAll { $0.id == reservationId }
//            showToastMessage("Reservation canceled")
//            
//        } catch {
//            // Handle backend conflict or error
//            if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
//                showToastMessage("Session expired. Please sign in again.")
//            } else {
//                showToastMessage("Failed to cancel reservation. Please try again.")
//                await loadReservations() // Refresh list
//            }
//        }
//        
//        // Remove from loading state
//        loadingReservations.remove(reservationId)
//    }
//    
//    // MARK: - BigCardOverlay Helper Methods
//    
//    private func primaryInfoText(for reservation: ReservationRow) -> String {
//        switch reservation.mode {
//        case .street:
//            if let distance = reservation.distanceKm {
//                return String(format: "≈ %.1f km away", distance)
//            } else {
//                return "Street pickup"
//            }
//        case .home:
//            return "From home (address hidden)"
//        }
//    }
//    
//    private func statusText(for reservation: ReservationRow) -> String {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            return "Pickup in: \(formatTimeRemaining(reservation.timeRemaining))"
//        case (.home, .pending):
//            return "Waiting for giver's confirmation"
//        case (.home, .active):
//            return "Confirmed! Contact the owner to pick it up"
//        default:
//            return "Posted \(formatRelativeTime(reservation.requestedAt)) ago"
//        }
//    }
//    
//    private func statusColor(for reservation: ReservationRow) -> Color {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            return AppTheme.ColorToken.danger // #C44242
//        case (.home, .pending):
//            return AppTheme.ColorToken.danger // #C44242
//        case (.home, .active):
//            return AppTheme.ColorToken.danger // #6AA54A
//        default:
//            return AppTheme.ColorToken.mutedGray
//        }
//    }
//    
//    private func reservationVariant(for reservation: ReservationRow) -> BigCardOverlay.Variant {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            return .reservations(.streetActive)
//        case (.home, .pending):
//            return .reservations(.homePending)
//        case (.home, .active):
//            return .reservations(.homeActive)
//        default:
//            return .reservations(.homePending)
//        }
//    }
//    
//    private func handlePrimaryAction(for reservation: ReservationRow) {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            onPickup(reservationId: reservation.id)
//            showDetailOverlay = false
//            selectedReservation = nil
//        case (.home, .pending):
//            onContact(reservation: reservation)
//        case (.home, .active):
//            onContact(reservation: reservation)
//        default:
//            break
//        }
//    }
//    
//    private func formatTimeRemaining(_ timeInterval: TimeInterval) -> String {
//        let hours = Int(timeInterval) / 3600
//        let minutes = Int(timeInterval) % 3600 / 60
//        return "\(hours)h \(minutes)m"
//    }
//    
//    private func formatRelativeTime(_ date: Date) -> String {
//        let formatter = RelativeDateTimeFormatter()
//        formatter.unitsStyle = .abbreviated
//        return formatter.localizedString(for: date, relativeTo: Date())
//    }
//    
//    // MARK: - Helper Methods
//    
//    private func goToFeed() {
//        if let onGoToFeed {
//            onGoToFeed()
//        } else {
//            dismiss()
//        }
//    }
//    
//    private func presentAlert(_ alert: UIAlertController) {
//        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
//              let window = windowScene.windows.first,
//              let rootViewController = window.rootViewController else { return }
//        
//        var topController = rootViewController
//        while let presented = topController.presentedViewController {
//            topController = presented
//        }
//        
//        topController.present(alert, animated: true)
//    }
//    
//    @MainActor
//    private func showToastMessage(_ message: String) {
//        toastMessage = message
//        showToast = true
//        
//        // Auto-hide after 3 seconds
//        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//            withAnimation {
//                showToast = false
//            }
//        }
//    }
//
//}
//
//// MARK: - ReservationCard
//
//
//private struct ReservationCard: View {
//    let reservation: ReservationRow
//    let isLoading: Bool
//    let imageTransition: Namespace.ID
//    let onTap: () -> Void
//    let onPickUp: () -> Void
//    let onCancel: () -> Void
//    let onDirections: () -> Void
//    let onContact: () -> Void
//    
//    @State private var timeRemaining: TimeInterval
//    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
//    
//    // Design tokens
//  
//    init(reservation: ReservationRow, isLoading: Bool = false, imageTransition: Namespace.ID, onTap: @escaping () -> Void, onPickUp: @escaping () -> Void, onCancel: @escaping () -> Void, onDirections: @escaping () -> Void, onContact: @escaping () -> Void) {
//        self.reservation = reservation
//        self.isLoading = isLoading
//        self.imageTransition = imageTransition
//        self.onTap = onTap
//        self.onPickUp = onPickUp
//        self.onCancel = onCancel
//        self.onDirections = onDirections
//        self.onContact = onContact
//        self._timeRemaining = State(initialValue: reservation.timeRemaining)
//    }
//    
//    var body: some View {
//        VStack(alignment: .leading, spacing: 0) {
//            // Collapsed content only - tap opens overlay
//            HStack(alignment: .top, spacing: 12) {
//                // Thumbnail with matched geometry effect
//                AsyncImage(url: reservation.primaryImageURL) { image in
//                    image
//                        .resizable()
//                        .aspectRatio(contentMode: .fill)
//                } placeholder: {
//                    Rectangle()
//                        .fill(AppTheme.ColorToken.mutedGray.opacity(0.2))
//                }
//                .frame(width: AppSize.thumbnail, height: AppSize.thumbnail)
//                .clipShape(RoundedRectangle(cornerRadius: 12))
//                .matchedGeometryEffect(id: "image-\(reservation.id)", in: imageTransition)
//                
//                // Text content
//                VStack(alignment: .leading, spacing: 12) {
//                    // Condition line
//                    HStack(spacing: 6) {
//                        Circle()
//                            .fill(AppTheme.ColorToken.accent)
//                            .frame(width: 8, height: 8)
//                        
//                        Text(reservation.condition.displayText)
//                            .font(.system(size: 13, weight: .semibold))
//                            .foregroundColor(AppTheme.ColorToken.primary)
//                        
//                        Spacer()
//                    }
//                    
//                    // Primary info line
//                    Text(primaryInfoText)
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.primary)
//                    
//                    // Status line
//                    Text(statusText)
//                        .font(.system(size: 12, weight: .regular))
//                        .foregroundColor(statusColor)
//                }
//            }
//            .padding(.top, 16)
//            .padding(.horizontal, 16)
//            
//            // Buttons row
//            buttonsRow
//                .padding(.top, 16)
//                .padding(.horizontal, 16)
//                .padding(.bottom, 16)
//        }
//        .background(Color(.systemBackground))
//        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
//        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
//        .onTapGesture {
//            onTap()
//        }
//        .onReceive(timer) { _ in
//            if reservation.mode == .street {
//                timeRemaining = reservation.timeRemaining
//            }
//        }
//    }
//    
//    // MARK: - Computed Properties
//    
//    private var primaryInfoText: String {
//        switch reservation.mode {
//        case .street:
//            if let distance = reservation.distanceKm {
//                return String(format: "≈ %.1f km away", distance)
//            } else {
//                return "Street pickup"
//            }
//        case .home:
//            return "Home listing"
//        }
//    }
//    
//    private var expandedPrimaryInfoText: String {
//        switch reservation.mode {
//        case .street:
//            if let distance = reservation.distanceKm {
//                return String(format: "≈ %.1f km away", distance)
//            } else {
//                return "Street pickup"
//            }
//        case .home:
//            return "From home (address hidden)"
//        }
//    }
//    
//    private var statusText: String {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            return "Pickup in: \(formatTimeRemaining(timeRemaining))"
//        case (.home, .pending):
//            return "Waiting for confirmation"
//        case (.home, .active):
//            return "Confirmed! Contact owner"
//        default:
//            return ""
//        }
//    }
//    
//    private var statusColor: Color {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            return AppTheme.ColorToken.danger // #C44242
//        case (.home, .pending):
//            return AppTheme.ColorToken.danger // #C44242
//        case (.home, .active):
//            return AppTheme.ColorToken.danger // #6AA54A
//        default:
//            return .secondary
//        }
//    }
//    
//    // MARK: - Helper Views
//    
//    @ViewBuilder
//    private var locationInfoView: some View {
//        switch reservation.mode {
//        case .street:
//            if let exactCoord = reservation.exactCoordinate {
//                VStack(alignment: .leading, spacing: 6) {
//                    Text("Exact Location")
//                        .font(.system(size: 14, weight: .semibold))
//                        .foregroundColor(.primary)
//                    
//                    // REMOVED expensive map preview - just show coordinates
//                    Text("Lat: \(exactCoord.latitude, specifier: "%.4f"), Lng: \(exactCoord.longitude, specifier: "%.4f")")
//                        .font(.system(size: 12))
//                        .foregroundColor(.secondary)
//                }
//            }
//            
//        case .home:
//            Text("Location details are kept private for home pickups")
//                .font(.system(size: 14, weight: .regular))
//                .foregroundColor(AppTheme.ColorToken.mutedGray)
//        }
//    }
//    
//    @ViewBuilder
//    private var sharedByRow: some View {
//        HStack(spacing: 12) {
//            // SIMPLIFIED avatar - no overlay to reduce draw calls
//            RoundedRectangle(cornerRadius: 4)
//                .fill(AppTheme.ColorToken.primary.opacity(0.15))
//                .frame(width: 28, height: 28)
//            
//            VStack(alignment: .leading, spacing: 1) {
//                Text("Shared by \(reservation.ownerName)")
//                    .font(.system(size: 14, weight: .medium))
//                    .foregroundColor(.primary)
//                
//                // Note: pickupsCount not available in flat model
//                Text("Community member")
//                    .font(.system(size: 12))
//                    .foregroundColor(.secondary)
//            }
//            
//            Spacer()
//        }
//    }
//    
//    // MARK: - Helper Methods
//    
//    private func formatRelativeTime(_ date: Date) -> String {
//        let formatter = RelativeDateTimeFormatter()
//        formatter.unitsStyle = .abbreviated
//        return formatter.localizedString(for: date, relativeTo: Date())
//    }
//    
//    // MARK: - Buttons Row
//    
//    @ViewBuilder
//    private var buttonsRow: some View {
//        switch (reservation.mode, reservation.status) {
//        case (.street, .active):
//            // Street → Left-aligned buttons: "Directions", "Picked up", "Cancel"
//            HStack(spacing: 12) {
//                Button(action: onDirections) {
//                    Text("Directions")
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(AppTheme.ColorToken.primary)
//                        .frame(height: AppSize.buttonHeight)
//                        .frame(maxWidth: .infinity)
//                }
//                .background(AppTheme.ColorToken.accent)
//                .clipShape(RoundedRectangle(cornerRadius: 29))
//                .disabled(isLoading)
//                .opacity(isLoading ? 0.6 : 1.0)
//                
//                Button(action: onPickUp) {
//                    Text("Picked up")
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.white)
//                        .frame(height: AppSize.buttonHeight)
//                        .frame(maxWidth: .infinity)
//                }
//                .background(AppTheme.ColorToken.primary)
//                .clipShape(RoundedRectangle(cornerRadius: 29))
//                .disabled(isLoading)
//                .opacity(isLoading ? 0.6 : 1.0)
//                
//                Button(action: onCancel) {
//                    Text("Cancel")
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.black)
//                        .frame(height: AppSize.buttonHeight)
//                        .frame(maxWidth: .infinity)
//                }
//                .background(Color.clear)
//                .clipShape(RoundedRectangle(cornerRadius: 29))
//                .overlay(
//                    RoundedRectangle(cornerRadius: 29)
//                        .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
//                )
//                .disabled(isLoading)
//                .opacity(isLoading ? 0.6 : 1.0)
//                
//                Spacer() // Push buttons to the left (aligned with image)
//            }
//            
//        case (.home, .pending):
//            // Home + pending → Top-right "Pending confirmation" label + centered Cancel button
//            VStack(spacing: 12) {
//                // Pending confirmation label (top-right, muted)
//                HStack {
//                    Spacer()
//                    Text("Pending confirmation")
//                        .font(.system(size: 12))
//                        .foregroundColor(.black.opacity(0.5))
//                }
//                
//                // Cancel button centered
//                HStack {
//                    Spacer()
//                    Button(action: onCancel) {
//                        Text("Cancel")
//                            .font(.system(size: 16, weight: .semibold))
//                            .foregroundColor(.black)
//                            .frame(height: AppSize.buttonHeight)
//                            .frame(width: 120) // Fixed width for centered button
//                    }
//                    .background(Color.clear)
//                    .clipShape(RoundedRectangle(cornerRadius: 29))
//                    .overlay(
//                        RoundedRectangle(cornerRadius: 29)
//                            .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
//                    )
//                    .disabled(isLoading)
//                    .opacity(isLoading ? 0.6 : 1.0)
//                    Spacer()
//                }
//            }
//            
//        case (.home, .active):
//            // Home + approved → Contact (Primary filled), Cancel (White)
//            HStack(spacing: 12) {
//                Button(action: onContact) {
//                    Text("Contact")
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.white)
//                        .frame(height: AppSize.buttonHeight)
//                        .frame(maxWidth: .infinity)
//                }
//                .background(AppTheme.ColorToken.primary)
//                .clipShape(RoundedRectangle(cornerRadius: 29))
//                .disabled(isLoading)
//                .opacity(isLoading ? 0.6 : 1.0)
//                
//                Button(action: onCancel) {
//                    Text("Cancel")
//                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.black)
//                        .frame(height: AppSize.buttonHeight)
//                        .frame(maxWidth: .infinity)
//                }
//                .background(Color.clear)
//                .clipShape(RoundedRectangle(cornerRadius: 29))
//                .overlay(
//                    RoundedRectangle(cornerRadius: 29)
//                        .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
//                )
//                .disabled(isLoading)
//                .opacity(isLoading ? 0.6 : 1.0)
//            }
//            
//        default:
//            EmptyView()
//        }
//    }
//    
//    private func formatTimeRemaining(_ timeInterval: TimeInterval) -> String {
//        let hours = Int(timeInterval) / 3600
//        let minutes = Int(timeInterval) % 3600 / 60
//        return "\(hours)h \(minutes)m"
//    }
//}
//


//
//  ReservationsView.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Supporting Types

enum ReservationStatus: String, CaseIterable {
    case pending = "pending"
    case active = "active"
    case picked = "picked"
    case canceled = "canceled"
    case expired = "expired"
}

// MARK: - Flat UI Model for Reservations

struct ReservationRow: Identifiable {
    // identity
    let id: String

    // post basics
    let title: String
    let description: String?

    // post meta
    let condition: ItemCondition
    let mode: ItemMode
    let distanceKm: Double?
    let primaryImageURL: URL?

    // owner (uploader)
    let ownerName: String
    let ownerPhone: String?

    // reservation state
    let status: ReservationStatus
    let requestedAt: Date
    let approvedAt: Date?

    // locations
    let exactCoordinate: CLLocationCoordinate2D?   // for street
    
    // Computed properties for business logic
    var expiresAt: Date {
        Calendar.current.date(byAdding: .hour, value: 6, to: requestedAt) ?? requestedAt
    }

    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}

// Nice helpers you can use directly in the View:
extension ReservationRow {
    var statusText: String {
        switch status {
        case .pending:  return "Pending confirmation"
        case .active:   return "Active"
        case .picked:   return "Completed"
        case .canceled: return "Canceled"
        case .expired:  return "Expired"
        }
    }
}

extension ReservationRow {
    init(_ r: Reservation) {
        let p = r.post

        id = r.id
        title = p.title
        description = p.description
        condition = p.condition
        mode = p.mode
        distanceKm = p.distance
        primaryImageURL = p.primaryImageURL

        ownerName = p.owner?.fullName ?? "Unknown"
        ownerPhone = p.owner?.phone

        // status + dates
        status = ReservationStatus(rawValue: r.status) ?? .pending
        let iso = ISO8601DateFormatter()
        requestedAt = iso.date(from: r.requestedAt) ?? Date()
        approvedAt = r.approvedAt.flatMap { iso.date(from: $0) }

        // street coordinate (using Location.coordinate extension)
        exactCoordinate = p.exactLocation?.coordinate
    }
}

// MARK: - ReservationsView

struct ReservationsView: View {
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    // Optional callback injected by parent to switch tabs to Feed
    var onGoToFeed: (() -> Void)? = nil
    @State private var api: ApiService?
    @State private var didKickOff = false
    @State private var reservations: [ReservationRow] = []
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // UI State Management
    @State private var loadingReservations: Set<String> = []
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    // Overlay State
    @State private var selectedReservation: ReservationRow?
    @State private var showDetailOverlay = false
    @Namespace private var imageTransition
    
    // MARK: - Helper Methods
    
    @MainActor private func maybeLoadReservations() async {
        if api == nil { api = ApiService(supabaseService: svc) }
        guard svc.hasAuthToken, didKickOff == false else { return }
        didKickOff = true
        await loadReservations()
    }
    
    @MainActor private func loadReservations() async {
        guard let api else { return }
        isLoading = true
        showError = false
        do {
            let apiReservations = try await fetchWithRetry(svc: svc) {
                try await api.getMyReservations()
            }
            
            await MainActor.run {
                reservations = apiReservations.map(ReservationRow.init)
                isLoading = false
            }
        } catch {
            #if DEBUG
            print("Failed to load reservations: \(error.localizedDescription)")
            #endif
            reservations = []
            isLoading = false
            if error is AuthError || error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Please sign in again to continue."
            } else {
                errorMessage = "Can't load reservations right now. Please try again."
            }
            showError = true
        }
    }
    
    // MARK: - Computed Properties
    private var activeReservations: [ReservationRow] {
        reservations.filter { reservation in
            // Street: active and not expired, Home: pending or active
            (reservation.mode == .street ?
             (reservation.status == .active && !reservation.isExpired) :
             (reservation.status == .pending || reservation.status == .active)
            ) &&
            // Exclude canceled, picked, expired
            ![.canceled, .picked, .expired].contains(reservation.status)
        }
    }

    var body: some View {
        NavigationStack {
            mainContentView
                .navigationTitle("Your reservations")
                .navigationBarTitleDisplayMode(.inline)
                .task {
                    if api == nil { api = ApiService(supabaseService: svc) }
                    await maybeLoadReservations()
                }
                .onChange(of: svc.isAuthenticated) { _ in
                    Task { await maybeLoadReservations() }
                }
                .onChange(of: svc.session?.accessToken ?? "") { _ in
                    Task { await maybeLoadReservations() }
                }
                .overlay(toastOverlayView)
                .overlay(detailOverlayView)
        }
    }

    // MARK: - View Components

    @ViewBuilder
    private var mainContentView: some View {
        Group {
            if isLoading {
                loadingView
            } else if showError {
                errorView
            } else if activeReservations.isEmpty {
                emptyStateView
            } else {
                reservationsListView
            }
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(AppTheme.ColorToken.primary)
            
            Text("Loading your reservations...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text(errorMessage ?? "Failed to load reservations")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
            
            retryButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var retryButton: some View {
        Button("Try Again") {
            Task {
                await loadReservations()
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(AppTheme.ColorToken.primary)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Text("No active reservations yet.")
                .font(.title2)
                .foregroundColor(AppTheme.ColorToken.mutedGray)
            
            Text("Browse the feed to find items you'd like to reserve")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            goToFeedButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var goToFeedButton: some View {
        Button("Go to Feed") {
            goToFeed()
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white)
        .frame(height: 48)
        .frame(minWidth: 120)
        .background(AppTheme.ColorToken.primary)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var reservationsListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(activeReservations) { reservation in
                    reservationCardView(for: reservation)
                        .id(reservation.id)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.chromeSide)
            .padding(.vertical, 12)
        }
        .refreshable {
            await loadReservations()
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func reservationCardView(for reservation: ReservationRow) -> some View {
        ReservationCard(
            reservation: reservation,
            isLoading: loadingReservations.contains(reservation.id),
            imageTransition: imageTransition,
            onTap: {
                selectedReservation = reservation
                showDetailOverlay = true
            },
            onPickUp: { onPickup(reservationId: reservation.id) },
            onCancel: { onCancel(reservationId: reservation.id) },
            onDirections: { onDirections(reservation: reservation) },
            onContact: { onContact(reservation: reservation) }
        )
    }

    @ViewBuilder
    private var toastOverlayView: some View {
        Group {
            if showToast {
                VStack {
                    Spacer()
                    toastMessageView
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: showToast)
            }
        }
    }

    @ViewBuilder
    private var toastMessageView: some View {
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

    @ViewBuilder
    private var detailOverlayView: some View {
        Group {
            if showDetailOverlay, let reservation = selectedReservation {
                overlayBackdropView
                    .overlay(bigCardOverlayView(for: reservation))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDetailOverlay)
            }
        }
    }

    @ViewBuilder
    private var overlayBackdropView: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea(.all)
            .onTapGesture {
                showDetailOverlay = false
                selectedReservation = nil
            }
            .zIndex(1)
    }

    @ViewBuilder
    private func bigCardOverlayView(for reservation: ReservationRow) -> some View {
        BigCardOverlay(
            images: reservation.primaryImageURL != nil ? [reservation.primaryImageURL!.absoluteString] : [],
            primaryInfo: primaryInfoText(for: reservation),
            statusInfo: statusText(for: reservation),
            statusColor: statusColor(for: reservation),
            description: reservation.description,
            mode: reservation.mode == .street ? .street : .home,
            exactLocation: reservation.exactCoordinate,
            ownerName: reservation.ownerName,
            memberSince: nil,
            pickupsCount: nil,
            variant: reservationVariant(for: reservation),
            onDismiss: {
                showDetailOverlay = false
                selectedReservation = nil
            },
            onPrimaryAction: {
                handlePrimaryAction(for: reservation)
            },
            onSecondaryAction: {
                onCancel(reservationId: reservation.id)
                showDetailOverlay = false
                selectedReservation = nil
            },
            onTertiaryAction: reservation.mode == .street ? {
                onDirections(reservation: reservation)
            } : nil
        )
        .zIndex(2)
    }

    @MainActor
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
    
    private func onDirections(reservation: ReservationRow) {
        // Only for street mode
        guard reservation.mode == .street, let exactCoord = reservation.exactCoordinate else { return }
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: exactCoord))
        mapItem.name = reservation.title
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
    
    private func onContact(reservation: ReservationRow) {
        switch reservation.status {
        case .pending:
            // Show inline tip - no call
            showToastMessage("Waiting for giver's confirmation")
        case .active:
            // Open phone dialer
            guard let phoneNumber = reservation.ownerPhone else {
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
        guard let api else { return }
        // Add to loading state
        loadingReservations.insert(reservationId)
        do {
            // Call API to complete the reservation with retry
            try await fetchWithRetry(svc: svc) {
                try await api.completeReservation(reservationId)
            }
            
            // Remove from list on success
            reservations.removeAll { $0.id == reservationId }
            showToastMessage("Item marked as picked up")
        } catch {
            // Handle backend conflict or error
            if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                showToastMessage("Please sign in again to continue.")
            } else {
                showToastMessage("Couldn't update reservation. Please try again.")
                await loadReservations() // Refresh list
            }
        }
        // Remove from loading state
        loadingReservations.remove(reservationId)
    }
    
    @MainActor
    private func handleCancel(reservationId: String) async {
        guard let api else { return }
        // Add to loading state
        loadingReservations.insert(reservationId)
        
        // Find the reservation
        guard let reservation = reservations.first(where: { $0.id == reservationId }) else {
            loadingReservations.remove(reservationId)
            showToastMessage("Reservation not found.")
            return
        }
        
        do {
            // Call API to cancel the reservation using reservation ID with retry
            try await fetchWithRetry(svc: svc) {
                try await api.cancelReservation(reservationId)
            }
            
            // Remove from list on success
            reservations.removeAll { $0.id == reservationId }
            showToastMessage("Reservation canceled")
        } catch {
            // Handle backend conflict or error
            if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                showToastMessage("Please sign in again to continue.")
            } else {
                showToastMessage("Couldn't cancel reservation. Please try again.")
                await loadReservations() // Refresh list
            }
        }
        // Remove from loading state
        loadingReservations.remove(reservationId)
    }
    
    // MARK: - BigCardOverlay Helper Methods
    private func primaryInfoText(for reservation: ReservationRow) -> String {
        switch reservation.mode {
        case .street:
            if let distance = reservation.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "From home (address hidden)"
        }
    }
    
    private func statusText(for reservation: ReservationRow) -> String {
        switch (reservation.mode, reservation.status) {
        case (.street, .active):
            return "Pickup in: \(formatTimeRemaining(reservation.timeRemaining))"
        case (.home, .pending):
            return "Waiting for giver's confirmation"
        case (.home, .active):
            return "Confirmed! Contact the owner to pick it up"
        default:
            return "Posted \(formatRelativeTime(reservation.requestedAt)) ago"
        }
    }
    
    private func statusColor(for reservation: ReservationRow) -> Color {
        switch (reservation.mode, reservation.status) {
        case (.street, .active):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .pending):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .active):
            return AppTheme.ColorToken.success // #6AA54A
        default:
            return AppTheme.ColorToken.mutedGray
        }
    }
    
    private func reservationVariant(for reservation: ReservationRow) -> BigCardOverlay.Variant {
        switch (reservation.mode, reservation.status) {
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
        switch (reservation.mode, reservation.status) {
        case (.street, .active):
            onPickup(reservationId: reservation.id)
            showDetailOverlay = false
            selectedReservation = nil
        case (.home, .pending):
            onContact(reservation: reservation)
        case (.home, .active):
            onContact(reservation: reservation)
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
    private func goToFeed() {
        if let onGoToFeed {
            onGoToFeed()
        } else {
            dismiss()
        }
    }
    
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
    
    @MainActor
    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
        // Auto-hide after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showToast = false
            }
        }
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
                AsyncImage(url: reservation.primaryImageURL) { image in
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
                        Text(reservation.condition.displayText)
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
            if reservation.mode == .street {
                timeRemaining = reservation.timeRemaining
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var primaryInfoText: String {
        switch reservation.mode {
        case .street:
            if let distance = reservation.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "Home listing"
        }
    }
    
    private var expandedPrimaryInfoText: String {
        switch reservation.mode {
        case .street:
            if let distance = reservation.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "From home (address hidden)"
        }
    }
    
    private var statusText: String {
        switch (reservation.mode, reservation.status) {
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
        switch (reservation.mode, reservation.status) {
        case (.street, .active):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .pending):
            return AppTheme.ColorToken.danger // #C44242
        case (.home, .active):
            return AppTheme.ColorToken.success // #6AA54A
        default:
            return .secondary
        }
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private var locationInfoView: some View {
        switch reservation.mode {
        case .street:
            if let exactCoord = reservation.exactCoordinate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact Location")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    // REMOVED expensive map preview - just show coordinates
                    Text("Lat: \(exactCoord.latitude, specifier: "%.4f"), Lng: \(exactCoord.longitude, specifier: "%.4f")")
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
                Text("Shared by \(reservation.ownerName)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                // Note: pickupsCount not available in flat model
                Text("Community member")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
        switch (reservation.mode, reservation.status) {
        case (.street, .active):
            // Street → Left-aligned buttons: "Directions", "Picked up", "Cancel"
            HStack(spacing: 12) {
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
                
                Button(action: onPickUp) {
                    Text("Picked up")
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
                
                Spacer() // Push buttons to the left (aligned with image)
            }
            
        case (.home, .pending):
            // Home + pending → Top-right "Pending confirmation" label + centered Cancel button
            VStack(spacing: 12) {
                // Pending confirmation label (top-right, muted)
                HStack {
                    Spacer()
                    Text("Pending confirmation")
                        .font(.system(size: 12))
                        .foregroundColor(.black.opacity(0.5))
                }
                
                // Cancel button centered
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(height: AppSize.buttonHeight)
                            .frame(width: 120) // Fixed width for centered button
                    }
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 29))
                    .overlay(
                        RoundedRectangle(cornerRadius: 29)
                            .stroke(AppTheme.ColorToken.primary, lineWidth: 2)
                    )
                    .disabled(isLoading)
                    .opacity(isLoading ? 0.6 : 1.0)
                    Spacer()
                }
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

