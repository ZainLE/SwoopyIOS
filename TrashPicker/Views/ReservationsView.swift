//
//  ReservationsView.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

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
    let addressLine: String?

    // owner (uploader)
    let ownerName: String
    let ownerPhone: String?
    let contactPhone: String?

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

    var distanceMeters: Double? {
        distanceKm.map { $0 * 1_000.0 }
    }

    var pickupDeadline: Date? {
        endAt ?? expiresAt
    }

    var streetDisplayAddress: String? {
        if let address = addressLine?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            return address
        }
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        return nil
    }

    var canContact: Bool {
        switch status {
        case .active:
            if let phone = contactPhone, !phone.isEmpty {
                return true
            }
            if let ownerPhone, !ownerPhone.isEmpty, mode == .street {
                return true
            }
            return false
        default:
            return false
        }
    }

    var isHome: Bool { mode == .home }

    var contactDisplayNumber: String? {
        if let phone = contactPhone, !phone.isEmpty {
            return phone
        }
        if let ownerPhone, !ownerPhone.isEmpty {
            return ownerPhone
        }
        return nil
    }
}

private enum ReservationDateParser {
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return Time.parseISO(raw)
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
        addressLine = p.addressLine

        ownerName = p.owner?.fullName ?? "Unknown"
        ownerPhone = p.owner?.phone
        contactPhone = r.contactPhone

        status = ReservationStatus(rawValue: r.status.rawValue) ?? .pending
        requestedAt = ReservationDateParser.parse(r.requestedAt) ?? Date()
        approvedAt = ReservationDateParser.parse(r.approvedAt)
        endAt = ReservationDateParser.parse(r.endAt)
        pickedAt = ReservationDateParser.parse(r.pickedAt)

        exactCoordinate = p.exactLocation?.coordinate
    }
}

// MARK: - ReservationsView

struct ReservationsView: View {
    @Environment(AppRouter.self) private var router
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss

    var onGoToFeed: (() -> Void)? = nil

    @State private var api: ApiService?
    @State private var didKickOff = false
    @State private var reservations: [ReservationRow] = []
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // UI State
    @State private var loadingReservations: Set<String> = []
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    // Overlay State
    @State private var selectedReservation: ReservationRow?
    @Namespace private var imageTransition
    @State private var contactReservation: ReservationRow?
    @State private var showContactOptions = false
    @State private var pendingContactRefreshId: String?

