import SwiftUI

struct ActionableNotificationRow: View {
    let notification: AppNotification
    let relativeTime: String
    let isPerformingAction: Bool
    let onAccept: () -> Void
    let onSkip: () -> Void
    let onConfirmPickup: () -> Void
    let onContact: () -> Void
    let onCancelAccepted: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            buttons
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = notification.counterpartyName, !name.isEmpty {
                Text(name)
                    .font(.headline)
            }
            if let title = notification.itemTitle, !title.isEmpty {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text(relativeTime)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var buttons: some View {
        switch notification.state {
        case .some(.pending_approval):
            HStack(spacing: 12) {
                Button("Share & Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.ColorToken.primary)
                    .disabled(isPerformingAction)
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .disabled(isPerformingAction)
            }
        case .some(.accepted):
            VStack(spacing: 8) {
                Button("Confirm Pickup", action: onConfirmPickup)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.ColorToken.primary)
                    .disabled(isPerformingAction)
                HStack(spacing: 12) {
                    Button("Contact", action: onContact)
                        .buttonStyle(.bordered)
                        .disabled(isPerformingAction)
                    Button("Cancel", role: .destructive, action: onCancelAccepted)
                        .buttonStyle(.bordered)
                        .disabled(isPerformingAction)
                }
            }
        default:
            EmptyView()
        }
    }
}
