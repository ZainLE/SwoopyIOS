import SwiftUI
import UIKit

struct NotificationsTabView: View {
    @EnvironmentObject private var reservationService: ReservationNotificationService
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    
    @StateObject private var viewModel: NotificationsTabViewModel
    @State private var pendingAccept: AppNotification?
    @State private var pendingCancel: AppNotification?
    
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
        .onDisappear {
            viewModel.onDisappear()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .confirmationDialog(
            "Share your phone number?",
            isPresented: Binding(
                get: { pendingAccept != nil },
                set: { value in if !value { pendingAccept = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Share & Accept", role: .none) {
                guard let notification = pendingAccept else { return }
                Task {
                    await viewModel.accept(notification)
                    pendingAccept = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingAccept = nil
            }
        } message: {
            Text("Your phone number will be shared with \(pendingAccept?.counterpartyName ?? "the requester").")
        }
        .confirmationDialog(
            "Cancel this pickup?",
            isPresented: Binding(
                get: { pendingCancel != nil },
                set: { value in if !value { pendingCancel = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel Pickup", role: .destructive) {
                guard let notification = pendingCancel else { return }
                Task {
                    await viewModel.cancelAccepted(notification)
                    pendingCancel = nil
                }
            }
            Button("Keep Reservation", role: .cancel) {
                pendingCancel = nil
            }
        } message: {
            Text("This will notify \(pendingCancel?.counterpartyName ?? "the requester").")
        }
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
                Label("No pending requests", systemImage: "checkmark.circle")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.actionRequired, id: \.id) { notification in
                    let isPerforming = viewModel.performingActionIDs.contains(notification.id)
                    ActionableNotificationRow(
                        notification: notification,
                        relativeTime: relativeDateString(notification.createdAt),
                        isPerformingAction: isPerforming,
                        onAccept: { pendingAccept = notification },
                        onSkip: { viewModel.skip(notification) },
                        onConfirmPickup: { Task { await viewModel.confirmPickup(notification) } },
                        onContact: { contact(notification) },
                        onCancelAccepted: { pendingCancel = notification }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openReservation(for: notification)
                    }
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
                    .onTapGesture {
                        openReservation(for: notification)
                    }
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
        guard let phone = notification.exposedContactPhone,
              let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })")
        else {
            viewModel.toastMessage = "Phone number unavailable"
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    
    private func openReservation(for notification: AppNotification) {
        guard let reservationId = notification.reservationId else { return }
        router.selectedTab = .reservations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openReservation, object: reservationId.uuidString)
        }
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