    var body: some View {
        NavigationStack {
            mainContentView
                .navigationTitle("Your reservations")
                .navigationBarTitleDisplayMode(.inline)
                .task { await maybeLoadReservations() }
                .onChange(of: svc.isAuthenticated) { _, _ in
                    Task { await maybeLoadReservations() }
                }
                .onChange(of: svc.session?.accessToken ?? "") { _, _ in
                    Task { await maybeLoadReservations() }
                }
                .overlay(toastOverlayView)
        }
        .confirmationDialog(
            "Contact giver",
            isPresented: $showContactOptions,
            presenting: contactReservation
        ) { reservation in
            if let phone = reservation.contactDisplayNumber {
                Button("Call \(phone)") { dialPhoneNumber(phone) }
                Button("Copy number") { copyPhoneNumber(phone) }
            }
            Button("Cancel", role: .cancel) {
                contactReservation = nil
            }
        } message: { reservation in
            if let phone = reservation.contactDisplayNumber {
                Text(phone)
            }
        }
        .fullScreenCover(item: $selectedReservation, onDismiss: { selectedReservation = nil }) { reservation in
            NavigationStack {
                BigCardOverlay(
                    postID: reservation.id,
                    images: reservation.primaryImageURL.map { [$0.absoluteString] } ?? [],
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
                    onDismiss: { selectedReservation = nil },
                    onPrimaryAction: { handlePrimaryAction(for: reservation) },
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

    // MARK: - Async Loading

    @MainActor
    private func maybeLoadReservations() async {
        if api == nil {
            api = ApiService(supabaseService: svc)
        }
        guard svc.hasAuthToken, didKickOff == false else { return }
        didKickOff = true
        await loadReservations()
    }

    @MainActor
    private func loadReservations() async {
        guard let api else { return }
        isLoading = true
        showError = false
        do {
            let apiReservations = try await fetchWithRetry(svc: svc) {
                try await api.getMyReservations()
            }
            let rows = apiReservations.map(ReservationRow.init)
            await MainActor.run {
                reservations = rows
                isLoading = false

                if let pendingId = pendingContactRefreshId {
                    if let refreshed = rows.first(where: { $0.id == pendingId }) {
                        if refreshed.canContact {
                            contactReservation = refreshed
                            showContactOptions = true
                        } else {
                            showToastMessage("Contact will appear after approval.")
                        }
                    } else {
                        showToastMessage("Contact will appear after approval.")
                    }
                    pendingContactRefreshId = nil
                }
            }
        } catch {
            DLog("Failed to load reservations: \(error.localizedDescription)")
            reservations = []
            isLoading = false
            pendingContactRefreshId = nil
            if error is AuthError || error.localizedDescription.contains("401") {
                errorMessage = "Please sign in again to continue."
            } else {
                errorMessage = "Can't load reservations right now. Please try again."
            }
            showError = true
        }
    }

    // MARK: - Computed Sections

    private var visibleReservations: [ReservationRow] {
        reservations.sorted { $0.requestedAt > $1.requestedAt }
    }

    // MARK: - View Builders

    @ViewBuilder
    private var mainContentView: some View {
        Group {
            if isLoading {
                loadingView
            } else if showError {
                errorView
            } else if visibleReservations.isEmpty {
                emptyStateView
            } else {
                reservationsListView
            }
        }
    }

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

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text(errorMessage ?? "Failed to load reservations")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task { await loadReservations() }
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
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No reservations yet")
                .font(.system(size: 18, weight: .semibold))

            Text("Reserve an item from the feed and it will appear here.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Browse Feed") {
                onGoToFeed?()
                dismiss()
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

    private var reservationsListView: some View {
        ScrollView {
            VStack(spacing: 28) {
                ForEach(visibleReservations) { reservation in
                    reservationCardView(for: reservation)
                        .id(reservation.id)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
            .padding(.horizontal, AppTheme.Spacing.chromeSide)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await loadReservations()
        }
    }

    private func reservationCardView(for reservation: ReservationRow) -> some View {
        ReservationCard(
            reservation: reservation,
            isLoading: loadingReservations.contains(reservation.id),
            imageTransition: imageTransition,
            onTap: { selectedReservation = reservation },
            onPickUp: { onPickup(reservationId: reservation.id) },
            onCancel: { onCancel(reservationId: reservation.id) },
            onDirections: { onDirections(reservation: reservation) },
            onContact: { onContact(reservation: reservation) }
        )
    }

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

    // MARK: - Actions

    private func onPickup(reservationId: String) {
        guard let reservation = reservations.first(where: { $0.id == reservationId }) else { return }
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
        guard reservation.mode == .street, let coordinate = reservation.exactCoordinate else { return }
        MapHelper.openAppleMaps(
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            name: reservation.title
        )
    }

    private func onContact(reservation: ReservationRow) {
        switch reservation.status {
        case .pending:
            showToastMessage("Waiting for giver's confirmation")
        case .active:
            if reservation.canContact, reservation.contactDisplayNumber != nil {
                contactReservation = reservation
                showContactOptions = true
            } else {
                pendingContactRefreshId = reservation.id
                NotificationCenter.default.post(name: .refreshReservations, object: nil)
            }
        case .picked:
            showToastMessage("Already picked up.")
        case .canceled, .expired:
            showToastMessage("Reservation is no longer active.")
        }
    }

    @MainActor
    private func handlePickup(reservationId: String) async {
        guard let api else { return }
        loadingReservations.insert(reservationId)
        do {
            try await fetchWithRetry(svc: svc) {
                try await api.completeReservation(reservationId)
            }
            await loadReservations()
            showToastMessage("Item marked as picked up")
        } catch {
            showToastMessage("Couldn't update reservation. Please try again.")
            await loadReservations()
        }
        loadingReservations.remove(reservationId)
    }

    @MainActor
    private func handleCancel(reservationId: String) async {
        guard let api else { return }
        loadingReservations.insert(reservationId)
        do {
            guard let reservation = reservations.first(where: { $0.id == reservationId }) else { return }
            try await fetchWithRetry(svc: svc) {
                try await api.cancelReservation(reservation.postId)
            }
            await loadReservations()
            showToastMessage("Reservation canceled")
        } catch {
            showToastMessage("Couldn't cancel reservation. Please try again.")
            await loadReservations()
        }
        loadingReservations.remove(reservationId)
    }

    private func dialPhoneNumber(_ phone: String) {
        let allowed = CharacterSet(charactersIn: "+0123456789")
        let clean = phone.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        guard !clean.isEmpty, let url = URL(string: "tel:\(clean)") else {
            showToastMessage("Unable to start a call.")
            contactReservation = nil
            showContactOptions = false
            return
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            showToastMessage("Calls are not supported on this device.")
        }
        contactReservation = nil
        showContactOptions = false
    }

    private func copyPhoneNumber(_ phone: String) {
        UIPasteboard.general.string = phone
        showToastMessage("Number copied to clipboard.")
        contactReservation = nil
        showContactOptions = false
    }

    // MARK: - Helper Methods

    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showToast = false
            }
        }
    }

    private func presentAlert(_ alert: UIAlertController) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(alert, animated: true)
    }

    private func primaryInfoText(for reservation: ReservationRow) -> String {
        if reservation.mode == .street {
            if let meters = reservation.distanceMeters {
                return formatDistance(meters)
            }
            return "Street pickup"
        } else {
            return "Address hidden"
        }
    }

    private func statusText(for reservation: ReservationRow) -> String {
        switch reservation.status {
        case .pending:
            return "Waiting for giver's confirmation"
        case .active:
            if let deadline = reservation.pickupDeadline {
                return formatRemaining(deadline)
            }
            return "Active"
        case .picked:
            if let pickedAt = reservation.pickedAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return "Picked \(formatter.localizedString(for: pickedAt, relativeTo: Date()))"
            }
            return "Picked up"
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
            onPickup(reservationId: reservation.id)
        case (.home, .pending), (.home, .active):
            onContact(reservation: reservation)
        default:
            break
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

    private enum Layout {
        static let thumbnail: CGFloat = 96
    }

    init(reservation: ReservationRow, isLoading: Bool, imageTransition: Namespace.ID, onTap: @escaping () -> Void, onPickUp: @escaping () -> Void, onCancel: @escaping () -> Void, onDirections: @escaping () -> Void, onContact: @escaping () -> Void) {
        self.reservation = reservation
        self.isLoading = isLoading
        self.imageTransition = imageTransition
        self.onTap = onTap
        self.onPickUp = onPickUp
        self.onCancel = onCancel
        self.onDirections = onDirections
        self.onContact = onContact
    }

    var body: some View {
        Group {
            if reservation.isHome {
                homeCard
            } else {
                streetCard
            }
        }
    }

    // MARK: - Card Layouts

    private var homeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 6) {
                    conditionRow
                    homeTextBlock
                }

                Spacer()
            }

            if reservation.status == .pending || reservation.status == .active {
                HStack(spacing: 8) {
                    Button("Contact", action: onContact)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .layoutPriority(1)
                        .buttonStyle(SwoopyPrimaryButtonStyle())
                        .disabled(isLoading || reservation.status == .pending)
                        .opacity(isLoading ? 0.6 : (reservation.canContact ? 1 : 0.45))

                    Button("Cancel", action: onCancel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .layoutPriority(1)
                        .buttonStyle(SwoopyOutlineButtonStyle())
                        .disabled(isLoading || !(reservation.status == .pending || reservation.status == .active))
                        .opacity((isLoading || !(reservation.status == .pending || reservation.status == .active)) ? 0.6 : 1.0)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var streetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 6) {
                    conditionRow
                    streetTextBlock
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Button("Pick up", action: onPickUp)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .buttonStyle(SwoopyPrimaryButtonStyle())
                    .disabled(isLoading || reservation.status != .active)
                    .opacity((isLoading || reservation.status != .active) ? 0.6 : 1.0)

                Button("Cancel", action: onCancel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .buttonStyle(SwoopyOutlineButtonStyle())
                    .disabled(isLoading || !(reservation.status == .pending || reservation.status == .active))
                    .opacity((isLoading || !(reservation.status == .pending || reservation.status == .active)) ? 0.6 : 1.0)

                Button("Directions", action: onDirections)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .buttonStyle(SwoopyPillSecondaryStyle())
                    .disabled(isLoading || reservation.exactCoordinate == nil)
                    .opacity((isLoading || reservation.exactCoordinate == nil) ? 0.6 : 1.0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // MARK: - Components

    private var thumbnail: some View {
        AsyncImage(url: reservation.primaryImageURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(AppTheme.ColorToken.mutedGray.opacity(0.2))
        }
        .frame(width: Layout.thumbnail, height: Layout.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .matchedGeometryEffect(id: "image-\(reservation.id)", in: imageTransition)
    }

    private var conditionRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(reservation.condition.dotColor)
                .frame(width: 8, height: 8)

            Text(reservation.condition.displayText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color("SwoopyDeepGreen").opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Spacer()
        }
    }

    private var streetTextBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let meters = reservation.distanceMeters {
                Text(formatDistance(meters))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            if let address = reservation.streetDisplayAddress {
                Text(address)
                    .font(.footnote)
                    .foregroundStyle(Color("SwoopyDeepGreen"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            if let deadline = reservation.pickupDeadline {
                Text(formatRemaining(deadline))
                    .font(.footnote)
                    .foregroundStyle(Color("SwoopyRed"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
    }

    private var homeTextBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Address hidden")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Text("Home listing")
                .font(.footnote)
                .foregroundStyle(Color("SwoopyDeepGreen"))
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            switch reservation.status {
            case .pending:
                Text("Waiting for giver's confirmation")
                    .font(.footnote)
                    .foregroundStyle(Color("SwoopyRed"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            case .active:
                Text("Confirmed! Contact the owner to pick it up")
                    .font(.footnote)
                    .foregroundStyle(Color("SwoopyGreen"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Formatting Helpers

private func formatDistance(_ meters: Double) -> String {
    if meters >= 1_000 {
        return String(format: "%.1f km away", meters / 1_000.0)
    } else {
        return "\(Int(round(meters))) m away"
    }
}

private func formatRemaining(_ until: Date) -> String {
    let remaining = max(0, Int(until.timeIntervalSinceNow))
    let clamped = min(remaining, 2 * 3600) // Clamp to 2 hours max
    let hours = clamped / 3600
    let minutes = (clamped % 3600) / 60
    if hours > 0 {
        return "Pickup in: \(hours)h \(minutes)m"
    }
    return "Pickup in: \(minutes)m"
}
