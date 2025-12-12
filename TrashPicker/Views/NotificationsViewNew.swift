import SwiftUI
import UIKit
import Combine

// MARK: - NotificationsViewNew

struct NotificationsViewNew: View {
    @StateObject private var viewModel: NotificationsScreenViewModel
    @EnvironmentObject private var svc: SupabaseService
    @EnvironmentObject private var reservationNotificationService: ReservationNotificationService
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var selectedTab: Tab = .actionRequired
    @State private var toastMessage: String?
    @State private var showPhoneAlert = false
    @State private var phoneInput = ""
    @State private var pendingApprovalNotification: AppNotification?
    @State private var showApprovalPrompt = false
    @State private var pendingContactPhone: String?
    @State private var showContactOptions = false
    @State private var contactPopoverNotificationId: String?
    @State private var reservationContacts: [UUID: ReservationContact] = [:]
    @State private var contactLoadingIds: Set<UUID> = []
    @State private var inFlightReadIds: Set<String> = []
    @State private var processingRequestIds: Set<String> = []
    
    init(viewModel: NotificationsScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    enum Tab: String, CaseIterable {
        case actionRequired = "Action Required"
        case updates = "Updates"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .actionRequired && viewModel.actionable.count > 0 {
                            Text("\(viewModel.actionable.count)")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                        if tab == .updates && viewModel.unreadCount > 0 {
                            Text("\(viewModel.unreadCount)")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                    }
                    .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            switch selectedTab {
            case .actionRequired:
                actionRequiredContent
            case .updates:
                updatesContent
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            CameraSessionManager.shared.stop()
        }
        .onDisappear {
            viewModel.cancelPendingRequests()
        }
        .task {
            await refreshAndLogCurrentTab()
        }
        .refreshable {
            await refreshAndLogCurrentTab(force: true)
        }
        .alert(
            "Share your phone number with the requester?",
            isPresented: $showApprovalPrompt,
            presenting: pendingApprovalNotification
        ) { notification in
            Button("Cancel", role: .cancel) {
                pendingApprovalNotification = nil
            }
            Button("Approve") {
                pendingApprovalNotification = nil
                Task { await approveNotification(notification) }
            }
        } message: { _ in
            Text("Approving will share your saved phone number with the requester.")
        }
        .alert("Add Phone Number", isPresented: $showPhoneAlert) {
            TextField("Phone number", text: $phoneInput)
                .keyboardType(.phonePad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await savePhoneNumber() }
            }
        } message: {
            Text("Add a phone number to approve home pickups.")
        }
        .overlay(alignment: .top) {
            if let message = toastMessage {
                Text(message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshReservations)) { _ in
            Task { await refreshAndLogCurrentTab() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshAndLogCurrentTab() }
            }
        }
        .onChange(of: selectedTab) { _, _ in
            Task { await refreshAndLogCurrentTab() }
        }
        .onChange(of: viewModel.actionable) { _, actionable in
            Task { await refreshReservationContactsIfNeeded(for: actionable) }
        }
    }
    
    @ViewBuilder
    private var actionRequiredContent: some View {
        if viewModel.isLoading {
            loadingView
        } else if let message = viewModel.error {
            errorView(message: message)
        } else if viewModel.actionable.isEmpty {
            emptyRequestsView
        } else {
            requestsListView(viewModel.actionable)
                .onAppear {
                    viewModel.refresh()
                }
        }
    }
    
    @ViewBuilder
    private var updatesContent: some View {
        if viewModel.isLoading {
            loadingView
        } else if let message = viewModel.error {
            errorView(message: message)
        } else if viewModel.informational.isEmpty {
            emptyUpdatesView
        } else {
            notificationsListView(viewModel.informational)
                .onAppear {
                    viewModel.refresh()
                }
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.ColorToken.primary)
            Text("Loading…")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Error View
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load notifications",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            Button("Retry") {
                Task { await refreshAndLogCurrentTab() }
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.ColorToken.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Requests List
    
    private func requestsListView(_ notifications: [AppNotification]) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(notifications) { notification in
                    let contactPhone = notification.reservationId.flatMap { reservationContacts[$0]?.trimmedPhone }
                    ActionableNotificationRow(
                        notification: notification,
                        relativeTime: relativeTime(from: notification.createdAt),
                        isPerformingAction: processingRequestIds.contains(notification.id),
                        isContactEnabled: contactAvailability(for: notification).enabled,
                        isContactLoading: contactAvailability(for: notification).loading,
                        contactPhone: contactPhone,
                        onApprove: {
                            pendingApprovalNotification = notification
                            showApprovalPrompt = true
                        },
                        onReject: {
                            Task { await rejectNotification(notification) }
                        },
                        onContact: {
                            handleContactTap(notification)
                        },
                        onCancel: {
                            Task { await cancelNotification(notification) }
                        }
                    )
                    .popover(
                        isPresented: Binding(
                            get: { showContactOptions && contactPopoverNotificationId == notification.id },
                            set: { presenting in
                                if !presenting {
                                    showContactOptions = false
                                    pendingContactPhone = nil
                                    contactPopoverNotificationId = nil
                                }
                            }
                        ),
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        contactPopoverContent()
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
    }
    
    private var emptyRequestsView: some View {
        ContentUnavailableView(
            "No pending requests",
            systemImage: "tray",
            description: Text("Home pickup requests will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Notifications List
    
    private func notificationsListView(_ notifications: [AppNotification]) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(notifications) { notification in
                    // Informational updates should never expose contact actions.
                    let contactAction: (() -> Void)? = nil
                    let deleteAction: (() -> Void)? = notification.category == .informational ? {
                        Task { await deleteNotification(notification) }
                    } : nil
                    NotificationRow(
                        notification: notification,
                        timeAgo: relativeTime(from: notification.createdAt),
                        onTap: { handleNotificationTap(notification) },
                        onContact: contactAction,
                        onDelete: deleteAction
                    )
                    .padding(.horizontal, 16)
                    .onAppear {
                        handleNotificationAppear(notification)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
    }
    
    private var emptyUpdatesView: some View {
        ContentUnavailableView(
            "No notifications yet",
            systemImage: "bell.badge",
            description: Text("Updates will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Actions
    
    @MainActor
    private func approveNotification(_ notification: AppNotification) async {
        guard let reservationId = notification.reservationId else {
            showToast("Missing reservation")
            return
        }
        Metrics.notificationsApproveTap(
            reservationId: reservationId.uuidString,
            postId: notification.postId?.uuidString ?? "unknown"
        )
        processingRequestIds.insert(notification.id)
        defer { processingRequestIds.remove(notification.id) }

        do {
            try await viewModel.approve(notification)
            showToast("Approved — your contact was shared")
            NotificationCenter.default.post(name: .refreshReservations, object: reservationId.uuidString)
            viewModel.refresh(force: true)
            await refreshReservationContacts(for: [reservationId])
            // No navigation - state updates inline
        } catch {
            #if DEBUG
            DLog("[NOTIFICATIONS] Approve error: \(error.localizedDescription)")
            #endif
            if shouldPromptForPhone(error) {
                showPhoneAlert = true
                return
            }
            if isAlreadyHandled(error) {
                showToast("Already approved")
                NotificationCenter.default.post(name: .refreshReservations, object: reservationId.uuidString)
                return
            }
            showToast("Couldn't approve request")
        }
    }
    
    @MainActor
    private func rejectNotification(_ notification: AppNotification) async {
        guard let reservationId = notification.reservationId else { return }
        Metrics.notificationsDeclineTap(
            reservationId: reservationId.uuidString,
            postId: notification.postId?.uuidString ?? "unknown"
        )
        processingRequestIds.insert(notification.id)
        defer { processingRequestIds.remove(notification.id) }
        do {
            try await viewModel.reject(notification)
            showToast("Request declined")
            viewModel.refresh(force: true)
            NotificationCenter.default.post(name: .refreshReservations, object: reservationId.uuidString)
            // Row removed immediately by ViewModel
        } catch {
#if DEBUG
            DLog("[NOTIFICATIONS] Reject error: \(error.localizedDescription)")
#endif
            showToast("Couldn't decline request")
        }
    }
    
    @MainActor
    private func cancelNotification(_ notification: AppNotification) async {
        guard let reservationId = notification.reservationId else { return }
        processingRequestIds.insert(notification.id)
        defer { processingRequestIds.remove(notification.id) }
        do {
            try await viewModel.cancel(notification)
            showToast("Reservation canceled")
            NotificationCenter.default.post(name: .refreshReservations, object: reservationId.uuidString)
            viewModel.refresh(force: true)
            await refreshReservationContacts(for: [reservationId])
            // Row removed immediately by ViewModel
        } catch {
#if DEBUG
            DLog("[NOTIFICATIONS] Cancel error: \(error.localizedDescription)")
#endif
            showToast("Couldn't cancel reservation")
        }
    }
    
    @MainActor
    private func deleteNotification(_ notification: AppNotification) async {
        do {
            try await viewModel.deleteInformational(notification)
            showToast("Notification removed")
            await refreshAndLogCurrentTab()
        } catch let serviceError as NotificationServiceError {
            showToast(serviceError.localizedDescription ?? "Only informational notifications can be deleted.")
        } catch let apiError as ApiHTTPError {
            if apiError.statusCode == 403 {
                showToast("Only informational notifications can be deleted.")
            } else {
                showToast(apiError.message ?? "Couldn't remove notification")
            }
        } catch {
#if DEBUG
            DLog("[NOTIFICATIONS] Delete error: \(error.localizedDescription)")
#endif
            showToast("Couldn't remove notification")
        }
    }

    private func handleNotificationTap(_ notification: AppNotification) {
        switch notification.type {
        case .home_pickup_request:
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                selectedTab = .actionRequired
            }
        case .street_pickup_confirmed, .request_declined, .request_cancelled_after_acceptance, .request_approved, .legacy_request_approved:
            openReservation(for: notification)
        default:
            break
        }

        markNotificationAsReadIfNeeded(notification)
    }

    private func handleNotificationAppear(_ notification: AppNotification) {
        markNotificationAsReadIfNeeded(notification)
    }
    
    private func markNotificationAsReadIfNeeded(_ notification: AppNotification) {
        guard notification.isUnread else { return }
        guard inFlightReadIds.insert(notification.id).inserted else { return }
        Task {
            await viewModel.markNotificationAsRead(notification)
            await MainActor.run {
                inFlightReadIds.remove(notification.id)
                logTabViewed(selectedTab)
            }
        }
    }

    private func openReservation(for notification: AppNotification) {
        guard let reservationId = notification.reservationId else { return }
        router.selectedTab = .reservations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .openReservation, object: reservationId.uuidString)
        }
    }

    private func dialPhoneNumber(_ phone: String) {
        let dialString = sanitizedDialString(from: phone)
        guard !dialString.isEmpty, let url = URL(string: "tel://\(dialString)") else {
            showToast("Can't dial this number")
            showContactOptions = false
            pendingContactPhone = nil
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        showContactOptions = false
        pendingContactPhone = nil
    }

    private func copyPhoneNumber(_ phone: String) {
        UIPasteboard.general.string = phone
        showContactOptions = false
        pendingContactPhone = nil
        showToast("Number copied")
    }

    private func sanitizedDialString(from phone: String) -> String {
        let allowed = CharacterSet(charactersIn: "+0123456789")
        let scalars = phone.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func savePhoneNumber() async {
        let trimmed = phoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        do {
            try await svc.updateProfile(firstName: nil, lastName: nil, phone: trimmed)
            showToast("Phone number saved")
        } catch {
            showToast("Couldn't save phone number")
        }
    }
    
    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }
    
    private func shouldPromptForPhone(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("phone")
    }
    
    private func isAlreadyHandled(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("not pending") || lower.contains("already") || lower.contains("approved")
    }
    
    private func refreshAndLogCurrentTab(force: Bool = false) async {
        viewModel.refresh(force: force)
        await refreshReservationContactsIfNeeded(for: viewModel.actionable)
        logTabViewed(selectedTab)
    }

    private func logTabViewed(_ tab: Tab) {
        Metrics.notificationsTabViewed(tabName: tab.rawValue)
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func contactPopoverContent() -> some View {
        VStack(spacing: 10) {
            if let phone = pendingContactPhone {
                Button("Call \(phone)") { dialPhoneNumber(phone) }
                    .buttonStyle(.borderedProminent)
                Button("Copy number") { copyPhoneNumber(phone) }
                    .buttonStyle(.bordered)
            } else {
                ProgressView("Loading contact...")
            }
            Button("Close", role: .cancel) {
                pendingContactPhone = nil
                showContactOptions = false
                contactPopoverNotificationId = nil
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Contact Support

    private func contactAvailability(for notification: AppNotification) -> (enabled: Bool, loading: Bool) {
        guard let reservationId = notification.reservationId else { return (false, false) }
        let hasPhone = reservationContacts[reservationId]?.trimmedPhone != nil
        let isLoading = contactLoadingIds.contains(reservationId)
        return (hasPhone, isLoading)
    }

    private func handleContactTap(_ notification: AppNotification) {
        guard notification.state == .accepted else {
            showToast("Contact available after approval")
            return
        }
        guard let reservationId = notification.reservationId else {
            showToast("Missing reservation")
            return
        }
        contactPopoverNotificationId = notification.id
        if let phone = reservationContacts[reservationId]?.trimmedPhone {
            pendingContactPhone = phone
            showContactOptions = true
            return
        }
        Task {
            await refreshReservationContacts(for: [reservationId], presentIfAvailable: true)
        }
    }

    private func refreshReservationContactsIfNeeded(for notifications: [AppNotification]) async {
        let missingIds = notifications
            .filter { $0.state == .accepted }
            .compactMap { $0.reservationId }
            .filter { reservationContacts[$0]?.trimmedPhone == nil && !contactLoadingIds.contains($0) }
        guard !missingIds.isEmpty else { return }
        await refreshReservationContacts(for: missingIds)
    }

    private func refreshReservationContacts(for reservationIds: [UUID], presentIfAvailable: Bool = false) async {
        let uniqueIds = Array(Set(reservationIds))
        await MainActor.run {
            contactLoadingIds.formUnion(uniqueIds)
        }
        defer {
            Task { @MainActor in
                contactLoadingIds.subtract(uniqueIds)
            }
        }

        let api = ApiService(supabaseService: svc)
        do {
            var contactLookup: [UUID: String] = [:]
            // Giver-side: check posts for taker phone
            if let posts = try? await api.getMyPosts() {
                contactLookup.merge(contactMap(from: posts)) { _, new in new }
            }

            // Taker-side fallback: check reservations
            if contactLookup.keys.count < uniqueIds.count {
                let reservations = try await api.getMyReservations()
                contactLookup.merge(contactMap(from: reservations)) { _, new in new }
            }

            await MainActor.run {
                updateReservationContacts(with: contactLookup)
                if presentIfAvailable, let firstId = uniqueIds.first {
                    if let phone = reservationContacts[firstId]?.trimmedPhone {
                        pendingContactPhone = phone
                        showContactOptions = true
                    } else {
                        showToast("Contact not available yet")
                    }
                }
            }
        } catch {
            // Silent failure: leave existing state and allow retry
        }
    }

    @MainActor
    private func updateReservationContacts(with map: [UUID: String]) {
        guard !map.isEmpty else { return }
        var updated = reservationContacts
        for (id, phone) in map {
            updated[id] = ReservationContact(phone: phone)
        }
        reservationContacts = updated
    }

    private func contactMap(from reservations: [Reservation]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for reservation in reservations {
            guard let id = UUID(uuidString: reservation.id),
                  let phone = resolvedPhone(from: reservation) else { continue }
            map[id] = phone
        }
        return map
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

    private func resolvedPhone(from reservation: Reservation) -> String? {
        let direct = reservation.contactPhone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerPhone = reservation.post.owner?.phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        if let ownerPhone, !ownerPhone.isEmpty { return ownerPhone }
        return nil
    }
}

private struct ReservationContact {
    let phone: String?

    var trimmedPhone: String? {
        guard let phone else { return nil }
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let notification: AppNotification
    let timeAgo: String
    let onTap: () -> Void
    let onContact: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                leadingView

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    if let detail = detailText, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Text(timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    if notification.isUnread {
                        Circle()
                            .fill(AppTheme.ColorToken.primary)
                            .frame(width: 8, height: 8)
                    }
                } else if notification.isUnread {
                    Circle()
                        .fill(AppTheme.ColorToken.primary)
                        .frame(width: 8, height: 8)
                }
            }

            if let onContact {
                HStack {
                    Spacer()
                    Button("Contact", action: onContact)
                        .buttonStyle(SwoopyPillSecondaryStyle(minHeight: 40))
                        .frame(maxWidth: 160)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var leadingView: some View {
        if isApprovalUpdate {
            approvalVisual
        } else {
            iconView
        }
    }

    @ViewBuilder
    private var iconView: some View {
        Image(systemName: iconName)
            .font(.title3)
            .foregroundColor(iconColor)
            .frame(width: 42, height: 42)
            .background(iconColor.opacity(0.12))
            .clipShape(Circle())
    }

    private var iconName: String {
        switch notification.type {
        case .home_pickup_request: return "hand.raised.fill"
        case .street_pickup_confirmed: return "mappin.circle.fill"
        case .request_declined: return "xmark.octagon.fill"
        case .request_cancelled_after_acceptance: return "arrow.uturn.backward.circle.fill"
        case .request_approved, .legacy_request_approved: return "checkmark.circle.fill"
        default: return "bell.fill"
        }
    }

    private var iconColor: Color {
        switch notification.type {
        case .home_pickup_request: return Color.orange
        case .street_pickup_confirmed: return Color.green
        case .request_declined: return Color.red
        case .request_cancelled_after_acceptance: return Color.gray
        case .request_approved, .legacy_request_approved: return Color.green
        default: return Color.blue
        }
    }

    private var titleText: String {
        if let payloadTitle = notification.payload?.title, !payloadTitle.isEmpty {
            return payloadTitle
        }
        switch notification.type {
        case .home_pickup_request:
            return "Home pickup request"
        case .street_pickup_confirmed:
            return "Street pickup confirmed"
        case .request_declined:
            return "Request declined"
        case .request_cancelled_after_acceptance:
            return "Request canceled"
        case .request_approved, .legacy_request_approved:
            if let name = notification.counterpartyName, !name.isEmpty {
                return "\(name) approved your request"
            }
            return "Approved your request"
        default:
            return notification.itemTitle ?? notification.counterpartyName ?? "Update"
        }
    }

    private var detailText: String? {
        if let payloadBody = notification.payload?.body, !payloadBody.isEmpty {
            return payloadBody
        }
        switch notification.type {
        case .home_pickup_request:
            return notification.itemTitle ?? notification.counterpartyName ?? "New request"
        case .street_pickup_confirmed:
            return notification.itemTitle ?? "Pickup confirmed"
        case .request_declined:
            return notification.itemTitle ?? "Your request was declined."
        case .request_cancelled_after_acceptance:
            return notification.itemTitle ?? "The requester canceled."
        case .request_approved, .legacy_request_approved:
            return notification.itemTitle ?? "You're approved. Arrange pickup with the giver."
        default:
            return notification.itemTitle ?? notification.counterpartyName
        }
    }

    private var isApprovalUpdate: Bool {
        notification.type == .request_approved || notification.type == .legacy_request_approved
    }

    @ViewBuilder
    private var approvalVisual: some View {
        ZStack(alignment: .bottomTrailing) {
            approvalItemImage
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            approvalAvatar
                .frame(width: 28, height: 28)
                .background(Color(.systemBackground))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                .offset(x: 8, y: 8)
        }
        .frame(width: 64, height: 64)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var approvalItemImage: some View {
        if let url = approvalItemURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                @unknown default:
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.15))
                .overlay(Image(systemName: "photo").foregroundColor(.gray))
        }
    }

    @ViewBuilder
    private var approvalAvatar: some View {
        if let url = notification.counterpartyAvatarURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "person.fill").foregroundColor(.gray))
            }
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .overlay(Image(systemName: "person.fill").foregroundColor(.gray))
        }
    }

    private var approvalItemURL: URL? {
        if let url = notification.itemThumbURL {
            return url
        }
        if let raw = notification.payload?.itemImageUrl, let url = URL(string: raw) {
            return url
        }
        if let raw = notification.payload?.postImageUrl, let url = URL(string: raw) {
            return url
        }
        return nil
    }
}
