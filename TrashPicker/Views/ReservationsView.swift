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
    let postId: String
    let ownerId: String

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
    let endAt: Date?
    let pickedAt: Date?

    // locations
    let exactCoordinate: CLLocationCoordinate2D?   // for street
    
    // Computed properties for business logic
    var expiresAt: Date {
        endAt ?? Calendar.current.date(byAdding: .hour, value: 6, to: requestedAt) ?? requestedAt
    }

    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}

private enum ReservationDateParser {
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return Time.parseISO(raw)
    }
}

// Nice helpers you can use directly in the View:
extension ReservationRow {
    var statusText: String {
        switch status {
        case .pending:  return "Waiting for giver's confirmation"
        case .active:   return "Active"
        case .picked:   return "Picked up"
        case .canceled: return "Canceled"
        case .expired:  return "Expired"
        }
    }
}

extension ReservationRow {
    init(_ r: Reservation) {
        let p = r.post

        id = r.id
        postId = p.id
        ownerId = p.ownerId.trimmingCharacters(in: .whitespacesAndNewlines)
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
        requestedAt = ReservationDateParser.parse(r.requestedAt) ?? Date()
        approvedAt = ReservationDateParser.parse(r.approvedAt)
        endAt = ReservationDateParser.parse(r.endAt)
        pickedAt = ReservationDateParser.parse(r.pickedAt)

        // street coordinate (using Location.coordinate extension)
        exactCoordinate = p.exactLocation?.coordinate
    }
}

// MARK: - ReservationsView

struct ReservationsView: View {
    @Environment(AppRouter.self) private var router
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
    @State private var showPastReservations = false
    
    // Overlay State
    @State private var selectedReservation: ReservationRow?
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
            
            let rows = apiReservations.map(ReservationRow.init)
            await MainActor.run {
                reservations = filterReservationsForDisplay(rows)
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
    private var pendingReservations: [ReservationRow] {
        sortByRecency(
            reservations.filter { $0.status == .pending && !$0.isExpired }
        )
    }

    private var activeReservations: [ReservationRow] {
        sortByRecency(
            reservations.filter { reservation in
                guard reservation.status == .active else { return false }
                if reservation.mode == .street {
                    return !reservation.isExpired
                }
                return true
            }
        )
    }

    private var pastReservations: [ReservationRow] {
        sortByRecency(
            reservations.filter { reservation in
                switch reservation.status {
                case .picked, .canceled, .expired:
                    return true
                case .active:
                    return reservation.mode == .street && reservation.isExpired
                case .pending:
                    return reservation.isExpired
                }
            }
        )
    }

    private var hasAnyReservations: Bool {
        !pendingReservations.isEmpty || !activeReservations.isEmpty || !pastReservations.isEmpty
    }

    private func sortByRecency(_ rows: [ReservationRow]) -> [ReservationRow] {
        rows.sorted { $0.requestedAt > $1.requestedAt }
    }

    private func filterReservationsForDisplay(_ rows: [ReservationRow]) -> [ReservationRow] {
        guard let myId = svc.userId else { return rows }
        let myIdLowercased = myId.uuidString.lowercased()

        return rows.filter { row in
            if let ownerUUID = UUID(uuidString: row.ownerId) {
                return ownerUUID != myId
            }
            return row.ownerId.lowercased() != myIdLowercased
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
        }
        .fullScreenCover(item: $selectedReservation, onDismiss: { selectedReservation = nil }) { reservation in
            NavigationStack {
                BigCardOverlay(
                    postID: reservation.id,
                    images: reservation.primaryImageURL != nil ? [reservation.primaryImageURL!.absoluteString] : [],
                    primaryInfo: primaryInfoText(for: reservation),
                    statusInfo: statusText(for: reservation),
                    statusColor: statusColor(for: reservation),
                    description: reservation.description,
                    mode: reservation.mode == .street ? .street : .home,
                    exactLocation: reservation.exactCoordinate,
                    ownerName: reservation.ownerName,
                    ownerAvatarUrl: nil,
                    memberSince: nil,
                    pickupsCount: nil,
                    variant: reservationVariant(for: reservation),
                    onDismiss: {
                        selectedReservation = nil
                    },
                    onPrimaryAction: {
                        handlePrimaryAction(for: reservation)
                    },
                    onSecondaryAction: {
                        onCancel(reservationId: reservation.id)
                        selectedReservation = nil
                    },
                    onTertiaryAction: reservation.mode == .street ? {
                        onDirections(reservation: reservation)
                    } : nil
                )
                .background(Color(.systemBackground))
                .ignoresSafeArea()
            }
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
            } else if !hasAnyReservations {
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
            Text("No reservations yet.")
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
            VStack(spacing: 28) {
                if !pendingReservations.isEmpty {
                    reservationsSection(title: "Pending confirmation", reservations: pendingReservations)
                }

                if !activeReservations.isEmpty {
                    reservationsSection(title: "Ready for pickup", reservations: activeReservations)
                }

                if !pastReservations.isEmpty {
                    pastReservationsSection
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
            .padding(.horizontal, AppTheme.Spacing.chromeSide)
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
            },
            onPickUp: { onPickup(reservationId: reservation.id) },
            onCancel: { onCancel(reservationId: reservation.id) },
            onDirections: { onDirections(reservation: reservation) },
            onContact: { onContact(reservation: reservation) }
        )
    }

    @ViewBuilder
    private func reservationsSection(title: String, reservations: [ReservationRow]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: title, count: reservations.count)

            ForEach(reservations) { reservation in
                reservationCardView(for: reservation)
                    .id(reservation.id)
            }
        }
    }

