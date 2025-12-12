import SwiftUI
import UIKit

struct NotificationsTabView: View {
    @EnvironmentObject private var reservationService: ReservationNotificationService
    @EnvironmentObject private var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    
    @StateObject private var viewModel: NotificationsTabViewModel
    @State private var pendingAccept: AppNotification?
    @State private var pendingCancel: AppNotification?
    @State private var reservationContacts: [UUID: String] = [:]
    @State private var contactLoadingIds: Set<UUID> = []
    
    init(service: NotificationService) {
        _viewModel = StateObject(wrappedValue: NotificationsTabViewModel(service: service))
    }
    
    var body: some View {
        List {
            errorSection
            actionRequiredSection
            informationSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Close") { dismiss() }
            }
        }
        .overlay(alignment: .center) {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.toastMessage {
                NotificationsToastView(message: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            reservationService.requestsCount = 0
            reservationService.unreadCount = 0
            await viewModel.onAppear()
        }
        .onChange(of: viewModel.actionRequired) { _ in
            Task { await primeContactsForAccepted() }
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .refreshable {
            await viewModel.refresh()
        }
        // Inline, instant actions (no confirmation dialogs per spec)
    }
    
    private func relativeDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.error {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
    }
    
    private var actionRequiredSection: some View {
        Section("Action Required") {
            if viewModel.actionRequired.isEmpty {
                Label("No home requests right now.", systemImage: "checkmark.circle")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.actionRequired, id: \ .id) { notification in
                    let isPerforming = viewModel.performingActionIDs.contains(notification.id)
                    let availability = contactState(for: notification)
                    let contactPhone = notification.reservationId.flatMap { reservationContacts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ActionableNotificationRow(
                        notification: notification,
                        relativeTime: relativeDateString(notification.createdAt),
                        isPerformingAction: isPerforming,
                        isContactEnabled: availability.enabled,
                        isContactLoading: availability.loading,
                        contactPhone: contactPhone,
                        onApprove: {
                            Task { await viewModel.accept(notification) }
                        },
                        onReject: { viewModel.skip(notification) },
                        onContact: { contact(notification) },
                        onCancel: {
                            Task { await viewModel.cancelAccepted(notification) }
                        }
                    )
                    .contentShape(Rectangle())
                    // No navigation on tap per spec
                }
            }
        }
    }
    
    private var informationSection: some View {
        Section("Information") {
            if viewModel.information.isEmpty {
                Label("No updates yet", systemImage: "bell")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.information, id: \.id) { notification in
                    InformationalNotificationRow(
                        notification: notification,
                        relativeTime: relativeDateString(notification.createdAt)
                    )
                    .contentShape(Rectangle())
                    // No navigation on tap per spec
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.swipeToDismiss(notification)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
    
    private func contact(_ notification: AppNotification) {
        let isHomeAction = notification.category == .actionable && notification.type == .home_pickup_request
        guard isHomeAction, notification.state == .accepted else {
            viewModel.toastMessage = "Contact available after approval"
            return
        }
        guard let reservationId = notification.reservationId else {
            viewModel.toastMessage = "Contact not available yet"
            return
        }

        if let phone = reservationContacts[reservationId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !phone.isEmpty {
            dial(phone)
            return
        }

        Task {
            await refreshContact(for: reservationId, presentIfAvailable: true)
        }
    }

    private func contactState(for notification: AppNotification) -> (enabled: Bool, loading: Bool) {
        guard let reservationId = notification.reservationId else { return (false, false) }
        let phone = reservationContacts[reservationId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let enabled = !phone.isEmpty
        let loading = contactLoadingIds.contains(reservationId)
        return (enabled, loading)
    }

    private func dial(_ phone: String) {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)"), !digits.isEmpty else {
            viewModel.toastMessage = "Can't dial this number"
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func refreshContact(for reservationId: UUID, presentIfAvailable: Bool = false) async {
        guard !contactLoadingIds.contains(reservationId) else { return }
        await MainActor.run {
            contactLoadingIds.insert(reservationId)
        }
        defer {
            Task { @MainActor in
                contactLoadingIds.remove(reservationId)
            }
        }

        let api = ApiService(supabaseService: svc)
        do {
            var resolvedPhone: String?

            if let posts = try? await api.getMyPosts() {
                resolvedPhone = contactFromPosts(posts, reservationId: reservationId)
            }

            if resolvedPhone == nil {
                let reservations = try await api.getMyReservations()
                if let match = reservations.first(where: { $0.id == reservationId.uuidString }) {
                    resolvedPhone = resolvedContactPhone(from: match)
                }
            }

            if let phone = resolvedPhone {
                await MainActor.run {
                    reservationContacts[reservationId] = phone
                }
                if presentIfAvailable { dial(phone) }
            } else if presentIfAvailable {
                await MainActor.run {
                    viewModel.toastMessage = "Contact not available yet"
                }
            }
        } catch {
            if presentIfAvailable {
                await MainActor.run {
                    viewModel.toastMessage = "Contact not available yet"
                }
            }
        }
    }

    private func resolvedContactPhone(from reservation: Reservation) -> String? {
        let direct = reservation.contactPhone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = reservation.post.owner?.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }
        if !owner.isEmpty { return owner }
        return nil
    }

    private func contactMap(from reservations: [Reservation]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for reservation in reservations {
            guard let id = UUID(uuidString: reservation.id),
                  let phone = resolvedContactPhone(from: reservation) else { continue }
            map[id] = phone
        }
        return map
    }

    @MainActor
    private func primeContactsForAccepted() async {
        let missing = viewModel.actionRequired
            .filter { $0.state == .accepted }
            .compactMap { $0.reservationId }
            .filter { reservationContacts[$0]?.isEmpty ?? true }
        guard !missing.isEmpty else { return }
        await refreshContactBatch(ids: missing)
    }

    private func refreshContactBatch(ids: [UUID]) async {
        let unique = Array(Set(ids))
        await MainActor.run {
            contactLoadingIds.formUnion(unique)
        }
        defer {
            Task { @MainActor in
                contactLoadingIds.subtract(unique)
            }
        }
        let api = ApiService(supabaseService: svc)
        do {
            var map: [UUID: String] = [:]
            if let posts = try? await api.getMyPosts() {
                map.merge(contactMap(from: posts)) { _, new in new }
            }
            if map.keys.count < unique.count {
                let reservations = try await api.getMyReservations()
                map.merge(contactMap(from: reservations)) { _, new in new }
            }
            await MainActor.run {
                reservationContacts.merge(map) { _, new in new }
            }
        } catch {
            // Ignore; buttons will stay disabled until next refresh
        }
    }

    private func contactFromPosts(_ posts: [Post], reservationId: UUID) -> String? {
        contactMap(from: posts)[reservationId]
    }

    private func contactMap(from posts: [Post]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for post in posts {
            guard let summary = post.userReservation,
                  let phone = summary.contactPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !phone.isEmpty,
                  let id = UUID(uuidString: summary.id) else { continue }
            map[id] = phone
        }
        return map
    }
}

private struct NotificationsToastView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 12)
    }
}
