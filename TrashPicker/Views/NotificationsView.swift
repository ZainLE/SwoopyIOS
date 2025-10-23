import SwiftUI

// MARK: - Notification Models (UI-only)

enum NotificationKind: Equatable {
    case requestPending
    case requestActive
    case pickedUp(expireAt: Date)
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

    private func handleApprove(item: NotificationItem, share: Bool) async {
        let res = await vm.approve(reservationId: item.id, shareContact: share)
        switch res {
        case .success:
            if case .content(var items) = vm.state, let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = NotificationItem(
                    id: item.id,
                    kind: .requestActive,
                    mode: item.mode,
                    title: item.title,
                    imageURL: item.imageURL,
                    avatarURL: item.avatarURL,
                    reserverName: item.reserverName,
                    requestedAt: item.requestedAt,
                    postId: item.postId
                )
                vm.state = .content(items)
            }
            showToast("Approved")
            NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
        case .alreadyProcessed:
            if case .content(var items) = vm.state {
                items.removeAll { $0.id == item.id }
                vm.state = .content(items)
            }
            showToast("Already processed.")
            NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
        case .notFound:
            if case .content(var items) = vm.state {
                items.removeAll { $0.id == item.id }
                vm.state = .content(items)
            }
            showToast("Item not found.")
        case .unauthorized:
            showToast("Please sign in again to continue.")
        case .network:
            showToast("Can't reach the server right now. Please try again.")
        case .phoneRequired(let message):
            await MainActor.run {
                let existing = svc.session?.user.userMetadata["phone"] as? String ?? ""
                phoneInput = existing
                phoneSheetError = nil
                phoneSheetModel = PhoneSheetModel(item: item, shareContact: share, message: message)
            }
        case .failure(let msg):
            showToast(msg)
        }
    }

    private func savePhoneAndRetry(_ sheet: PhoneSheetModel) async {
        let trimmed = phoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run {
                phoneSheetError = "Phone number can't be empty."
            }
            return
        }

        await MainActor.run {
            isSavingPhone = true
            phoneSheetError = nil
        }

        do {
            try await svc.updateProfile(firstName: nil, lastName: nil, phone: trimmed)
            await MainActor.run {
                isSavingPhone = false
                phoneSheetModel = nil
            }
            await handleApprove(item: sheet.item, share: sheet.shareContact)
        } catch {
            let message = normalizedErrorMessage(error, fallback: "Couldn't update profile.")
            await MainActor.run {
                isSavingPhone = false
                phoneSheetError = message
            }
        }
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

        return error.localizedDescription
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
}

// MARK: - Badge Notification Name

extension Notification.Name {
    static let notificationsBadgeDecrement = Notification.Name("notificationsBadgeDecrement")
}

