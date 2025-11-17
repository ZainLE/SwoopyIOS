//
//  ReservationsView.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit
import Combine
import SmartlookAnalytics

// MARK: - Supporting Types

enum ReservationStatus: String, CaseIterable, Equatable {
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
    let ownerAvatarUrl: URL?
    var contactPhone: String?

    // reservation state
    let status: ReservationStatus
    let requestedAt: Date
    let approvedAt: Date?
    let endAt: Date?
    let pickedAt: Date?
    let postExpiresAt: Date?

    // locations
    var exactCoordinate: CLLocationCoordinate2D?   // street or approved home
    var approxCoordinate: CLLocationCoordinate2D?
    
    // Computed properties for business logic
    var expiresAt: Date {
        let fallback = Calendar.current.date(byAdding: .hour, value: 6, to: requestedAt) ?? requestedAt
        let postCap = postExpiresAt ?? fallback
        if mode == .street {
            let streetWindow = Calendar.current.date(byAdding: .hour, value: 2, to: requestedAt) ?? requestedAt
            let reservationCap = min(endAt ?? streetWindow, streetWindow)
            return min(reservationCap, postCap)
        }
        return min(endAt ?? fallback, postCap)
    }

    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }

    var distanceMeters: Double? {
        guard mode == .street else { return nil }
        guard let pickup = streetCoordinate else {
            return distanceKm.map { $0 * 1_000.0 }
        }
        if let user = LocationService.shared.lastKnownCoordinate {
            let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
            let pickupLocation = CLLocation(latitude: pickup.latitude, longitude: pickup.longitude)
            return userLocation.distance(from: pickupLocation)
        }
        return distanceKm.map { $0 * 1_000.0 }
    }

    var pickupDeadline: Date? {
        return expiresAt
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
        // Street mode: never show contact (public pickups, no contact needed)
        guard mode == .home else { return false }
        
        // Home mode: only when active and contact info available
        switch effectiveStatus {
        case .active:
            if let phone = contactPhone, !phone.isEmpty {
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
    
    var sharedByText: String {
        // Extract first name from ownerName (assumes "FirstName LastName" format)
        let components = ownerName.components(separatedBy: " ")
        let firstName = components.first ?? "Someone"
        return "Shared by \(firstName)"
    }
    
    /// Effective status for UI gating.
    /// Street posts: pending is treated as active (no giver approval needed).
    /// Home posts: status is used as-is (requires explicit approval).
    var effectiveStatus: ReservationStatus {
        if mode == .street && status == .pending {
            return .active
        }
        return status
    }
}

private struct ReservationContactSignature: Equatable {
    let id: String
    let contactPhone: String?
    let status: ReservationStatus
    
    init(_ reservation: ReservationRow) {
        self.id = reservation.id
        self.contactPhone = reservation.contactPhone
        self.status = reservation.status
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
        ownerAvatarUrl = p.owner?.avatarUrl
        contactPhone = r.contactPhone

        status = ReservationStatus(rawValue: r.status.rawValue) ?? .pending
        requestedAt = ReservationDateParser.parse(r.requestedAt) ?? Date()
        approvedAt = ReservationDateParser.parse(r.approvedAt)
        endAt = ReservationDateParser.parse(r.endAt)
        pickedAt = ReservationDateParser.parse(r.pickedAt)
        postExpiresAt = p.expiresAt
        LocationCache.shared.store(post: p)
        if p.mode == .street, let cached = LocationCache.shared.coordinate(for: p.id, mode: .street), p.exactCoordinate == nil {
            exactCoordinate = cached
        } else {
            exactCoordinate = p.exactCoordinate
        }
        if p.mode == .home, let cached = LocationCache.shared.coordinate(for: p.id, mode: .home), p.approxCoordinate == nil {
            approxCoordinate = cached
        } else {
            approxCoordinate = p.approxCoordinate
        }
    }
    
    /// Create an optimistic reservation row from a Post for immediate UI feedback
    init(optimisticFrom post: Post, reservationId: String) {
        id = reservationId
        postId = post.id
        ownerId = post.ownerId.trimmingCharacters(in: .whitespacesAndNewlines)
        title = post.title
        description = post.description
        condition = post.condition
        mode = post.mode
        distanceKm = post.distance
        primaryImageURL = post.primaryImageURL
        addressLine = post.addressLine
        
        ownerName = post.owner?.fullName ?? "Unknown"
        ownerPhone = post.owner?.phone
        ownerAvatarUrl = post.owner?.avatarUrl
        contactPhone = nil
        
        // Optimistic reservation starts as pending for home, active for street
        status = post.mode == .street ? .active : .pending
        requestedAt = Date()
        approvedAt = nil
        endAt = nil
        pickedAt = nil
        postExpiresAt = post.expiresAt
        
        LocationCache.shared.store(post: post)
        if post.mode == .street, let cached = LocationCache.shared.coordinate(for: post.id, mode: .street), post.exactCoordinate == nil {
            exactCoordinate = cached
        } else {
            exactCoordinate = post.exactCoordinate
        }
        if post.mode == .home, let cached = LocationCache.shared.coordinate(for: post.id, mode: .home), post.approxCoordinate == nil {
            approxCoordinate = cached
        } else {
            approxCoordinate = post.approxCoordinate
        }
    }
}

extension ReservationRow {
    var streetCoordinate: CLLocationCoordinate2D? {
        guard mode == .street else { return nil }
        if let exactCoordinate {
            return exactCoordinate
        }
        return LocationCache.shared.coordinate(for: postId, mode: .street)
    }

    var streetGeoPoint: GeoPoint? { GeoPoint(coordinate: streetCoordinate) }

    var homeCoordinate: CLLocationCoordinate2D? {
        guard mode == .home else { return nil }
        if let approxCoordinate {
            return approxCoordinate
        }
        return LocationCache.shared.coordinate(for: postId, mode: .home)
    }

    var pickupCoordinate: CLLocationCoordinate2D? {
        switch mode {
        case .street:
            return streetCoordinate
        case .home:
            return homeCoordinate
        }
    }
}

// MARK: - ReservationsView

struct ReservationsView: View {
    @Environment(AppRouter.self) private var router
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var notificationService: ReservationNotificationService
    @Environment(\.dismiss) private var dismiss

    var onGoToFeed: (() -> Void)? = nil

    @State private var api: ApiService?
    @State private var didKickOff = false
    @State private var reservations: [ReservationRow] = []
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // UI State
    @State private var loadingActionMap: [String: ReservationActionBar.Action] = [:]
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIsError = false
    @State private var toastRetryAction: (() -> Void)? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    // Overlay State
    @State private var selectedReservation: ReservationRow?
    @State private var contactReservation: ReservationRow?
    @State private var showContactOptions = false
    @State private var pendingContactRefreshId: String?
    @State private var pendingOpenReservationId: String?
    @State private var clock = Date()
    @State private var hydratingPostIds: Set<String> = []
    @State private var pendingAction: PendingReservationAction?
    @State private var loggedContactStates: [String: Bool] = [:]
    @Namespace private var imageTransition

    var body: some View {
        navigationContent
            .modifier(contactDialog)
            .modifier(reservationCover)
            .modifier(actionDialog)
    }

    // MARK: - Navigation Content
    private var navigationContent: some View {
        NavigationStack {
            mainContentView
                .navigationTitle("Your reservations")
                .navigationBarTitleDisplayMode(.inline)
                .task {
                    await maybeLoadReservations()
                    applyApprovedPhones(notificationService.contactPhonesByReservation)
                }
                .modifier(authenticationChanges)
                .modifier(notificationHandlers)
                .modifier(timerHandler)
                .onReceive(notificationService.$contactPhonesByReservation) { phoneMap in
                    applyApprovedPhones(phoneMap)
                }
                .onChange(of: reservations.map(ReservationContactSignature.init)) { _ in
                    logContactStates(for: reservations)
                }
                .overlay(toastOverlayView)
        }
    }

    // MARK: - Authentication Changes
    private var authenticationChanges: AuthenticationModifier {
        AuthenticationModifier(
            svc: svc,
            maybeLoadReservations: maybeLoadReservations
        )
    }

    // MARK: - Notification Handlers
    private var notificationHandlers: NotificationModifier {
        NotificationModifier(
            pendingContactRefreshId: $pendingContactRefreshId,
            pendingOpenReservationId: $pendingOpenReservationId,
            loadReservations: loadReservations,
            updateLocalReservationContact: updateLocalReservationContact,
            presentReservationIfPossible: presentReservationIfPossible,
            insertOptimisticReservation: insertOrUpdateOptimisticReservation,
            removeOptimisticReservation: removeOptimisticReservation
        )
    }

    // MARK: - Timer Handler
    private var timerHandler: TimerModifier {
        TimerModifier(
            timer: timer,
            clock: $clock,
            reservations: $reservations,
            loadReservations: loadReservations
        )
    }

    // MARK: - Contact Dialog
    private var contactDialog: ContactDialogViewModifier {
        ContactDialogViewModifier(
            showContactOptions: $showContactOptions,
            contactReservation: $contactReservation,
            dialPhoneNumber: dialPhoneNumber,
            copyPhoneNumber: copyPhoneNumber
        )
    }

    // MARK: - Reservation Cover
    private var reservationCover: ReservationCoverViewModifier {
        ReservationCoverViewModifier(
            selectedReservation: $selectedReservation,
            buildOverlay: { AnyView(buildBigCardOverlay(for: $0)) }
        )
    }

    // MARK: - Action Dialog
    private var actionDialog: ActionDialogViewModifier {
        ActionDialogViewModifier(
            pendingAction: $pendingAction,
            handlePickup: handlePickup,
            handleCancel: handleCancel
        )
    }

    // MARK: - Helper Methods
    private func buildBigCardOverlay(for reservation: ReservationRow) -> some View {
        let overlayActionConfig = reservation.mode == .street ? actionConfiguration(for: reservation) : nil
        
        return NavigationStack {
            BigCardOverlay(
                postID: reservation.id,
                images: reservation.primaryImageURL.map { [$0.absoluteString] } ?? [],
                primaryInfo: primaryInfoText(for: reservation),
                statusInfo: statusText(for: reservation),
                statusColor: statusColor(for: reservation),
                description: reservation.description,
                mode: reservation.mode == .street ? .street : .home,
                exactCoordinate: reservation.streetCoordinate,
                approxCoordinate: reservation.homeCoordinate,
                ownerName: reservation.ownerName,
                ownerAvatarUrl: reservation.ownerAvatarUrl,
                memberSince: nil,
                pickupsCount: nil,
                variant: reservationVariant(for: reservation),
                deadline: reservation.pickupDeadline,
                reservationActionConfig: overlayActionConfig,
                onDismiss: { selectedReservation = nil },
                onPrimaryAction: { handlePrimaryAction(for: reservation) },
                onSecondaryAction: {
                    onCancel(reservationId: reservation.id)
                    selectedReservation = nil
                },
                onTertiaryAction: reservation.mode == .street ? {
                    onDirections(reservation: reservation)
                } : nil,
                onReservationAction: overlayActionConfig == nil ? nil : { action in
                    handleReservationActionSwitch(action, reservation)
                }
            )
            .background(Color(.systemBackground))
            .ignoresSafeArea()
        }
    }

    private func handleReservationActionSwitch(_ action: ReservationActionBar.Action, _ reservation: ReservationRow) {
        switch action {
        case .directions:
            onDirections(reservation: reservation)
        case .pickup:
            onPickup(reservationId: reservation.id)
        case .cancel:
            onCancel(reservationId: reservation.id)
        }
    }

    // MARK: - View Modifiers
    struct AuthenticationModifier: ViewModifier {
        let svc: SupabaseService
        let maybeLoadReservations: () async -> Void
        
        func body(content: Content) -> some View {
            content
                .onChange(of: svc.isAuthenticated) { _, _ in
                    Task { await maybeLoadReservations() }
                }
                .onChange(of: svc.session?.accessToken ?? "") { _, _ in
                    Task { await maybeLoadReservations() }
                }
        }
    }

    struct NotificationModifier: ViewModifier {
        @Binding var pendingContactRefreshId: String?
        @Binding var pendingOpenReservationId: String?
        let loadReservations: () async -> Void
        let updateLocalReservationContact: (String, String) -> Void
        let presentReservationIfPossible: () -> Void
        let insertOptimisticReservation: (ReservationRow) -> Void
        let removeOptimisticReservation: (String) -> Void
        
        func body(content: Content) -> some View {
            content
                .onReceive(NotificationCenter.default.publisher(for: .refreshReservations)) { note in
                    if let reservationId = note.object as? String {
                        pendingContactRefreshId = reservationId
                    }
                    Task { await loadReservations() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .reservationOptimisticInsert)) { note in
                    guard let row = note.object as? ReservationRow else { return }
                    insertOptimisticReservation(row)
                }
                .onReceive(NotificationCenter.default.publisher(for: .reservationOptimisticRemove)) { note in
                    guard let id = note.object as? String else { return }
                    removeOptimisticReservation(id)
                }
                .onReceive(NotificationCenter.default.publisher(for: .reservationContactUpdated)) { note in
                    guard let info = note.userInfo as? [String: Any],
                          let reservationId = info["reservationId"] as? String,
                          let phone = info["contactPhone"] as? String else { return }
                    updateLocalReservationContact(reservationId, phone)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openReservation)) { note in
                    guard let reservationId = note.object as? String else { return }
                    pendingOpenReservationId = reservationId
                    presentReservationIfPossible()
                    Task { await loadReservations() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .profileDidUpdate)) { _ in
                    Task { await loadReservations() }
                }
        }
    }

    struct TimerModifier: ViewModifier {
        let timer: Publishers.Autoconnect<Timer.TimerPublisher>
        @Binding var clock: Date
        @Binding var reservations: [ReservationRow]
        let loadReservations: () async -> Void
        
        func body(content: Content) -> some View {
            content
                .onReceive(timer) { now in
                    clock = now
                    let before = reservations.count
                    if before > 0 {
                        reservations.removeAll { $0.isExpired }
                        let after = reservations.count
                        if after < before {
                            Task { await loadReservations() }
                        }
                    }
                }
        }
    }

    struct ContactDialogViewModifier: ViewModifier {
        @Binding var showContactOptions: Bool
        @Binding var contactReservation: ReservationRow?
        let dialPhoneNumber: (String) -> Void
        let copyPhoneNumber: (String) -> Void
        
        func body(content: Content) -> some View {
            content.confirmationDialog(
                "Contact giver",
                isPresented: $showContactOptions,
                presenting: contactReservation
            ) { reservation in
                dialogButtons(for: reservation)
            } message: { reservation in
                dialogMessage(for: reservation)
            }
        }
        
        @ViewBuilder
        private func dialogButtons(for reservation: ReservationRow) -> some View {
            if let phone = reservation.contactDisplayNumber {
                Button("Call \(phone)") { dialPhoneNumber(phone) }
                Button("Copy number") { copyPhoneNumber(phone) }
            }
            Button("Cancel", role: .cancel) {
                contactReservation = nil
            }
        }
        
        @ViewBuilder
        private func dialogMessage(for reservation: ReservationRow) -> some View {
            if let phone = reservation.contactDisplayNumber {
                Text(phone)
            }
        }
    }

    struct ReservationCoverViewModifier: ViewModifier {
        @Binding var selectedReservation: ReservationRow?
        let buildOverlay: (ReservationRow) -> AnyView
        
        func body(content: Content) -> some View {
            content.fullScreenCover(
                item: $selectedReservation,
                onDismiss: { selectedReservation = nil }
            ) { reservation in
                buildOverlay(reservation)
            }
        }
    }

    private struct ActionDialogViewModifier: ViewModifier {
        @Binding var pendingAction: PendingReservationAction?
        let handlePickup: (String) async -> Void
        let handleCancel: (String) async -> Void
        
        func body(content: Content) -> some View {
            content.confirmationDialog(
                pendingAction?.dialogTitle ?? "",
                isPresented: Binding<Bool>(
                    get: { pendingAction != nil },
                    set: { if !$0 { pendingAction = nil } }
                ),
                presenting: pendingAction
            ) { action in
                actionButtons(for: action)
            } message: { action in
                Text(action.message)
            }
        }
        
        @ViewBuilder
        private func actionButtons(for action: PendingReservationAction) -> some View {
            switch action.kind {
            case .pickup:
                Button(action.confirmButtonTitle) {
                    Task { await handlePickup(action.reservationId) }
                }
            case .cancel:
                Button(action.confirmButtonTitle, role: .destructive) {
                    Task { await handleCancel(action.reservationId) }
                }
            }
            Button("Not now", role: .cancel) { }
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
        Task {
            _ = try? await LocationService.shared.currentCoordinate()
        }
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
            // Map and filter out expired reservations upfront
            let rows = apiReservations
                .map(ReservationRow.init)
                .filter { !$0.isExpired }
            await MainActor.run {
                reservations = rows
                hydrateMissingLocations(for: rows)
                isLoading = false

                if pendingContactRefreshId != nil {
                    // Do not auto-present any contact dialog or toast on first load
                    pendingContactRefreshId = nil
                }

                presentReservationIfPossible()
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

    @MainActor
    private func hydrateMissingLocations(for rows: [ReservationRow]) {
        guard let api else { return }
        let needsHydration = rows.filter {
            $0.mode == .street &&
            $0.exactCoordinate == nil &&
            LocationCache.shared.coordinate(for: $0.postId, mode: .street) == nil
        }

        for row in needsHydration {
            guard !hydratingPostIds.contains(row.postId) else { continue }
            hydratingPostIds.insert(row.postId)

            Task {
                do {
                    let hydratedPost = try await fetchWithRetry(svc: svc) {
                        try await api.getPost(row.postId)
                    }
                    LocationCache.shared.store(post: hydratedPost)
                    if let coord = hydratedPost.exactCoordinate {
                        await MainActor.run {
                            for index in reservations.indices where reservations[index].postId == row.postId {
                                reservations[index].exactCoordinate = coord
                            }
                        }
                    }
                } catch {
                    #if DEBUG
                    DLog("[RESERVATIONS] hydrate failed post=\(row.postId) error=\(error.localizedDescription)")
                    #endif
                }
                await MainActor.run {
                    hydratingPostIds.remove(row.postId)
                }
            }
        }
    }

    @MainActor
    private func presentReservationIfPossible() {
        guard let targetId = pendingOpenReservationId else { return }
        guard let reservation = reservations.first(where: { $0.id == targetId }) else { return }
        selectedReservation = reservation
        pendingOpenReservationId = nil
    }

    @MainActor
    private func updateLocalReservationContact(reservationId: String, contactPhone: String) {
        var didUpdate = false
        if let index = reservations.firstIndex(where: { $0.id == reservationId }) {
            reservations[index].contactPhone = contactPhone
            didUpdate = true
        }

        if var current = selectedReservation, current.id == reservationId {
            current.contactPhone = contactPhone
            selectedReservation = current
        }

        if didUpdate && pendingContactRefreshId == reservationId {
            pendingContactRefreshId = nil
            contactReservation = reservations.first(where: { $0.id == reservationId })
            if contactReservation?.canContact == true {
                showContactOptions = true
            }
        } else if !didUpdate && pendingContactRefreshId == nil {
            pendingContactRefreshId = reservationId
        }
    }
    
    private func applyApprovedPhones(_ map: [UUID: String]) {
        for (identifier, phone) in map {
            updateLocalReservationContact(reservationId: identifier.uuidString, contactPhone: phone)
        }
    }
    
    @MainActor
    private func insertOrUpdateOptimisticReservation(_ row: ReservationRow) {
        if let index = reservations.firstIndex(where: { $0.id == row.id }) {
            reservations[index] = row
        } else {
            reservations.insert(row, at: 0)
        }
    }
    
    @MainActor
    private func removeOptimisticReservation(id: String) {
        if let idx = reservations.firstIndex(where: { $0.id == id }) {
            reservations.remove(at: idx)
        }
        if selectedReservation?.id == id { selectedReservation = nil }
    }
    
    private func logContactStates(for rows: [ReservationRow]) {
        for reservation in rows where reservation.isHome {
            let enabled = reservation.canContact
            if loggedContactStates[reservation.id] != enabled {
                loggedContactStates[reservation.id] = enabled
                Metrics.contactButtonState(
                    reservationId: reservation.id,
                    postId: reservation.postId,
                    enabled: enabled
                )
            }
        }
    }

    // MARK: - Computed Sections

    private var visibleReservations: [ReservationRow] {
        // Ensure no expired items slip through and keep newest first
        reservations
            .filter { !$0.isExpired }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    private func actionConfiguration(for reservation: ReservationRow) -> ReservationActionBarConfiguration {
        var config = ReservationActionBarConfiguration()
        let loading = loadingActionMap[reservation.id]
        let isExpired = reservation.isExpired || reservation.status == .expired
        let hasCoordinate = reservation.streetCoordinate != nil

        config.showDirections = true
        config.showPickup = true
        config.showCancel = true

        config.isDirectionsEnabled = hasCoordinate && !isExpired && loading == nil
        config.isPickupEnabled = reservation.effectiveStatus == .active && !isExpired && loading == nil
        config.isCancelEnabled = (reservation.effectiveStatus == .active || reservation.status == .pending) && !isExpired && loading == nil

        config.pickupLoading = loading == .pickup
        config.cancelLoading = loading == .cancel

        if loading == .pickup {
            config.isCancelEnabled = false
            config.isDirectionsEnabled = false
        } else if loading == .cancel {
            config.isPickupEnabled = false
            config.isDirectionsEnabled = false
        }

        if !hasCoordinate {
            config.directionsUnavailableReason = "Waiting for pickup pin"
        }

        if isExpired {
            config.directionsUnavailableReason = "Reservation expired"
            config.isPickupEnabled = false
            config.isCancelEnabled = false
            config.isDirectionsEnabled = false
        }

        return config
    }

    private func setLoading(action: ReservationActionBar.Action?, for reservationId: String) {
        if let action {
            loadingActionMap[reservationId] = action
        } else {
            loadingActionMap.removeValue(forKey: reservationId)
        }
    }

    private func removeReservation(reservationId: String, postId: String) {
        reservations.removeAll { $0.id == reservationId }
        LocationCache.shared.remove(postId: postId)
        if selectedReservation?.id == reservationId {
            selectedReservation = nil
        }
    }
    
    @MainActor
    private func scheduleReservationsRefresh(after seconds: Double = 1.2) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await loadReservations()
        }
    }

    private func shouldTreatAsResolved(_ error: Error) -> Bool {
        if let apiError = error as? ApiServiceError {
            switch apiError {
            case .notFound:
                return true
            case .serverError(let message):
                let normalized = message.lowercased()
                return ["already", "expired", "no longer"].contains { normalized.contains($0) }
            default:
                break
            }
        }

        if let http = error as? ApiHTTPError, http.statusCode == 404 {
            return true
        }

        let message = error.localizedDescription.lowercased()
        let keywords = ["already", "expired", "not found", "no longer"]
        return keywords.contains { message.contains($0) }
    }

    private func readableMessage(from error: Error) -> String {
        if let apiError = error as? ApiServiceError {
            switch apiError {
            case .serverError(let message): return message
            default: return apiError.localizedDescription
            }
        }
        if let httpError = error as? ApiHTTPError {
            return httpError.errorDescription ?? "Unexpected error"
        }
        return error.localizedDescription
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
                router.selectedTab = .feed
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
        let config = reservation.mode == .street ? actionConfiguration(for: reservation) : nil
        let isBusy = loadingActionMap[reservation.id] != nil
        return ReservationCard(
            reservation: reservation,
            isBusy: isBusy,
            actionConfig: config,
            imageTransition: imageTransition,
            tick: clock,
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
        HStack(spacing: 12) {
            Text(toastMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)

            if let retryAction = toastRetryAction {
                Button("Retry") {
                    showToast = false
                    toastRetryAction = nil
                    retryAction()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background((toastIsError ? Color.red : Color.black).opacity(0.85))
        .clipShape(Capsule())
        .padding(.horizontal, AppTheme.Spacing.chromeSide)
        .padding(.bottom, 100)
    }

    // MARK: - Actions

    private func onPickup(reservationId: String) {
        guard reservations.contains(where: { $0.id == reservationId }) else { return }
        pendingAction = PendingReservationAction(kind: .pickup, reservationId: reservationId)
    }

    private func onCancel(reservationId: String) {
        pendingAction = PendingReservationAction(kind: .cancel, reservationId: reservationId)
    }

    private func onDirections(reservation: ReservationRow) {
        guard reservation.mode == .street, let coordinate = reservation.streetCoordinate else { return }
        MapHelper.openAppleMaps(coordinate: coordinate, name: reservation.title)
    }

    private func onContact(reservation: ReservationRow) {
        Metrics.contactButtonTap(reservationId: reservation.id, postId: reservation.postId)
        switch (reservation.mode, reservation.status) {
        case (.home, .pending):
            showToastMessage("Waiting for giver's confirmation")
        case (.home, .active):
            if reservation.canContact, reservation.contactDisplayNumber != nil {
                contactReservation = reservation
                showContactOptions = true
            } else {
                pendingContactRefreshId = reservation.id
                NotificationCenter.default.post(name: .refreshReservations, object: reservation.id)
            }
        case (_, .picked):
            showToastMessage("Already picked up.")
        case (_, .canceled), (_, .expired):
            showToastMessage("Reservation is no longer active.")
        default:
            break
        }
    }

    @MainActor
    private func handlePickup(reservationId: String) async {
        guard let api else { return }
        guard let reservation = reservations.first(where: { $0.id == reservationId }) else { return }
        let allowedStatuses: [ReservationStatus] = reservation.mode == .street ? [.active, .pending] : [.active]
        guard allowedStatuses.contains(reservation.status) else {
            showToastMessage("Can only pick up active reservations", isError: true)
            return
        }

        setLoading(action: .pickup, for: reservationId)
        defer { setLoading(action: nil, for: reservationId) }

        do {
            try await fetchWithRetry(svc: svc) {
                try await api.completeReservation(reservationId)
            }

            Haptics.play(.success)
            removeReservation(reservationId: reservationId, postId: reservation.postId)
            showToastMessage("Item marked as picked up")

            if ConsentManager.shared.analytics == .provided {
                let userId = svc.userId?.uuidString ?? "unknown"
                let props = Properties()
                    .setProperty("reservationId", to: String(describing: reservationId))
                    .setProperty("userId", to: userId)
                Smartlook.instance.track(event: "ItemPickedUp", properties: props)
            }

            scheduleReservationsRefresh()
            FeedViewModel.requestFeedRefresh()

        } catch {
            if shouldTreatAsResolved(error) {
                removeReservation(reservationId: reservationId, postId: reservation.postId)
                showToastMessage("Reservation is no longer active.")
                scheduleReservationsRefresh()
                FeedViewModel.requestFeedRefresh()
            } else {
                let message = readableMessage(from: error)
                showToastMessage(message, isError: true) {
                    Task { await handlePickup(reservationId: reservationId) }
                }
            }
        }
    }

    @MainActor
    private func handleCancel(reservationId: String) async {
        #if DEBUG || RESERVATIONS_DIAGNOSTICS
        let corr = Diag.generateCorrelationId()
        Diag.log(.action, "cancel.tap", fields: ["corr": corr, "reservationId": reservationId])
        #endif
        
        guard let api else { return }
        guard let reservation = reservations.first(where: { $0.id == reservationId }) else { return }

        #if DEBUG || RESERVATIONS_DIAGNOSTICS
        Diag.log(.action, "cancel.preconditions", fields: [
            "corr": corr,
            "postId": reservation.postId,
            "status": reservation.status.rawValue,
            "mode": reservation.mode.rawValue,
            "onMain": Thread.isMainThread
        ])
        #endif

        setLoading(action: .cancel, for: reservationId)
        defer { setLoading(action: nil, for: reservationId) }

        do {
            let isOwner: Bool = {
                guard let uid = svc.userId?.uuidString else { return false }
                return uid.lowercased() == reservation.ownerId.lowercased()
            }()

            try await fetchWithRetry(svc: svc) {
                #if DEBUG || RESERVATIONS_DIAGNOSTICS
                Diag.log(.action, "cancel.api_call", fields: [
                    "corr": corr,
                    "role": isOwner ? "owner" : "reserver",
                    "postId": reservation.postId
                ])
                #endif
                if isOwner {
                    #if DEBUG || RESERVATIONS_DIAGNOSTICS
                    try await api.cancelReservation(id: reservationId, corr: corr)
                    #else
                    try await api.cancelReservation(id: reservationId)
                    #endif
                } else {
                    try await api.cancelReservation(postId: reservation.postId)
                }
            }

            #if DEBUG || RESERVATIONS_DIAGNOSTICS
            Diag.log(.store, "cancel.success", fields: ["corr": corr, "reservationId": reservationId])
            Diag.assertMainThread(corr: corr, context: "cancel.state_update")
            #endif

            Haptics.play(.success)
            removeReservation(reservationId: reservationId, postId: reservation.postId)
            showToastMessage("Reservation canceled")
            // Trigger refetches for reservations and notifications consumers
            NotificationCenter.default.post(name: .refreshReservations, object: reservationId)
            scheduleReservationsRefresh()
            FeedViewModel.requestFeedRefresh()

        } catch {
            #if DEBUG || RESERVATIONS_DIAGNOSTICS
            Diag.log(.error, "cancel.failed", fields: [
                "corr": corr,
                "error": error.localizedDescription,
                "shouldResolve": shouldTreatAsResolved(error)
            ])
            #endif
            if shouldTreatAsResolved(error) {
                removeReservation(reservationId: reservationId, postId: reservation.postId)
                showToastMessage("Reservation is no longer active.")
                NotificationCenter.default.post(name: .refreshReservations, object: reservationId)
                scheduleReservationsRefresh()
                FeedViewModel.requestFeedRefresh()
            } else {
                let message = readableMessage(from: error)
                showToastMessage(message, isError: true) {
                    Task { await handleCancel(reservationId: reservationId) }
                }
            }
        }
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

    private func showToastMessage(
        _ message: String,
        isError: Bool = false,
        retryAction: (() -> Void)? = nil
    ) {
        toastMessage = message
        toastIsError = isError
        toastRetryAction = retryAction
        showToast = true

        let delay: TimeInterval = retryAction == nil ? 3 : 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if toastRetryAction == nil {
                withAnimation { showToast = false }
            }
        }
    }

    private func primaryInfoText(for reservation: ReservationRow) -> String {
        if reservation.mode == .street {
            if let pickup = reservation.streetCoordinate,
               let user = LocationService.shared.lastKnownCoordinate {
                return DistanceFormatterHelper.formattedDistance(from: user, to: pickup)
            }
            if let meters = reservation.distanceMeters {
                return DistanceFormatterHelper.formattedDistance(fromMeters: meters)
            }
            return "Street pickup"
        } else {
            return "Address hidden"
        }
    }

    private func statusText(for reservation: ReservationRow) -> String {
        switch reservation.effectiveStatus {
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
            // Street reservations should show countdown in red; Home stays primary
            return reservation.mode == .street ? Color("SwoopyRed") : AppTheme.ColorToken.primary
        case .picked:
            return AppTheme.ColorToken.success
        case .canceled, .expired:
            return AppTheme.ColorToken.mutedGray
        }
    }

    private func reservationVariant(for reservation: ReservationRow) -> BigCardOverlay.Variant {
        switch (reservation.mode, reservation.status) {
        case (.street, .pending):
            return .reservations(.streetPending)
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
        case (.street, .pending):
            showToastMessage("Awaiting owner approval")
        case (.home, .pending), (.home, .active):
            onContact(reservation: reservation)
        default:
            break
        }
    }
}

private struct PendingReservationAction: Identifiable {
    enum Kind { case pickup, cancel }

    let kind: Kind
    let reservationId: String

    var id: String { reservationId + "-" + (kind == .pickup ? "pickup" : "cancel") }

    var confirmButtonTitle: String {
        switch kind {
        case .pickup: return "Yes, picked up"
        case .cancel: return "Yes, cancel"
        }
    }

    var message: String {
        switch kind {
        case .pickup: return "Mark this reservation as picked up?"
        case .cancel: return "Cancel this reservation?"
        }
    }

    var dialogTitle: String {
        switch kind {
        case .pickup: return "Picked up?"
        case .cancel: return "Cancel reservation?"
        }
    }
}

// MARK: - ReservationCard

private struct ReservationCard: View {
    let reservation: ReservationRow
    let isBusy: Bool
    let actionConfig: ReservationActionBarConfiguration?
    let imageTransition: Namespace.ID
    let tick: Date
    let onTap: () -> Void
    let onPickUp: () -> Void
    let onCancel: () -> Void
    let onDirections: () -> Void
    let onContact: () -> Void

    @ObservedObject private var locationService = LocationService.shared
    @State private var addressText: String
    @State private var locationSummaryText: String?

    init(
        reservation: ReservationRow,
        isBusy: Bool,
        actionConfig: ReservationActionBarConfiguration?,
        imageTransition: Namespace.ID,
        tick: Date,
        onTap: @escaping () -> Void,
        onPickUp: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDirections: @escaping () -> Void,
        onContact: @escaping () -> Void
    ) {
        self.reservation = reservation
        self.isBusy = isBusy
        self.actionConfig = actionConfig
        self.imageTransition = imageTransition
        self.tick = tick
        self.onTap = onTap
        self.onPickUp = onPickUp
        self.onCancel = onCancel
        self.onDirections = onDirections
        self.onContact = onContact
        _addressText = State(initialValue: reservation.streetDisplayAddress ?? "")
        _locationSummaryText = State(initialValue: nil)
    }

    private var isLoading: Bool { isBusy }

    var body: some View {
        Group {
            if reservation.isHome {
                homeCard
            } else {
                streetCard
            }
        }
        .task(id: locationTaskID) {
            await updateLocationData(requestFreshLocation: true)
        }
        .onReceive(locationService.$lastFix) { _ in
            Task { await updateDistanceSummary(forceRefresh: false) }
        }
    }

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
                        .buttonStyle(SwoopyPrimaryButtonStyle(minHeight: 44))
                        .disabled(isLoading || !reservation.canContact)
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

            if let actionConfig {
                HStack(spacing: 8) {
                    if actionConfig.showPickup {
                        Button(action: onPickUp) {
                            buttonLabel(title: "Pick up", loading: actionConfig.pickupLoading)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .layoutPriority(1)
                        .buttonStyle(SwoopyPrimaryButtonStyle())
                        .disabled(!actionConfig.isPickupEnabled)
                        .opacity(actionConfig.isPickupEnabled ? 1 : 0.6)
                    }

                    if actionConfig.showCancel {
                        Button(action: onCancel) {
                            buttonLabel(title: "Cancel", loading: actionConfig.cancelLoading)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .layoutPriority(1)
                        .buttonStyle(SwoopyOutlineButtonStyle())
                        .disabled(!actionConfig.isCancelEnabled)
                        .opacity(actionConfig.isCancelEnabled ? 1 : 0.6)
                    }

                    if actionConfig.showDirections {
                        Button("Directions", action: onDirections)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .layoutPriority(1)
                            .buttonStyle(SwoopyPillSecondaryStyle())
                            .disabled(!actionConfig.isDirectionsEnabled)
                            .opacity(actionConfig.isDirectionsEnabled ? 1 : 0.6)
                    }
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

    private var thumbnail: some View {
        AsyncImage(url: reservation.primaryImageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure, .empty:
                Rectangle().fill(AppTheme.ColorToken.mutedGray.opacity(0.2))
            @unknown default:
                Rectangle().fill(AppTheme.ColorToken.mutedGray.opacity(0.2))
            }
        }
        .frame(width: Layout.thumbnail, height: Layout.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .matchedGeometryEffect(id: "image-\(reservation.id)", in: imageTransition)
    }

    private var conditionRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(reservation.condition.dotColor)
                .frame(width: 8, height: 8)

            Text(reservation.condition.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color("SwoopyDeepGreen").opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Spacer()
        }
    }

    private var streetTextBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            EmptyView().id(tick)

            if let summary = distanceText {
                Text(summary)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            if !addressText.isEmpty {
                Text(addressText)
                    .font(.footnote)
                    .foregroundStyle(Color("SwoopyDeepGreen"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } else if reservation.streetCoordinate == nil {
                Text("Waiting for pickup pin")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
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

            switch reservation.effectiveStatus {
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

    private var distanceText: String? {
        if let summary = locationSummaryText, !summary.isEmpty {
            return summary
        }
        if let meters = reservation.distanceMeters {
            return formatDistance(meters)
        }
        return nil
    }

    private func buttonLabel(title: String, loading: Bool) -> some View {
        HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            Text(title)
                .font(.headline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1f km away", meters / 1_000.0)
        } else {
            return "\(Int(round(meters))) m away"
        }
    }

    private enum Layout {
        static let thumbnail: CGFloat = 96
    }

    private var locationTaskID: String {
        guard reservation.mode == .street, let coordinate = reservation.streetCoordinate else {
            return "\(reservation.id)-home"
        }
        let lat = String(format: "%.5f", coordinate.latitude)
        let lng = String(format: "%.5f", coordinate.longitude)
        return "\(reservation.id)-\(lat)-\(lng)"
    }

    private func updateLocationData(requestFreshLocation: Bool) async {
        guard reservation.mode == .street else {
            await MainActor.run {
                addressText = ""
                locationSummaryText = nil
            }
            return
        }

        await updateDistanceSummary(forceRefresh: requestFreshLocation)

        guard let coordinate = reservation.streetCoordinate else {
            await MainActor.run { addressText = reservation.streetDisplayAddress ?? "" }
            return
        }

        let address = await ReverseGeocoder.shared.address(for: coordinate, cacheKey: reservation.postId)
        await MainActor.run {
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addressText = reservation.streetDisplayAddress ?? ""
            } else {
                addressText = address
            }
        }
    }

    private func updateDistanceSummary(forceRefresh: Bool) async {
        guard reservation.mode == .street, let pickup = reservation.streetCoordinate else {
            await MainActor.run { locationSummaryText = nil }
            return
        }

        var userCoordinate: CLLocationCoordinate2D?
        if forceRefresh {
            if let fresh = try? await LocationService.shared.currentCoordinate() {
                userCoordinate = fresh
            }
        }

        if userCoordinate == nil {
            userCoordinate = locationService.lastFix?.coordinate ?? LocationService.shared.lastKnownCoordinate
        }

        if let userCoordinate {
            let text = DistanceFormatterHelper.formattedDistance(from: userCoordinate, to: pickup)
            await MainActor.run {
                locationSummaryText = text
            }
        } else if let meters = reservation.distanceMeters {
            await MainActor.run {
                locationSummaryText = DistanceFormatterHelper.formattedDistance(fromMeters: meters)
            }
        } else {
            await MainActor.run { locationSummaryText = nil }
        }
    }
}

// MARK: - Formatting Helpers

private func formatRemaining(_ until: Date) -> String {
    let remaining = max(0, Int(until.timeIntervalSinceNow))
    let clamped = min(remaining, 2 * 3600) // Clamp to 2 hours max
    let hours = clamped / 3600
    let minutes = (clamped % 3600) / 60
    if hours > 0 {
        return "Pickup in: \(hours)h \(minutes)m"
    }
    let seconds = clamped % 60
    return String(format: "Pickup in: %02d:%02d", minutes, seconds)
}
