import SwiftUI

// MARK: - Notification Models (UI-only)

enum NotificationCategory: Equatable {
    case incomingRequest
    case general(GeneralKind)

    enum GeneralKind: Equatable {
        case requestApproved
        case requestRejected
        case requestWithdrawn
        case pickupCompleted
        case requestExpired
    }
}

// MARK: - Toast & Actions helpers

extension NotificationsView {
    @ViewBuilder
    private func toastView(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.top, 8)
    }

    private func showToast(_ text: String) {
        toastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { toastMessage = nil }
    }

    private func approveSelectedIncoming(retrying: Bool = false) async {
        guard let item = selectedIncoming else { return }
        await MainActor.run {
            detailError = nil
            detailAction = .approving
        }

        let result = await vm.approve(reservationId: item.reservationId, shareContact: true)

        if case .unauthorized = result, !retrying {
            await MainActor.run { detailAction = .idle }
            do {
                try await svc.refreshSessionIfNeeded()
                await approveSelectedIncoming(retrying: true)
            } catch {
                await MainActor.run {
                    detailError = "Please sign in again to continue."
                }
            }
            return
        }

        await MainActor.run {
            detailAction = .idle
            switch result {
            case .success:
                vm.removeIncoming(withId: item.id)
                Metrics.reservationAction(
                    screen: "Notifications",
                    role: "owner",
                    postId: item.postId,
                    reservationId: item.reservationId,
                    mode: item.mode,
                    statusBefore: "pending",
                    statusAfter: "approved"
                )
                showToast("Approved")
                NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                selectedIncoming = nil
            case .alreadyProcessed:
                vm.removeIncoming(withId: item.id)
                Metrics.reservationAction(
                    screen: "Notifications",
                    role: "owner",
                    postId: item.postId,
                    reservationId: item.reservationId,
                    mode: item.mode,
                    statusBefore: "pending",
                    statusAfter: "already_processed"
                )
                showToast("Already processed.")
                NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                selectedIncoming = nil
            case .notFound:
                vm.removeIncoming(withId: item.id)
                Metrics.reservationAction(
                    screen: "Notifications",
                    role: "owner",
                    postId: item.postId,
                    reservationId: item.reservationId,
                    mode: item.mode,
                    statusBefore: "pending",
                    statusAfter: "already_canceled"
                )
                showToast("Already canceled.")
                selectedIncoming = nil
            case .unauthorized:
                showToast("Please sign in again to continue.")
            case .network:
                showToast("Can't reach the server right now. Please try again.")
            case .phoneRequired(let message):
                detailError = message
            case .failure(let msg):
                detailError = msg
            }
        }
    }

    private func cancelSelectedIncoming(retrying: Bool = false) async {
        guard let item = selectedIncoming else { return }
        await MainActor.run {
            detailError = nil
            detailAction = .canceling
        }

        let result = await vm.skip(reservationId: item.reservationId)

        if case .unauthorized = result, !retrying {
            await MainActor.run { detailAction = .idle }
            do {
                try await svc.refreshSessionIfNeeded()
                await cancelSelectedIncoming(retrying: true)
            } catch {
                await MainActor.run {
                    detailError = "Please sign in again to continue."
                }
            }
            return
        }

        await MainActor.run {
            detailAction = .idle
            switch result {
            case .success:
                vm.removeIncoming(withId: item.id)
                Metrics.reservationAction(
                    screen: "Notifications",
                    role: "owner",
                    postId: item.postId,
                    reservationId: item.reservationId,
                    mode: item.mode,
                    statusBefore: "pending",
                    statusAfter: "canceled"
                )
                showToast("Reservation canceled")
                NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                selectedIncoming = nil
            case .alreadyProcessed:
                vm.removeIncoming(withId: item.id)
                Metrics.reservationAction(
                    screen: "Notifications",
                    role: "owner",
                    postId: item.postId,
                    reservationId: item.reservationId,
                    mode: item.mode,
                    statusBefore: "pending",
                    statusAfter: "already_processed"
                )
                showToast("Already processed.")
                NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                selectedIncoming = nil
            case .notFound:
                vm.removeIncoming(withId: item.id)
                Metrics.reservationAction(
                    screen: "Notifications",
                    role: "owner",
                    postId: item.postId,
                    reservationId: item.reservationId,
                    mode: item.mode,
                    statusBefore: "pending",
                    statusAfter: "already_canceled"
                )
                showToast("Already canceled.")
                selectedIncoming = nil
            case .unauthorized:
                showToast("Please sign in again to continue.")
            case .network:
                showToast("Can't reach the server right now. Please try again.")
            case .failure(let msg):
                detailError = msg
            case .phoneRequired:
                break
            }
        }
    }

    private func savePhoneNumber() async {
        let trimmed = detailPhoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run { detailError = "Phone number can't be empty." }
            return
        }

        await MainActor.run {
            isSavingPhone = true
            detailError = nil
        }

        do {
            try await svc.updateProfile(firstName: nil, lastName: nil, phone: trimmed)
            await MainActor.run {
                isSavingPhone = false
                detailPhoneInput = trimmed
                showToast("Phone number saved.")
            }
        } catch {
            let message = normalizedErrorMessage(error, fallback: "Couldn't update profile.")
            await MainActor.run {
                isSavingPhone = false
                detailError = message
            }
        }
    }

    private func currentProfilePhone() -> String {
        let metadataPhone = svc.session?.user.userMetadata["phone"] as? String ?? ""
        return metadataPhone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedErrorMessage(_ error: Error, fallback: String) -> String {
        if let http = error as? ApiHTTPError {
            return friendlyMessage(statusCode: http.statusCode, backendMessage: http.message, fallback: fallback)
        }

        if let apiError = error as? ApiServiceError {
            switch apiError {
            case .unauthorized:
                return "Please sign in again to continue."
            case .notFound:
                return "Item not found."
            case .serverError(let msg):
                return friendlyMessage(statusCode: nil, backendMessage: msg, fallback: fallback)
            case .networkError:
                return "Can't reach the server right now. Please try again."
            default:
                return fallback
            }
        }

        DLog("[NOTIFS] resolveError fallback: \(error.localizedDescription)")
        return fallback
    }

    private func friendlyMessage(statusCode: Int?, backendMessage: String?, fallback: String) -> String {
        if let backendMessage, !backendMessage.isEmpty {
            let lower = backendMessage.lowercased()
            if lower.contains("phone_required_for_home_mode") {
                return "Add a phone number to approve home pickups."
            }
            DLog("[NOTIFS] backend message surfaced: \(backendMessage)")
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
}

// MARK: - Badge Notification Name

extension Notification.Name {
    static let notificationsBadgeDecrement = Notification.Name("notificationsBadgeDecrement")
}

struct NotificationSections {
    var incoming: [NotificationItem]
    var general: [NotificationItem]
}

struct NotificationItem: Identifiable, Equatable {
    let id: String
    let reservationId: String
    let postId: String
    let category: NotificationCategory
    let mode: ItemMode
    let title: String
    let message: String?
    let imageURL: URL?
    let avatarURL: URL?
    let reserverName: String?
    let createdAt: Date?
    let contactPhone: String?

    static func == (lhs: NotificationItem, rhs: NotificationItem) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - ViewModel

// MARK: - Date Provider

protocol DateProvider { func now() -> Date }
struct DefaultDateProvider: DateProvider { func now() -> Date { Date() } }

// MARK: - ViewModel

@MainActor
final class NotificationsViewModel: ObservableObject {
    enum State {
        case loading
        case error(String)
        case content(NotificationSections)
    }

    @Published var state: State = .loading

    private var api: ApiService?
    private let dateProvider: DateProvider
    var currentUserId: UUID?

    init(dateProvider: DateProvider) {
        self.dateProvider = dateProvider
    }

    func attach(api: ApiService, userId: UUID?) {
        self.api = api
        self.currentUserId = userId
    }

    func fetch() async {
        guard let api else { return }
        #if DEBUG
        DLog("[NOTIFS] fetch start")
        #endif
        state = .loading
        do {
            let items = try await fetchNotifications(api: api)
            #if DEBUG
            DLog("[NOTIFS] fetch end incoming=\(items.incoming.count) general=\(items.general.count)")
            #endif
            self.state = .content(items)
        } catch {
            #if DEBUG
            DLog("[NOTIFS] fetch error=\(error.localizedDescription)")
            #endif
            let message = resolveError(error, fallback: "Couldn't load requests.")
            self.state = .error(message)
        }
    }

    enum ActionResult {
        case success
        case alreadyProcessed
        case unauthorized
        case network
        case phoneRequired(String)
        case notFound
        case failure(String)
    }

    func approve(reservationId: String, shareContact: Bool) async -> ActionResult {
        #if DEBUG
        DLog("[NOTIFS] approve start id=\(reservationId) share_contact=\(shareContact)")
        #endif
        guard let api else { return .failure("No API") }

        struct ApproveBody: Encodable { let share_contact: Bool }
        do {
            let body = try JSONEncoder().encode(ApproveBody(share_contact: shareContact))
            let result = try await api.rawRequest(
                "/reservations/\(reservationId)/approve",
                method: .POST,
                body: body
            )

            #if DEBUG
            DLog("[NOTIFS] approve endpoint=/reservations/\(reservationId)/approve status=\(result.statusCode) message=\(result.message ?? "<none>")")
            #endif

            switch result.statusCode {
            case 200...299:
                return .success
            case 401:
                return .unauthorized
            case 404:
                return .notFound
            case 409:
                return .alreadyProcessed
            case 422:
                let message = result.message ?? "Add a phone number to approve home pickups."
                return .phoneRequired(message)
            case 403:
                return .failure("You're not allowed to perform this action.")
            default:
                let message = mapFriendlyMessage(statusCode: result.statusCode, backendMessage: result.message, fallback: "Couldn't approve the request.")
                return .failure(message)
            }
        } catch let e as ApiServiceError {
            #if DEBUG
            DLog("[NOTIFS] approve error id=\(reservationId) err=\(e.localizedDescription)")
            #endif
            switch e {
            case .unauthorized:
                return .unauthorized
            case .serverError(let msg):
                let lower = msg.lowercased()
                if lower.contains("already processed") || lower.contains("not pending") {
                    return .alreadyProcessed
                }
                if lower.contains("not found") {
                    return .notFound
                }
                if lower.contains("phone_required_for_home_mode") {
                    return .failure("Add a phone number in your profile to approve home pickups.")
                }
                let message = mapFriendlyMessage(statusCode: nil, backendMessage: msg, fallback: "Couldn't approve the request.")
                return .failure(message)
            case .networkError:
                return .network
            default:
                DLog("[NOTIFS] approve ApiServiceError default: \(e.localizedDescription)")
                return .failure("Couldn't approve the request.")
            }
        } catch let httpError as ApiHTTPError {
            #if DEBUG
            DLog("[NOTIFS] approve http-error endpoint=/reservations/\(reservationId)/approve status=\(httpError.statusCode) message=\(httpError.message ?? "<none>")")
            #endif
            switch httpError.statusCode {
            case 403:
                return .failure("You're not allowed to perform this action.")
            case 404:
                return .notFound
            case 422:
                let message = httpError.message ?? "Add a phone number to approve home pickups."
                return .phoneRequired(message)
            default:
                return .failure(httpError.message ?? "Couldn't approve the request.")
            }
        } catch {
            #if DEBUG
            DLog("[NOTIFS] approve error id=\(reservationId) err=\(error.localizedDescription)")
            #endif
            DLog("[NOTIFS] approve unexpected error: \(error.localizedDescription)")
            return .failure("Couldn't approve the request.")
        }
    }

    func skip(reservationId: String) async -> ActionResult {
        #if DEBUG
        DLog("[NOTIFS] skip start id=\(reservationId)")
        #endif
        guard let api else { return .failure("No API") }
        do {
            let result = try await api.rawRequest(
                "/reservations/\(reservationId)/cancel",
                method: .POST
            )
            #if DEBUG
            DLog("[NOTIFS] reject endpoint=/reservations/\(reservationId)/cancel status=\(result.statusCode) message=\(result.message ?? "<none>")")
            #endif

            switch result.statusCode {
            case 200...299:
                return .success
            case 401:
                return .unauthorized
            case 404:
                return .notFound
            case 409:
                return .alreadyProcessed
            case 403:
                return .failure("You're not allowed to perform this action.")
            default:
                let message = mapFriendlyMessage(statusCode: result.statusCode, backendMessage: result.message, fallback: "Couldn't cancel the request.")
                return .failure(message)
            }
        } catch let e as ApiServiceError {
            #if DEBUG
            DLog("[NOTIFS] skip error id=\(reservationId) err=\(e.localizedDescription)")
            #endif
            switch e {
            case .unauthorized:
                return .unauthorized
            case .serverError(let msg):
                let lower = msg.lowercased()
                if lower.contains("already processed") || lower.contains("not pending") {
                    return .alreadyProcessed
                }
                if lower.contains("not found") {
                    return .notFound
                }
                let message = mapFriendlyMessage(statusCode: nil, backendMessage: msg, fallback: "Couldn't cancel the request.")
                return .failure(message)
            case .networkError: return .network
            default:
                DLog("[NOTIFS] skip ApiServiceError default: \(e.localizedDescription)")
                return .failure("Couldn't cancel the request.")
            }
        } catch let httpError as ApiHTTPError {
            #if DEBUG
            DLog("[NOTIFS] skip http-error endpoint=/reservations/\(reservationId)/cancel status=\(httpError.statusCode) message=\(httpError.message ?? "<none>")")
            #endif
            switch httpError.statusCode {
            case 403:
                return .failure("You're not allowed to perform this action.")
            case 404:
                return .notFound
            default:
                return .failure(httpError.message ?? "Couldn't cancel the request.")
            }
        } catch {
            #if DEBUG
            DLog("[NOTIFS] skip error id=\(reservationId) err=\(error.localizedDescription)")
            #endif
            DLog("[NOTIFS] skip unexpected error: \(error.localizedDescription)")
            return .failure("Couldn't cancel the request.")
        }
    }

    func removeIncoming(withId id: String) {
        guard case .content(var sections) = state else { return }
        sections.incoming.removeAll { $0.id == id }
        state = .content(sections)
    }

    // MARK: - Private
    private func fetchNotifications(api: ApiService) async throws -> NotificationSections {
        struct NotificationsEnvelope: Decodable {
            struct ServerNotification: Decodable {
                struct RemotePost: Decodable {
                    let id: String?
                    let post_id: String?
                    let title: String?
                    let mode: String?
                }
                struct RemoteCounterparty: Decodable {
                    let user_id: String?
                    let first_name: String?
                    let last_name: String?
                    let avatar_url: String?
                }

                let id: String?
                let type: String?
                let created_at: String?
                let post: RemotePost?
                let counterparty: RemoteCounterparty?
                let reservation_id: String?
                let contact_phone: String?
                let message: String?
            }

            let notifications: [ServerNotification]?
        }

        let raw = try await api.rawRequest("/my/notifications", method: .GET)
        guard (200...299).contains(raw.statusCode) else {
            let message = raw.message ?? "Couldn't load notifications."
            throw ApiServiceError.serverError(message)
        }

        let decoded = try JSONDecoder().decode(NotificationsEnvelope.self, from: raw.data)
        let currentId = currentUserId?.uuidString.lowercased()

        func normalizedName(first: String?, last: String?) -> String? {
            let f = (first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let l = (last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = [f, l].filter { !$0.isEmpty }.joined(separator: " ")
            if !combined.isEmpty { return combined }
            if !f.isEmpty { return f }
            if !l.isEmpty { return l }
            return nil
        }

        let incoming: [NotificationItem] = (decoded.notifications ?? []).compactMap { note in
            guard let type = note.type?.lowercased(), type == "new_request" else { return nil }
            let mode = ItemMode(rawValue: (note.post?.mode ?? "").lowercased()) ?? .street
            guard mode == .home else { return nil }

            if let currentId,
               let requesterId = note.counterparty?.user_id?.lowercased(),
               requesterId == currentId {
                return nil
            }

            let reservationId = note.reservation_id ?? note.id ?? UUID().uuidString
            let postId = note.post?.id ?? note.post?.post_id ?? reservationId
            let title = (note.post?.title?.isEmpty ?? true) ? "Untitled item" : (note.post?.title ?? "Untitled item")
            let avatarURL = note.counterparty?.avatar_url.flatMap(URL.init(string:))
            let createdAt = Time.parseISO(note.created_at)

            return NotificationItem(
                id: reservationId,
                reservationId: reservationId,
                postId: postId,
                category: .incomingRequest,
                mode: mode,
                title: title,
                message: note.message,
                imageURL: nil,
                avatarURL: avatarURL,
                reserverName: normalizedName(first: note.counterparty?.first_name, last: note.counterparty?.last_name),
                createdAt: createdAt,
                contactPhone: nil
            )
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        let general: [NotificationItem] = (decoded.notifications ?? []).compactMap { note in
            guard let type = note.type?.lowercased(), type != "new_request" else { return nil }

            if let currentId,
               let counterpartyId = note.counterparty?.user_id?.lowercased(),
               counterpartyId == currentId {
                return nil
            }

            let reservationId = note.reservation_id ?? note.id ?? UUID().uuidString
            let postId = note.post?.id ?? note.post?.post_id ?? reservationId
            let title = (note.post?.title?.isEmpty ?? true) ? "Untitled item" : (note.post?.title ?? "Untitled item")
            let avatarURL = note.counterparty?.avatar_url.flatMap(URL.init(string:))
            let createdAt = Time.parseISO(note.created_at)
            let mode = ItemMode(rawValue: (note.post?.mode ?? "").lowercased()) ?? .street

            let category: NotificationCategory
            let message: String?
            switch type {
            case "request_approved":
                category = .general(.requestApproved)
                message = "Approved! Use the phone number to coordinate pickup."
            case "request_rejected":
                category = .general(.requestRejected)
                message = "Request declined."
            case "request_withdrawn":
                category = .general(.requestWithdrawn)
                message = "Reservation withdrawn."
            case "pickup_completed":
                category = .general(.pickupCompleted)
                message = "Pickup completed."
            case "request_expired":
                category = .general(.requestExpired)
                message = "Reservation expired."
            default:
                return nil
            }

            return NotificationItem(
                id: reservationId,
                reservationId: reservationId,
                postId: postId,
                category: category,
                mode: mode,
                title: title,
                message: message,
                imageURL: nil,
                avatarURL: avatarURL,
                reserverName: normalizedName(first: note.counterparty?.first_name, last: note.counterparty?.last_name),
                createdAt: createdAt,
                contactPhone: note.contact_phone
            )
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        return NotificationSections(incoming: incoming, general: general)
    }

    private func resolveError(_ error: Error, fallback: String) -> String {
        if let http = error as? ApiHTTPError {
            return mapFriendlyMessage(statusCode: http.statusCode, backendMessage: http.message, fallback: fallback)
        }

        if let apiError = error as? ApiServiceError {
            switch apiError {
            case .unauthorized:
                return "Please sign in again to continue."
            case .notFound:
                return "Item not found."
            case .serverError(let message):
                return mapFriendlyMessage(statusCode: nil, backendMessage: message, fallback: fallback)
            case .networkError:
                return "Can't reach the server right now. Please try again."
            default:
                break
            }
        }

        DLog("[NOTIFS] resolveError fallback: \(error.localizedDescription)")
        return fallback
    }

    private func mapFriendlyMessage(statusCode: Int?, backendMessage: String?, fallback: String) -> String {
        if let backendMessage, !backendMessage.isEmpty {
            let lower = backendMessage.lowercased()
            if lower.contains("phone_required_for_home_mode") {
                return "Add a phone number to approve home pickups."
            }
            DLog("[NOTIFS] backend message surfaced: \(backendMessage)")
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
}

// MARK: - NotificationsView

struct NotificationsView: View {
    @EnvironmentObject var svc: SupabaseService
    @StateObject private var vm = NotificationsViewModel(dateProvider: DefaultDateProvider())
    @State private var api: ApiService?
    @State private var toastMessage: String? = nil
    @State private var selectedIncoming: NotificationItem?
    @State private var detailPhoneInput: String = ""
    @State private var detailError: String?
    @State private var detailAction: DetailAction = .idle
    @State private var isSavingPhone = false
    
    private enum DetailAction {
        case idle
        case approving
        case canceling
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                loadingView
            case .error(let message):
                errorView(message: message)
            case .content(let sections):
                contentView(for: sections)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if api == nil { api = ApiService(supabaseService: svc) }
            if let api {
                vm.attach(api: api, userId: svc.userId)
            }
            await vm.fetch()
            if svc.hasAuthToken {
                await svc.fetchMyStuff()
            }
        }
        .refreshable {
            await vm.fetch()
            if svc.hasAuthToken {
                await svc.fetchMyStuff()
            }
        }
        .onAppear {
#if DEBUG
            DLog("[NAV] Profile → Notifications")
#endif
        }
        .onChange(of: svc.userId) { _, newValue in
            vm.currentUserId = newValue
        }
        .onChange(of: selectedIncoming) { _, newValue in
            if newValue != nil {
                detailPhoneInput = currentProfilePhone()
                detailError = nil
                detailAction = .idle
                isSavingPhone = false
            }
        }
        .sheet(item: $selectedIncoming) { item in
            incomingDetailSheet(item: item)
        }
        .overlay(alignment: .top) {
            if let message = toastMessage {
                toastView(message)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppColor.brandGreen)
            Text("Loading…")
                .font(AppFont.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load requests",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            Button("Retry") {
                Task { await vm.fetch() }
            }
            .buttonStyle(.bordered)
            .tint(AppColor.brandGreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func contentView(for sections: NotificationSections) -> some View {
        if sections.incoming.isEmpty && sections.general.isEmpty {
            List {
                ContentUnavailableView(
                    "No notifications yet",
                    systemImage: "bell.badge",
                    description: Text("Reservation updates will appear here.")
                )
            }
            .listStyle(.insetGrouped)
        } else {
            List {
                if !sections.incoming.isEmpty {
                    Section("Incoming requests") {
                        ForEach(sections.incoming) { item in
                            Button {
                                selectedIncoming = item
                            } label: {
                                IncomingRequestRow(
                                    item: item,
                                    relativeTime: relativeDescription(for: item.createdAt)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !sections.general.isEmpty {
                    Section("Activity") {
                        ForEach(sections.general) { item in
                            GeneralNotificationRow(
                                item: item,
                                message: generalMessage(for: item),
                                relativeTime: relativeDescription(for: item.createdAt),
                                iconName: iconName(for: item.category)
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func incomingDetailSheet(item: NotificationItem) -> some View {
        NavigationStack {
            IncomingRequestDetailContent(
                item: item,
                phoneInput: $detailPhoneInput,
                detailError: $detailError,
                actionState: detailAction,
                isSavingPhone: isSavingPhone,
                relativeTime: relativeDescription(for: item.createdAt),
                onApprove: { Task { await approveSelectedIncoming() } },
                onCancel: { Task { await cancelSelectedIncoming() } },
                onSavePhone: { Task { await savePhoneNumber() } }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { selectedIncoming = nil }
                }
            }
        }
    }

    private func generalMessage(for item: NotificationItem) -> String {
        if let message = item.message, !message.isEmpty {
            return message
        }
        switch item.category {
        case .general(.requestApproved):
            return "Approved! Use the phone number to coordinate pickup."
        case .general(.requestRejected):
            return "Request declined."
        case .general(.requestWithdrawn):
            return "Reservation withdrawn."
        case .general(.pickupCompleted):
            return "Pickup completed."
        case .general(.requestExpired):
            return "Reservation expired."
        case .incomingRequest:
            return ""
        }
    }

    private func iconName(for category: NotificationCategory) -> String {
        switch category {
        case .general(.requestApproved):
            return "checkmark.circle.fill"
        case .general(.requestRejected):
            return "xmark.circle.fill"
        case .general(.requestWithdrawn):
            return "arrow.uturn.left.circle.fill"
        case .general(.pickupCompleted):
            return "cube.box.fill"
        case .general(.requestExpired):
            return "hourglass.circle.fill"
        case .incomingRequest:
            return "envelope.fill"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func relativeDescription(for date: Date?) -> String? {
        guard let date else { return nil }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private struct IncomingRequestRow: View {
        let item: NotificationItem
        let relativeTime: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.title)
                        .font(AppFont.h3)
                        .foregroundColor(AppColor.text)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("HOME")
                            .font(AppFont.sub)
                            .textCase(.uppercase)
                    }
                    .foregroundColor(AppColor.brandGreen)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppColor.brandGreen.opacity(0.15))
                    .clipShape(Capsule())
                }

                Text(item.reserverName ?? "Someone requested a pickup")
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)

                if let relativeTime {
                    Text(relativeTime)
                        .font(AppFont.sub)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Tap to review")
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColor.muted)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
        }
    }

    private struct GeneralNotificationRow: View {
        let item: NotificationItem
        let message: String
        let relativeTime: String?
        let iconName: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 20))
                    .foregroundColor(AppColor.brandGreen)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(AppFont.h3)
                        .foregroundColor(AppColor.text)

                    if !message.isEmpty {
                        Text(message)
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)
                    }

                    if case .general(.requestApproved) = item.category,
                       let phone = item.contactPhone,
                       !phone.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(phone)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                        .padding(8)
                        .background(AppColor.brandGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundColor(AppColor.brandGreen)
                    }

                    if let relativeTime {
                        Text(relativeTime)
                            .font(AppFont.sub)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }

    private struct IncomingRequestDetailContent: View {
        let item: NotificationItem
        @Binding var phoneInput: String
        @Binding var detailError: String?
        let actionState: DetailAction
        let isSavingPhone: Bool
        let relativeTime: String?
        let onApprove: () -> Void
        let onCancel: () -> Void
        let onSavePhone: () -> Void

        private var trimmedPhone: String {
            phoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var canApprove: Bool {
            !trimmedPhone.isEmpty && actionState == .idle && !isSavingPhone
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(AppFont.h2)
                            .foregroundColor(AppColor.text)

                        Text(item.reserverName ?? "Pickup request")
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)

                        if let relativeTime {
                            Text(relativeTime)
                                .font(AppFont.sub)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Share your phone number")
                            .font(AppFont.h3)
                            .foregroundColor(AppColor.text)

                        Text("We'll share this number with the requester so they can coordinate pickup.")
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)

                        TextField("Phone number", text: $phoneInput)
                            .keyboardType(.phonePad)
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        if trimmedPhone.isEmpty {
                            Text("Add a phone number before approving so the requester can contact you.")
                                .font(AppFont.sub)
                                .foregroundColor(.secondary)
                        }

                        Button {
                            onSavePhone()
                        } label: {
                            if isSavingPhone {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Save phone number")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(AppColor.brandGreen)
                        .disabled(isSavingPhone || trimmedPhone.isEmpty)
                    }

                    if let detailError, !detailError.isEmpty {
                        Text(detailError)
                            .font(AppFont.sub)
                            .foregroundColor(AppTheme.ColorToken.danger)
                    }

                    VStack(spacing: 12) {
                        Button {
                            onApprove()
                        } label: {
                            if actionState == .approving {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Approve & Share Phone")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.brandGreen)
                        .disabled(!canApprove)

                        Button(role: .destructive) {
                            onCancel()
                        } label: {
                            if actionState == .canceling {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Cancel reservation")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(actionState == .approving || isSavingPhone)
                    }
                }
                .padding()
            }
            .navigationTitle("Incoming request")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
        }
    }
}
