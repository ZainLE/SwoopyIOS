import SwiftUI

// Feature flag: when true, use real incoming reservations endpoint
private let USE_INCOMING_RESERVATIONS = false

// MARK: - Notification Models (UI-only)

enum NotificationKind {
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
        guard USE_INCOMING_RESERVATIONS else {
            // Fallback: just log and convert locally
            #if DEBUG
            print("[NOTIFS] approve start id=\(item.id) share_contact=\(share)")
            print("[NOTIFS] approve success id=\(item.id)")
            #endif
            // Convert to active locally
            if case .content(var items) = vm.state, let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = NotificationItem(id: item.id, kind: .requestActive, title: item.title, imageURL: item.imageURL, avatarURL: item.avatarURL, reserverName: item.reserverName, requestedAt: item.requestedAt, postId: item.postId)
                vm.state = .content(items)
            }
            showToast(share ? "Approved • Contact shared" : "Approved")
            return
        }
        let res = await vm.approve(reservationId: item.id, shareContact: share)
        switch res {
        case .success:
            if case .content(var items) = vm.state, let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = NotificationItem(id: item.id, kind: .requestActive, title: item.title, imageURL: item.imageURL, avatarURL: item.avatarURL, reserverName: item.reserverName, requestedAt: item.requestedAt, postId: item.postId)
                vm.state = .content(items)
            }
            showToast(share ? "Approved • Contact shared" : "Approved")
            NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
        case .alreadyProcessed:
            if case .content(var items) = vm.state {
                items.removeAll { $0.id == item.id }
                vm.state = .content(items)
            }
            showToast("Already processed.")
            NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
        case .unauthorized:
            showToast("Session expired")
        case .network:
            showToast("Couldn't reach the server")
        case .failure(let msg):
            showToast(msg)
        }
    }
}

// MARK: - Badge Notification Name

extension Notification.Name {
    static let notificationsBadgeDecrement = Notification.Name("notificationsBadgeDecrement")
}

struct NotificationItem: Identifiable {
    let id: String                 // reservation id or synthetic for picked-up
    let kind: NotificationKind
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
    private let useIncomingEndpoint: Bool
    private let dateProvider: DateProvider

