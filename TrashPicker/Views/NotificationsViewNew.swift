import SwiftUI
import UIKit

// MARK: - NotificationsViewNew

struct NotificationsViewNew: View {
    @EnvironmentObject var svc: SupabaseService
    @Environment(AppRouter.self) private var router
    @ObservedObject private var notificationService: NotificationService
    
    @State private var selectedTab: Tab = .requests
    @State private var requests: [IncomingRequestItem] = []
    @State private var notifications: [NotificationRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    @State private var showPhoneAlert = false
    @State private var phoneInput = ""
    @State private var pendingApprovalRequest: IncomingRequestItem?
    @State private var showApprovalPrompt = false
    @State private var pendingContactPhone: String?
    @State private var showContactOptions = false
    @State private var processedReservationContactIds: Set<String> = []
    @State private var inFlightReadIds: Set<String> = []
    @State private var processingRequestIds: Set<String> = []
    
    enum Tab: String, CaseIterable {
        case requests = "Requests"
        case notifications = "Notifications"
    }
    
    init(notificationService: NotificationService) {
        _notificationService = ObservedObject(wrappedValue: notificationService)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Segmented Control
            Picker("Tab", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .requests && notificationService.requestsCount > 0 {
                            Text("\(notificationService.requestsCount)")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                        if tab == .notifications && notificationService.unreadCount > 0 {
                            Text("\(notificationService.unreadCount)")
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
            
            // Content
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(message: error)
            } else {
                switch selectedTab {
                case .requests:
                    requestsListView
                case .notifications:
                    notificationsListView
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
        .alert(
            "Share your phone number with the requester?",
            isPresented: $showApprovalPrompt,
            presenting: pendingApprovalRequest
        ) { request in
            Button("Cancel", role: .cancel) {
                pendingApprovalRequest = nil
            }
            Button("Approve") {
                pendingApprovalRequest = nil
                Task { await approveRequest(request) }
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
                Task { await loadData() }
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.ColorToken.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Requests List
    
    private var requestsListView: some View {
        Group {
            if requests.isEmpty {
                ContentUnavailableView(
                    "No pending requests",
                    systemImage: "tray",
                    description: Text("Home pickup requests will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(requests) { request in
                            RequestRow(
                                request: request,
                                timeAgo: relativeTime(from: request.createdAt),
                                isProcessing: processingRequestIds.contains(request.id),
                                onApprove: {
                                    pendingApprovalRequest = request
                                    showApprovalPrompt = true
                                },
                                onSkip: {
                                    Task { await skipRequest(request) }
                                }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
            }
        }
    }
    
    // MARK: - Notifications List
    
    private var notificationsListView: some View {
        Group {
            if notifications.isEmpty {
                ContentUnavailableView(
                    "No notifications yet",
                    systemImage: "bell.badge",
                    description: Text("Updates will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(notifications) { notification in
                            NotificationRow(
                                notification: notification,
                                timeAgo: relativeTime(from: notification.createdAt),
                                onTap: { handleNotificationTap(notification) },
                                onContact: notification.contactPhone?.isEmpty == false ? {
                                    pendingContactPhone = notification.contactPhone
                                    showContactOptions = true
                                } : nil
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
        }
    }
    
    // MARK: - Actions
    
    @MainActor
    private func loadData() async {
        isLoading = true
        errorMessage = nil
        
        do {
            async let requestsTask = notificationService.fetchIncomingRequests()
            async let notificationsTask = notificationService.fetchNotifications()
            
            let (fetchedRequests, fetchedNotifications) = try await (requestsTask, notificationsTask)
            
            requests = fetchedRequests.sorted { $0.createdAt > $1.createdAt }
            notifications = fetchedNotifications.items.sorted { $0.createdAt > $1.createdAt }
            isLoading = false
        } catch {
            errorMessage = "Couldn't load data. Please try again."
            isLoading = false
        }
    }
    
    @MainActor
    private func approveRequest(_ request: IncomingRequestItem) async {
        processingRequestIds.insert(request.id)
        defer { processingRequestIds.remove(request.id) }
        
        do {
            try await notificationService.approveRequest(reservationId: request.reservationId)
            showToast("Approved — your contact was shared")
            requests.removeAll { $0.id == request.id }
            
            // Refresh reservations
            NotificationCenter.default.post(name: .refreshReservations, object: request.reservationId)
        } catch {
            if let apiError = error as? ApiServiceError, case .serverError(let msg) = apiError {
                if msg.lowercased().contains("phone") {
                    showPhoneAlert = true
                    return
                }
            }
            showToast("Couldn't approve request")
        }
    }
    
    @MainActor
    private func skipRequest(_ request: IncomingRequestItem) async {
        processingRequestIds.insert(request.id)
        defer { processingRequestIds.remove(request.id) }
        
        do {
            try await notificationService.skipRequest(reservationId: request.reservationId)
            showToast("Request declined")
            requests.removeAll { $0.id == request.id }
        } catch {
            showToast("Couldn't decline request")
        }
    }

    private func handleNotificationTap(_ notification: NotificationRecord) {
        applyContactUpdateIfNeeded(notification)

        switch notification.type {
        case "new_request":
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                selectedTab = .requests
            }
        case "request_approved":
            openReservation(for: notification)
        default:
            break
        }

        Task { await markNotificationAsRead(notification) }
    }

    private func handleNotificationAppear(_ notification: NotificationRecord) {
        applyContactUpdateIfNeeded(notification)
        guard notification.readAt == nil else { return }
        Task { await markNotificationAsRead(notification) }
    }

    @MainActor
    private func markNotificationAsRead(_ notification: NotificationRecord) async {
        guard notification.readAt == nil else { return }
        guard inFlightReadIds.insert(notification.id).inserted else { return }
        defer { inFlightReadIds.remove(notification.id) }
        do {
            try await notificationService.markRead(id: notification.id)
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[index].readAt = Date()
            }
        } catch {
            #if DEBUG
            DLog("[NOTIFICATIONS] markRead failed: \(error.localizedDescription)")
            #endif
        }
    }

    @MainActor
    private func applyContactUpdateIfNeeded(_ notification: NotificationRecord) {
        guard notification.type == "request_approved",
              let phone = notification.contactPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty,
              processedReservationContactIds.insert(notification.reservationId).inserted else { return }

        NotificationCenter.default.post(
            name: .reservationContactUpdated,
            object: nil,
            userInfo: ["reservationId": notification.reservationId, "contactPhone": phone]
        )
        NotificationCenter.default.post(name: .refreshReservations, object: notification.reservationId)
    }

    private func openReservation(for notification: NotificationRecord) {
        router.selectedTab = .reservations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .openReservation, object: notification.reservationId)
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
    
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Request Row

private struct RequestRow: View {
    let request: IncomingRequestItem
    let timeAgo: String
    let isProcessing: Bool
    let onApprove: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.15))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                        )
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text((request.post.title?.isEmpty ?? true) ? "Untitled listing" : (request.post.title ?? "Untitled listing"))
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(request.requester.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.ColorToken.primary)

                    Text(timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(AppTheme.ColorToken.primary)
                }
            }

            HStack(spacing: 12) {
                Button("Approve", action: onApprove)
                    .buttonStyle(SwoopyPrimaryButtonStyle(minHeight: 44))
                    .disabled(isProcessing)
                    .opacity(isProcessing ? 0.6 : 1.0)

                Button("Skip", action: onSkip)
                    .buttonStyle(SwoopyOutlineButtonStyle(minHeight: 44))
                    .disabled(isProcessing)
                    .opacity(isProcessing ? 0.6 : 1.0)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var thumbnailURL: URL? {
        guard let raw = request.post.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), !raw.isEmpty else { return nil }
        return url
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let notification: NotificationRecord
    let timeAgo: String
    let onTap: () -> Void
    let onContact: (() -> Void)?

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

                if notification.readAt == nil {
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
        case "street_reserved": return "mappin.circle.fill"
        case "new_request": return "hand.raised.fill"
        case "request_approved": return "checkmark.circle.fill"
        case "request_rejected": return "xmark.octagon.fill"
        case "request_withdrawn": return "arrow.uturn.backward.circle.fill"
        case "pickup_completed": return "checkmark.seal.fill"
        case "request_expired": return "clock.fill"
        default: return "bell.fill"
        }
    }

    private var iconColor: Color {
        switch notification.type {
        case "street_reserved": return Color.blue
        case "new_request": return Color.orange
        case "request_approved": return Color.green
        case "request_rejected": return Color.red
        case "request_withdrawn": return Color.gray
        case "pickup_completed": return Color.green
        case "request_expired": return Color.orange
        default: return Color.gray
        }
    }

    private var titleText: String {
        switch notification.type {
        case "street_reserved":
            return "Someone reserved your street listing"
        case "new_request":
            return "Pickup request for your home listing"
        case "request_approved":
            return "Request approved"
        case "request_rejected":
            return "Request declined"
        case "request_withdrawn":
            return "Request withdrawn"
        case "request_expired":
            return "Request expired"
        case "pickup_completed":
            return "Pickup completed"
        default:
            return "Notification"
        }
    }

    private var detailText: String? {
        let title = notification.post.title?.isEmpty == false ? notification.post.title! : nil

        switch notification.type {
        case "street_reserved":
            return title
        case "new_request":
            if let title {
                return "\(notification.counterparty.displayName) • \(title)"
            }
            return notification.counterparty.displayName
        case "request_approved":
            if let phone = notification.contactPhone, !phone.isEmpty {
                return "Contact: \(phone)"
            }
            return title
        case "request_rejected":
            return "The owner declined your request."
        case "request_withdrawn":
            return "The requester withdrew their reservation."
        case "request_expired":
            return "The reservation expired."
        case "pickup_completed":
            return title ?? "Pick up completed"
        default:
            return title
        }
    }
}