    @ViewBuilder
    private var pastReservationsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPastReservations.toggle()
                }
            } label: {
                HStack {
                    Text("Past reservations")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    Text("\(pastReservations.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())

                    Image(systemName: showPastReservations ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showPastReservations {
                VStack(spacing: 16) {
                    ForEach(pastReservations) { reservation in
                        reservationCardView(for: reservation)
                            .id(reservation.id)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
        }
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
            
            // Reload to reflect updated status
            await loadReservations()
            showToastMessage("Item marked as picked up")
        } catch let apiError as ApiServiceError {
            switch apiError {
            case .unauthorized:
                showToastMessage("Please sign in again to continue.")
            case .notFound:
                showToastMessage("Item not found.")
                await loadReservations()
            case .serverError(let message):
                let friendly = friendlyMessage(statusCode: nil, backendMessage: message, fallback: "Couldn't update reservation. Please try again.")
                showToastMessage(friendly)
                await loadReservations()
            case .networkError:
                showToastMessage("Can't reach the server right now. Please try again.")
            default:
                showToastMessage(apiError.localizedDescription)
                await loadReservations()
            }
        } catch {
            let friendly = friendlyMessage(statusCode: nil, backendMessage: error.localizedDescription, fallback: "Couldn't update reservation. Please try again.")
            showToastMessage(friendly)
            await loadReservations()
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
            // Call API to cancel the reservation using post ID with retry
            try await fetchWithRetry(svc: svc) {
                try await api.cancelReservation(reservation.postId)
            }
            
            // Remove from list on success
            Metrics.reservationAction(
                screen: "Reservations",
                role: "reserver",
                postId: reservation.postId,
                reservationId: reservation.id,
                mode: reservation.mode,
                statusBefore: reservation.status.rawValue,
                statusAfter: "canceled"
            )
            reservations.removeAll { $0.id == reservationId }
            showToastMessage("Reservation canceled")
        } catch let apiError as ApiServiceError {
            switch apiError {
            case .unauthorized:
                showToastMessage("Please sign in again to continue.")
            case .notFound:
                Metrics.reservationAction(
                    screen: "Reservations",
                    role: "reserver",
                    postId: reservation.postId,
                    reservationId: reservation.id,
                    mode: reservation.mode,
                    statusBefore: reservation.status.rawValue,
                    statusAfter: "already_canceled"
                )
                reservations.removeAll { $0.id == reservationId }
                showToastMessage("Reservation already canceled")
            case .serverError(let message):
                let friendly = friendlyMessage(statusCode: nil, backendMessage: message, fallback: "Couldn't cancel reservation. Please try again.")
                showToastMessage(friendly)
                await loadReservations()
            case .networkError:
                showToastMessage("Can't reach the server right now. Please try again.")
            default:
                showToastMessage(apiError.localizedDescription)
                await loadReservations()
            }
        } catch {
            let friendly = friendlyMessage(statusCode: nil, backendMessage: error.localizedDescription, fallback: "Couldn't cancel reservation. Please try again.")
            showToastMessage(friendly)
            await loadReservations()
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
        switch reservation.status {
        case .pending:
            return "Waiting for giver's confirmation"
        case .active:
            let remaining = reservation.timeRemaining
            return remaining > 0 ? "Pickup in: \(formatTimeRemaining(remaining))" : "Pickup window ending soon"
        case .picked:
            if let pickedAt = reservation.pickedAt {
                return "Picked up \(formatRelativeTime(pickedAt))"
            }
            return "Picked up! Enjoy."
        case .canceled:
            return "Canceled"
        case .expired:
            return "Expired"
        }
    }

    private func statusColor(for reservation: ReservationRow) -> Color {
        switch reservation.status {
        case .pending:
            return AppTheme.ColorToken.danger
        case .active:
            return AppTheme.ColorToken.primary
        case .picked:
            return AppTheme.ColorToken.success
        case .canceled, .expired:
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
        case (_, .picked):
            return .reservations(.completed)
        default:
            return .reservations(.homePending)
        }
    }
    
    private func handlePrimaryAction(for reservation: ReservationRow) {
        switch (reservation.mode, reservation.status) {
        case (.street, .active):
            onDirections(reservation: reservation)
            selectedReservation = nil
        case (.home, .pending):
            onContact(reservation: reservation)
        case (.home, .active):
            onContact(reservation: reservation)
        case (_, .picked):
            selectedReservation = nil
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

    private func friendlyMessage(statusCode: Int?, backendMessage: String?, fallback: String) -> String {
        if let backendMessage, !backendMessage.isEmpty {
            let lower = backendMessage.lowercased()
            if lower.contains("phone_required_for_home_mode") {
                return "Add a phone number to approve home pickups."
            }
            return backendMessage
        }

        if let statusCode {
            switch statusCode {
            case 403:
                return "You're not allowed to perform this action."
            case 404:
                return "Item not found."
            default:
                break
            }
        }

        return fallback
    }
    
    // MARK: - Helper Methods
    private func goToFeed() {
        // Prefer global router for tab navigation
        router.selectedTab = AppTab.feed
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

    private enum Layout {
        static let thumbnail: CGFloat = 96
        static let horizontalPadding: CGFloat = 20
        static let verticalPadding: CGFloat = 20
    }
    
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
                .frame(width: Layout.thumbnail, height: Layout.thumbnail)
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
            .padding(.top, Layout.verticalPadding)
            .padding(.horizontal, Layout.horizontalPadding)
            
            // Buttons row
            buttonsRow
                .padding(.top, Layout.verticalPadding)
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.bottom, Layout.verticalPadding)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .onTapGesture {
            onTap()
        }
        .onReceive(timer) { _ in
            if reservation.status == .active {
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
            return "From home (address hidden)"
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
        switch reservation.status {
        case .pending:
            return "Waiting for giver's confirmation"
        case .active:
            let remaining = max(0, timeRemaining)
            return remaining > 0 ? "Pickup in: \(formatTimeRemaining(remaining))" : "Pickup window ending soon"
        case .picked:
            if let pickedAt = reservation.pickedAt {
                return "Picked up \(formatRelativeTime(pickedAt))"
            }
            return "Picked up! Enjoy."
        case .canceled:
            return "Canceled"
        case .expired:
            return "Expired"
        }
    }
    
    private var statusColor: Color {
        switch reservation.status {
        case .pending:
            return AppTheme.ColorToken.danger
        case .active:
            return AppTheme.ColorToken.primary
        case .picked:
            return AppTheme.ColorToken.success
        case .canceled, .expired:
            return AppTheme.ColorToken.mutedGray
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
            // Street → Directions + Cancel
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
            
        case (.home, .pending):
            // Home + pending → Top-right "Pending confirmation" label + centered Cancel button
            VStack(spacing: 12) {
                // Pending confirmation label (top-right, muted)
                HStack {
                    Spacer()
                    Text("Waiting for giver's confirmation")
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
                    Text("Contact owner")
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
        case (_, .picked):
            VStack(spacing: 6) {
                HStack {
                    Spacer()
                    Label("Picked up!", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.ColorToken.success)
                    Spacer()
                }
                if let pickedAt = reservation.pickedAt {
                    HStack {
                        Spacer()
                        Text("Completed \(formatRelativeTime(pickedAt))")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
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