struct NotificationItem: Identifiable {
    let id: String                 // reservation id
    let kind: NotificationKind
    let mode: ItemMode
    let title: String              // post title
    let imageURL: URL?
    let avatarURL: URL?
    let reserverName: String?
    let requestedAt: Date?
    let postId: String
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
        case content([NotificationItem])
    }

    @Published var state: State = .loading

    private var api: ApiService?
    private let dateProvider: DateProvider

    init(dateProvider: DateProvider) {
        self.dateProvider = dateProvider
    }

    func attach(api: ApiService) {
        self.api = api
    }

    func fetch() async {
        guard let api else { return }
        #if DEBUG
        print("[NOTIFS] fetch start")
        #endif
        state = .loading
        do {
            let items = try await fetchIncoming(api: api)
            #if DEBUG
            print("[NOTIFS] fetch end count=\(items.count)")
            #endif
            self.state = .content(items)
        } catch {
            #if DEBUG
            print("[NOTIFS] fetch error=\(error.localizedDescription)")
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
        print("[NOTIFS] approve start id=\(reservationId) share_contact=\(shareContact)")
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
            print("[NOTIFS] approve endpoint=/reservations/\(reservationId)/approve status=\(result.statusCode) message=\(result.message ?? "<none>")")
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
            print("[NOTIFS] approve error id=\(reservationId) err=\(e.localizedDescription)")
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
                let message = mapFriendlyMessage(statusCode: nil, backendMessage: msg, fallback: msg)
                return .failure(message)
            case .networkError:
                return .network
            default:
                return .failure(e.localizedDescription)
            }
        } catch let httpError as ApiHTTPError {
            #if DEBUG
            print("[NOTIFS] approve http-error endpoint=/reservations/\(reservationId)/approve status=\(httpError.statusCode) message=\(httpError.message ?? "<none>")")
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
            print("[NOTIFS] approve error id=\(reservationId) err=\(error.localizedDescription)")
            #endif
            return .failure(error.localizedDescription)
        }
    }

    func skip(reservationId: String) async -> ActionResult {
        #if DEBUG
        print("[NOTIFS] skip start id=\(reservationId)")
        #endif
        guard let api else { return .failure("No API") }
        do {
            let result = try await api.rawRequest(
                "/reservations/\(reservationId)/cancel",
                method: .POST
            )
            #if DEBUG
            print("[NOTIFS] reject endpoint=/reservations/\(reservationId)/cancel status=\(result.statusCode) message=\(result.message ?? "<none>")")
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
            print("[NOTIFS] skip error id=\(reservationId) err=\(e.localizedDescription)")
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
                let message = mapFriendlyMessage(statusCode: nil, backendMessage: msg, fallback: msg)
                return .failure(message)
            case .networkError: return .network
            default: return .failure(e.localizedDescription)
            }
        } catch let httpError as ApiHTTPError {
            #if DEBUG
            print("[NOTIFS] skip http-error endpoint=/reservations/\(reservationId)/cancel status=\(httpError.statusCode) message=\(httpError.message ?? "<none>")")
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
            print("[NOTIFS] skip error id=\(reservationId) err=\(error.localizedDescription)")
            #endif
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Private
    private func fetchIncoming(api: ApiService) async throws -> [NotificationItem] {
        async let pendingTask = api.getIncomingRequests(status: .pending)
        async let activeTask = api.getIncomingRequests(status: .active)

        let (pending, active) = try await (pendingTask, activeTask)
        let combined = pending + active

        // Deduplicate by reservation id, keeping the latest record
        var latestById: [String: IncomingRequest] = [:]
        for request in combined {
            latestById[request.reservationId] = request
        }

        let sortedRequests = latestById.values.sorted { lhs, rhs in
            let lhsDate = lhs.createdAtDate ?? Date.distantPast
            let rhsDate = rhs.createdAtDate ?? Date.distantPast
            return lhsDate > rhsDate
        }

        return sortedRequests.compactMap { request in
            let status = request.status?.lowercased() ?? ""

            if status == "canceled" { return nil }

            let kind: NotificationKind
            switch status {
            case "pending":
                kind = .requestPending
            case "active":
                kind = .requestActive
            case "picked", "picked_up", "completed":
                let expire = request.endAtDate ?? request.expiresAtDate ?? Date()
                kind = .pickedUp(expireAt: expire)
            default:
                kind = .requestPending
            }

            let mode = request.mode ?? .street

            return NotificationItem(
                id: request.reservationId,
                kind: kind,
                mode: mode,
                title: request.resolvedTitle ?? "Untitled item",
                imageURL: request.leadImageURL,
                avatarURL: request.requester?.photoURL,
                reserverName: request.requesterName,
                requestedAt: request.createdAtDate,
                postId: request.postId
            )
        }
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

        return error.localizedDescription
    }

    private func mapFriendlyMessage(statusCode: Int?, backendMessage: String?, fallback: String) -> String {
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
}

// MARK: - NotificationsView

struct NotificationsView: View {
    @EnvironmentObject var svc: SupabaseService
    @StateObject private var vm = NotificationsViewModel(dateProvider: DefaultDateProvider())
    @State private var api: ApiService?
    @State private var approveTarget: NotificationItem? = nil
    @State private var showApproveAlert = false
    @State private var toastMessage: String? = nil
    @State private var phoneSheetModel: PhoneSheetModel?
    @State private var phoneInput: String = ""
    @State private var phoneSheetError: String? = nil
    @State private var isSavingPhone = false

    private struct PhoneSheetModel: Identifiable {
        let id = UUID()
        let item: NotificationItem
        let shareContact: Bool
        let message: String
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().tint(AppColor.brandGreen)
                    Text("Loading…")
                        .font(AppFont.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                
            case .error(let message):
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
                
            case .content(let items):
                if items.isEmpty {
                    List {
                        ContentUnavailableView(
                            "No requests yet",
                            systemImage: "bell.badge",
                            description: Text("Pickup requests from other users will appear here")
                        )
                    }
                } else {
                    List {
                        ForEach(items) { item in
                            if item.mode == .home && item.kind == .requestPending {
                                NotificationCard(
                                    item: item,
                                    onApprove: {
                                        approveTarget = item
                                        showApproveAlert = true
                                    },
                                    onSkip: {
                                        Task {
                                            let res = await vm.skip(reservationId: item.id)
                                            await MainActor.run {
                                                switch res {
                                                case .success:
                                                    if case .content(var current) = vm.state {
                                                        current.removeAll { $0.id == item.id }
                                                        vm.state = .content(current)
                                                    }
                                                    showToast("Rejected")
                                                    NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                                                    
                                                case .alreadyProcessed:
                                                    if case .content(var current) = vm.state {
                                                        current.removeAll { $0.id == item.id }
                                                        vm.state = .content(current)
                                                    }
                                                    showToast("Already processed.")
                                                    NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                                                    
                                                case .notFound:
                                                    if case .content(var current) = vm.state {
                                                        current.removeAll { $0.id == item.id }
                                                        vm.state = .content(current)
                                                    }
                                                    showToast("Item not found.")

                                                case .unauthorized:
                                                    showToast("Please sign in again to continue.")
                                                    
                                                case .network:
                                                    showToast("Can't reach the server right now. Please try again.")
                                                    
                                                case .failure(let msg):
                                                    showToast(msg)

                                                case .phoneRequired:
                                                    showToast("Add a phone number to your profile.")
                                                }
                                            }
                                        }
                                    }
                                )
                            } else {
                                // Street or non-pending items: informational only (no actions)
                                NotificationCard(item: item)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if api == nil { api = ApiService(supabaseService: svc) }
            if let api { vm.attach(api: api) }
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
            print("[NAV] Profile → Notifications")
#endif
        }
        .alert("Share your phone number with the requester?", isPresented: $showApproveAlert, presenting: approveTarget) { item in
            Button("Share", role: .none) {
                Task { await handleApprove(item: item, share: true) }
            }
            Button("Don't share", role: .none) {
                Task { await handleApprove(item: item, share: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("We'll share your phone if available.")
        }
        .sheet(item: $phoneSheetModel) { sheet in
            NavigationStack {
                Form {
                    Section {
                        Text(sheet.message)
                            .font(AppFont.sub)
                            .foregroundColor(.secondary)
                    }

                    Section("Phone number") {
                        TextField("Phone number", text: $phoneInput)
                            .keyboardType(.phonePad)
                            .textInputAutocapitalization(.never)
                    }

                    if let phoneSheetError {
                        Section {
                            Text(phoneSheetError)
                                .foregroundColor(.red)
                                .font(AppFont.sub)
                        }
                    }
                }
                .navigationTitle("Add Phone")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { phoneSheetModel = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSavingPhone {
                            ProgressView()
                        } else {
                            Button("Save & Approve") {
                                Task { await savePhoneAndRetry(sheet) }
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let msg = toastMessage { toastView(msg) }
        }
    }
    // MARK: - NotificationCard
    
    private struct NotificationCard: View {
        let item: NotificationItem
        var onApprove: (() -> Void)? = nil
        var onSkip: (() -> Void)? = nil
        var onView: (() -> Void)? = nil
        
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    // Thumbnail 56x56, 12pt radius
                    AsyncImage(url: item.imageURL) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.15)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
                    
                    // Reserver avatar 40x40 circle
                    AsyncImage(url: item.avatarURL) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default:
                            ZStack {
                                Circle().fill(Color.gray.opacity(0.15))
                                Image(systemName: "person.fill").foregroundColor(AppColor.muted)
                            }
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AppColor.stroke, lineWidth: 1))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(AppFont.h3)
                            .foregroundColor(AppColor.text)
                        
                        subline
                    }
                    
                    Spacer(minLength: 0)
                }
                
                buttonsRow
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        }
        
        @ViewBuilder
        private var subline: some View {
            switch item.kind {
            case .requestPending:
                if item.mode == .street {
                    Text("Street pickup request pending")
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                } else {
                    Text("Waiting for approval")
                        .font(AppFont.sub)
                        .foregroundColor(Color(red: 0.77, green: 0.26, blue: 0.26))
                }
            case .requestActive:
                if item.mode == .street {
                    Text("Street pickup scheduled")
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                } else {
                    Text("Reserved by \(item.reserverName ?? "someone")")
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                }
            case .pickedUp:
                Text("Picked up")
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
            }
        }
        
        @ViewBuilder
        private var buttonsRow: some View {
            switch item.kind {
            case .requestPending:
                if item.mode == .home {
                    HStack(spacing: 12) {
                        if let onApprove {
                            Button("Accept") { onApprove() }
                                .buttonStyle(.borderedProminent)
                                .tint(AppColor.brandGreen)
                        }
                        if let onSkip {
                            Button("Reject") { onSkip() }
                                .buttonStyle(.bordered)
                                .tint(AppColor.brandGreen)
                        }
                    }
                } else {
                    HStack { Spacer() }
                }
            case .requestActive:
                if item.mode == .home {
                    HStack {
                        if let onView {
                            Button("View") { onView() }
                                .buttonStyle(.bordered)
                                .tint(AppColor.muted)
                        }
                        Spacer()
                    }
                } else {
                    HStack { Spacer() }
                }
            case .pickedUp:
                HStack { Spacer() }
            }
        }
    }

}
