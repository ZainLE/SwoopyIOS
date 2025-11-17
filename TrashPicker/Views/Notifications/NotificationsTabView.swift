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
                    ActionableNotificationRow(
                        notification: notification,
                        relativeTime: relativeDateString(notification.createdAt),
                        isPerformingAction: isPerforming,
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
        guard let phone = notification.exposedContactPhone,
              let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })")
        else {
            viewModel.toastMessage = "Contact not available yet"
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
