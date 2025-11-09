import Foundation

@MainActor
final class NotificationsTabViewModel: ObservableObject {
    @Published private(set) var actionRequired: [AppNotification] = []
    @Published private(set) var information: [AppNotification] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var toastMessage: String?
    @Published private(set) var performingActionIDs: Set<String> = []
    
    private let service: NotificationService
    private var timerTask: Task<Void, Never>?
    private var isVisible = false
    private var activeViewSeconds: [String: Int] = [:]
    
    init(service: NotificationService) {
        self.service = service
    }
    
    func onAppear() async {
        guard !isVisible else { return }
        isVisible = true
        await markAllReadAndLoad()
        startActiveViewingTimer()
    }
    
    func onDisappear() {
        isVisible = false
        timerTask?.cancel()
        timerTask = nil
    }
    
    func refresh() async {
        await load()
    }
    
    func swipeToDismiss(_ notification: AppNotification) {
        guard notification.category == .informational else { return }
        information.removeAll { $0.id == notification.id }
        Task {
            do {
                try await service.deleteInformational(id: notification.id)
            } catch let error as NotificationServiceError {
                await MainActor.run { self.toastMessage = error.localizedDescription }
            } catch let apiError as ApiHTTPError where apiError.statusCode == 403 {
                await MainActor.run { self.toastMessage = "Only informational notifications can be deleted." }
            }
        }
    }

    func accept(_ notification: AppNotification) async {
        guard let reservationId = notification.reservationId else { return }
        setAction(notification.id, active: true)
        defer { setAction(notification.id, active: false) }
        do {
            try await service.approve(reservationId: reservationId)
            replaceActionable(notification.updating(state: .accepted))
            showToast("Request accepted")
        } catch {
            showToast("Couldn't accept request")
        }
    }
    
    func skip(_ notification: AppNotification) {
        actionRequired.removeAll { $0.id == notification.id }
        Task {
            try? await service.markRead(id: notification.id)
        }
    }
    
    func confirmPickup(_ notification: AppNotification) async {
        guard let reservationId = notification.reservationId else { return }
        setAction(notification.id, active: true)
        defer { setAction(notification.id, active: false) }
        do {
            try await service.complete(reservationId: reservationId)
            actionRequired.removeAll { $0.id == notification.id }
            showToast("Pickup confirmed")
        } catch {
            showToast("Couldn't confirm pickup")
        }
    }
    
    func cancelAccepted(_ notification: AppNotification) async {
        guard let reservationId = notification.reservationId else { return }
        setAction(notification.id, active: true)
        defer { setAction(notification.id, active: false) }
        do {
            try await service.cancel(reservationId: reservationId)
            actionRequired.removeAll { $0.id == notification.id }
            showToast("Reservation canceled")
        } catch {
            showToast("Couldn't cancel reservation")
        }
    }
    
    func markInformationRead(_ notification: AppNotification) {
        if let index = information.firstIndex(where: { $0.id == notification.id }) {
            information[index] = notification.markingRead()
        }
        Task {
            try? await service.markRead(id: notification.id)
        }
    }
    
    private func load() async {
        isLoading = true
        error = nil
        do {
            let notifications = try await service.fetchAll()
            apply(notifications)
        } catch {
            self.error = "Couldn't load notifications"
        }
        isLoading = false
    }
    
    private func markAllReadAndLoad() async {
        isLoading = true
        error = nil
        do {
            try await service.markAllRead()
            let notifications = try await service.fetchAll()
            apply(notifications)
        } catch {
            self.error = "Couldn't load notifications"
        }
        isLoading = false
    }
    
    private func apply(_ notifications: [AppNotification]) {
        let actionable = notifications.filter { $0.category == .actionable }
        let informational = notifications.filter { $0.category == .informational }
        
        actionRequired = actionable.sorted { (lhs: AppNotification, rhs: AppNotification) -> Bool in
            return lhs.createdAt < rhs.createdAt
        }
        
        information = informational.sorted(by: { (lhs: AppNotification, rhs: AppNotification) -> Bool in
            if lhs.isUnread != rhs.isUnread {
                return lhs.isUnread && !rhs.isUnread
            }
            return lhs.createdAt > rhs.createdAt
        })
        
        activeViewSeconds = [:]
    }
    
    private func replaceActionable(_ notification: AppNotification) {
        if let index = actionRequired.firstIndex(where: { $0.id == notification.id }) {
            actionRequired[index] = notification
        }
    }
    
    private func startActiveViewingTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.tickActiveViewing()
            }
        }
    }
    
    private func tickActiveViewing() async {
        guard isVisible else { return }
        var expiredIDs: [String] = []
        for notification in information {
            guard notification.persistenceType == .active_view else { continue }
            let seconds = (activeViewSeconds[notification.id] ?? 0) + 1
            activeViewSeconds[notification.id] = seconds
            let threshold = notification.persistenceSeconds ?? 300
            if seconds >= threshold {
                expiredIDs.append(notification.id)
            }
        }

        guard !expiredIDs.isEmpty else { return }
        information.removeAll { expiredIDs.contains($0.id) }
        for id in expiredIDs {
            Task {
                try? await service.deleteInformational(id: id)
            }
        }
    }
    
    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.toastMessage == message {
                self.toastMessage = nil
            }
        }
    }
    
    private func setAction(_ id: String, active: Bool) {
        if active {
            performingActionIDs.insert(id)
        } else {
            performingActionIDs.remove(id)
        }
    }
}