    init(useIncomingEndpoint: Bool, dateProvider: DateProvider) {
        self.useIncomingEndpoint = useIncomingEndpoint
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
            let (items, source) = try await fetchItems(api: api)
            #if DEBUG
            print("[NOTIFS] fetch end count=\(items.count) source=\(source)")
            #endif
            self.state = .content(items)
        } catch {
            #if DEBUG
            print("[NOTIFS] fetch error=\(error.localizedDescription)")
            #endif
            self.state = .error(error.localizedDescription)
        }
    }

    enum ActionResult { case success, alreadyProcessed, unauthorized, network, failure(String) }

    func approve(reservationId: String, shareContact: Bool) async -> ActionResult {
        #if DEBUG
        print("[NOTIFS] approve start id=\(reservationId) share_contact=\(shareContact)")
        #endif
        guard let api else { return .failure("No API") }

        // If not using incoming endpoint yet, just log
        guard useIncomingEndpoint else {
            #if DEBUG
            print("[NOTIFS] approve success id=\(reservationId)")
            #endif
            return .success
        }

        struct ApproveBody: Encodable { let share_contact: Bool }
        struct ApproveResp: Decodable { let message: String? }

        do {
            let body = try JSONEncoder().encode(ApproveBody(share_contact: shareContact))
            let _: ApproveResp = try await api.makeRequest(
                "/reservations/\(reservationId)/approve",
                method: .POST,
                body: body
            )
            #if DEBUG
            print("[NOTIFS] approve success id=\(reservationId)")
            #endif
            return .success
        } catch let e as ApiServiceError {
            #if DEBUG
            print("[NOTIFS] approve error id=\(reservationId) err=\(e.localizedDescription)")
            #endif
            switch e {
            case .unauthorized:
                return .unauthorized
            case .serverError(let msg):
                if msg.localizedCaseInsensitiveContains("already processed") {
                    return .alreadyProcessed
                }
                return .failure(msg)
            case .networkError:
                return .network
            default:
                return .failure(e.localizedDescription)
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
        // If not using incoming endpoint yet, just log
        guard useIncomingEndpoint else {
            #if DEBUG
            print("[NOTIFS] skip success id=\(reservationId)")
            #endif
            return .success
        }
        struct CancelResp: Decodable { let message: String? }
        do {
            let _: CancelResp = try await api.makeRequest(
                "/reservations/\(reservationId)/cancel",
                method: .POST
            )
            #if DEBUG
            print("[NOTIFS] skip success id=\(reservationId)")
            #endif
            return .success
        } catch let e as ApiServiceError {
            #if DEBUG
            print("[NOTIFS] skip error id=\(reservationId) err=\(e.localizedDescription)")
            #endif
            switch e {
            case .unauthorized: return .unauthorized
            case .serverError(let msg): return .failure(msg)
            case .networkError: return .network
            default: return .failure(e.localizedDescription)
            }
        } catch {
            #if DEBUG
            print("[NOTIFS] skip error id=\(reservationId) err=\(error.localizedDescription)")
            #endif
            return .failure(error.localizedDescription)
        }
    }

    func ackPickedUp(id: String) {
        if case .content(var items) = state {
            items.removeAll { $0.id == id }
            state = .content(items)
        }
    }

    // MARK: - Private

    private func fetchItems(api: ApiService) async throws -> ([NotificationItem], String) {
        if useIncomingEndpoint {
            let items = try await fetchIncoming(api: api)
            return (items, "incoming_endpoint")
        } else {
            let items = try await fetchFallback(api: api)
            return (items, "fallback")
        }
    }

    private func parseISO(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    private func fetchIncoming(api: ApiService) async throws -> [NotificationItem] {
        struct ServerImage: Decodable { let url: URL; let order_index: Int }
        struct ServerPost: Decodable { let id: String; let title: String; let images: [ServerImage]? }
        struct ServerReserver: Decodable { let id: String; let first_name: String?; let avatar_url: URL?; let phone: String? }
        struct ServerReservation: Decodable {
            let id: String
            let status: String
            let requested_at: String
            let reserver: ServerReserver?
            let post: ServerPost
        }
        struct IncomingResponse: Decodable { let reservations: [ServerReservation] }

        let pending: IncomingResponse = try await api.makeRequest("/my/incoming_reservations", queryParams: [URLQueryItem(name: "status", value: "pending")])
        let active: IncomingResponse = try await api.makeRequest("/my/incoming_reservations", queryParams: [URLQueryItem(name: "status", value: "active")])
        let all = pending.reservations + active.reservations
        return all.map { r in
            let requested = parseISO(r.requested_at)
            let kind: NotificationKind
            switch r.status {
            case "pending":
                kind = .requestPending
            case "active":
                kind = .requestActive
            case "picked":
                // No picked_up_at provided here yet; auto-dismiss after 12h from now
                kind = .pickedUp(expireAt: dateProvider.now().addingTimeInterval(12 * 3600))
            default:
                kind = .requestActive
            }
            return NotificationItem(
                id: r.id,
                kind: kind,
                title: r.post.title,
                imageURL: r.post.images?.sorted { $0.order_index < $1.order_index }.first?.url,
                avatarURL: r.reserver?.avatar_url,
                reserverName: r.reserver?.first_name,
                requestedAt: requested,
                postId: r.post.id
            )
        }
    }

    private func fetchFallback(api: ApiService) async throws -> [NotificationItem] {
        struct ServerImage: Decodable { let url: URL; let order_index: Int }
        struct ServerReserver: Decodable { let id: String; let first_name: String?; let phone: String? }
        struct ActiveReservation: Decodable { let id: String; let status: String; let reserver: ServerReserver? }
        struct ServerPost: Decodable {
            let id: String
            let title: String
            let images: [ServerImage]?
            let active_reservation: ActiveReservation?
            let picked_up_at: String?
        }
        struct PostsResponse: Decodable { let posts: [ServerPost] }

        let resp: PostsResponse = try await api.makeRequest("/my/posts")
        var items: [NotificationItem] = []

        for p in resp.posts {
            if let ar = p.active_reservation {
                let kind: NotificationKind = (ar.status == "pending") ? .requestPending : .requestActive
                items.append(
                    NotificationItem(
                        id: ar.id,
                        kind: kind,
                        title: p.title,
                        imageURL: p.images?.sorted { $0.order_index < $1.order_index }.first?.url,
                        avatarURL: nil,
                        reserverName: ar.reserver?.first_name,
                        requestedAt: nil,
                        postId: p.id
                    )
                )
            }
            if let picked = p.picked_up_at, let pickedAt = parseISO(picked) {
                let expire = pickedAt.addingTimeInterval(12 * 3600)
                items.append(
                    NotificationItem(
                        id: "picked_\(p.id)",
                        kind: .pickedUp(expireAt: expire),
                        title: p.title,
                        imageURL: p.images?.sorted { $0.order_index < $1.order_index }.first?.url,
                        avatarURL: nil,
                        reserverName: nil,
                        requestedAt: pickedAt,
                        postId: p.id
                    )
                )
            }
        }
        return items
    }
}

// MARK: - NotificationsView

struct NotificationsView: View {
    @EnvironmentObject var svc: SupabaseService
    @StateObject private var vm = NotificationsViewModel(useIncomingEndpoint: USE_INCOMING_RESERVATIONS, dateProvider: DefaultDateProvider())
    @State private var api: ApiService?
    @State private var approveTarget: NotificationItem? = nil
    @State private var showApproveAlert = false
    @State private var toastMessage: String? = nil
    
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
                            NotificationCard(
                                item: item,
                                onApprove: {
                                    // Only for pending + real endpoint
                                    if case .requestPending = item.kind, USE_INCOMING_RESERVATIONS {
                                        approveTarget = item
                                        showApproveAlert = true
                                    }
                                },
                                onSkip: {
                                    Task {
                                        let res = await vm.skip(reservationId: item.id)
                                        switch res {
                                        case .success, .alreadyProcessed:
                                            if case .content(var items) = vm.state {
                                                items.removeAll { $0.id == item.id }
                                                vm.state = .content(items)
                                            }
                                            showToast("Skipped")
                                            NotificationCenter.default.post(name: .notificationsBadgeDecrement, object: nil)
                                        case .unauthorized:
                                            showToast("Session expired")
                                        case .network:
                                            showToast("Couldn't reach the server")
                                        case .failure(let msg):
                                            showToast(msg)
                                        }
                                    }
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if case .pickedUp = item.kind {
                                    Button(role: .destructive) {
                                        vm.ackPickedUp(id: item.id)
                                    } label: { Label("Dismiss", systemImage: "trash") }
                                }
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
        }
        .refreshable {
            await vm.fetch()
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
            Text("You can share your phone to coordinate pickup.")
        }
        .overlay(alignment: .top) {
            if let msg = toastMessage { toastView(msg) }
        }
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
            Text("Waiting for approval")
                .font(AppFont.sub)
                .foregroundColor(Color(red: 0.77, green: 0.26, blue: 0.26)) // danger red per spec
        case .requestActive:
            Text("Reserved by \(item.reserverName ?? "someone")")
                .font(AppFont.sub)
                .foregroundColor(AppColor.muted)
        case .pickedUp:
            HStack(spacing: 6) {
                Text("Picked up")
                if let d = item.requestedAt {
                    Text(d, style: .relative)
                }
            }
            .font(AppFont.sub)
            .foregroundColor(AppColor.muted)
        }
    }
    
    private var isPending: Bool {
        if case .requestPending = item.kind { return true }
        return false
    }

    @ViewBuilder
    private var buttonsRow: some View {
        switch item.kind {
        case .requestPending:
            HStack(spacing: 12) {
                Button("Accept") { onApprove?() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.brandGreen)
                Button("Skip") { onSkip?() }
                    .buttonStyle(.bordered)
                    .tint(AppColor.brandGreen)
            }
        case .requestActive:
            HStack {
                Button("View") { onView?() }
                    .buttonStyle(.bordered)
                    .tint(AppColor.muted)
                Spacer()
            }
        case .pickedUp:
            HStack {
                Button("Hide") { onSkip?() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(AppColor.muted)
                Spacer()
            }
        }
    }
}
