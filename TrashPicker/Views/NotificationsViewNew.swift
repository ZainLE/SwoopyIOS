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
    @State private var processedReservationContactIds: Set<UUID> = []
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
        .confirmationDialog(
            "Contact requester",
            isPresented: $showContactOptions,
            presenting: pendingContactPhone
        ) { phone in
            Button("Call \(phone)") {
                dialPhoneNumber(phone)
            }
            Button("Copy number") {
                copyPhoneNumber(phone)
            }
            Button("Cancel", role: .cancel) {
                pendingContactPhone = nil
            }
        } message: { phone in
            Text(phone)
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
                    ActionableNotificationRow(
                        notification: notification,
                        relativeTime: relativeTime(from: notification.createdAt),
                        isPerformingAction: processingRequestIds.contains(notification.id),
                        onApprove: {
                            pendingApprovalNotification = notification
                            showApprovalPrompt = true
                        },
                        onReject: {
                            Task { await rejectNotification(notification) }
                        },
                        onContact: {
                            if let phone = notification.exposedContactPhone {
                                dialPhoneNumber(phone)
                            }
                        },
                        onCancel: {
                            Task { await cancelNotification(notification) }
                        }
                    )
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
                    let contactAction: (() -> Void)? = {
                        guard let phone = notification.exposedContactPhone,
                              !phone.isEmpty else { return nil }
                        return {
                            pendingContactPhone = phone
                            showContactOptions = true
                        }
                    }()
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
        applyContactUpdateIfNeeded(notification)

        switch notification.type {
        case .home_pickup_request:
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                selectedTab = .actionRequired
            }
        case .street_pickup_confirmed, .request_declined, .request_cancelled_after_acceptance:
            openReservation(for: notification)
        default:
            break
        }

        markNotificationAsReadIfNeeded(notification)
    }

    private func handleNotificationAppear(_ notification: AppNotification) {
        applyContactUpdateIfNeeded(notification)
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

    @MainActor
    private func applyContactUpdateIfNeeded(_ notification: AppNotification) {
        guard let phone = notification.exposedContactPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty,
              let reservationId = notification.reservationId,
              processedReservationContactIds.insert(reservationId).inserted else { return }

        let reservationIdString = reservationId.uuidString
        NotificationCenter.default.post(
            name: .reservationContactUpdated,
            object: nil,
            userInfo: ["reservationId": reservationIdString, "contactPhone": phone]
        )
        NotificationCenter.default.post(name: .refreshReservations, object: reservationIdString)
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
                iconView

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
        default: return "bell.fill"
        }
    }

    private var iconColor: Color {
        switch notification.type {
        case .home_pickup_request: return Color.orange
        case .street_pickup_confirmed: return Color.green
        case .request_declined: return Color.red
        case .request_cancelled_after_acceptance: return Color.gray
        default: return Color.blue
        }
    }

    private var titleText: String {
        switch notification.type {
        case .home_pickup_request:
            return "Home pickup request"
        case .street_pickup_confirmed:
            return "Street pickup confirmed"
        case .request_declined:
            return "Request declined"
        case .request_cancelled_after_acceptance:
            return "Request canceled"
        default:
            return "Notification"
        }
    }

    private var detailText: String? {
        switch notification.type {
        case .home_pickup_request:
            return notification.itemTitle ?? notification.counterpartyName ?? "New request"
        case .street_pickup_confirmed:
            return notification.itemTitle ?? "Pickup confirmed"
        case .request_declined:
            return notification.itemTitle ?? "Your request was declined."
        case .request_cancelled_after_acceptance:
            return notification.itemTitle ?? "The requester canceled."
        default:
            return notification.itemTitle ?? notification.counterpartyName
        }
    }
}
