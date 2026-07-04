import SwiftUI

struct ActionableNotificationRow: View {
    let notification: AppNotification
    let relativeTime: String
    let isPerformingAction: Bool
    let isContactEnabled: Bool
    let isContactLoading: Bool
    let contactPhone: String?
    let onApprove: () -> Void
    let onReject: () -> Void
    let onContact: () -> Void
    let onCancel: () -> Void
    
    private var isHomeAction: Bool {
        notification.category == .actionable && notification.type == .home_pickup_request
    }

    private var titleText: String {
        if notification.type == .street_reserved {
            return "Someone reserved your item"
        }
        return notification.itemTitle ?? "Home pickup request"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Item thumbnail
                itemThumbnail
                    .frame(width: 88, height: 88)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        requesterAvatar
                            .frame(width: 32, height: 32)
                        
                        Text(notification.counterpartyName ?? "Someone")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }

                    Text(conditionText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    // Time ago
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer(minLength: 0)
            }
            
            // Buttons based on state
            buttons
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
    
    @ViewBuilder
    private var itemThumbnail: some View {
        if let thumbURL = notification.itemThumbURL {
            ResilientAsyncImage(url: thumbURL) { phase in
                switch phase {
                case .empty:
                    // Loading state
                    RoundedRectangle(cornerRadius: AppRadius.thumb, style: .continuous)
                        .fill(Color.gray.opacity(0.1))
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.7)
                        )
                case .success(let image):
                    // Image loaded successfully
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipped()
                case .failure:
                    // Failed to load - show placeholder
                    RoundedRectangle(cornerRadius: AppRadius.thumb, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                                .font(.title3)
                        )
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumb, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: AppRadius.thumb, style: .continuous)
                .fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                        .font(.title3)
                )
        }
    }
    
    /// Rounded square in the same corner family as the item thumbnail,
    /// scaled down for the 32pt avatar.
    private let avatarCornerRadius: CGFloat = 8

    @ViewBuilder
    private var requesterAvatar: some View {
        if let url = notification.counterpartyAvatarURL {
            ResilientAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    avatarFallback
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: avatarCornerRadius, style: .continuous))
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        RoundedRectangle(cornerRadius: avatarCornerRadius, style: .continuous)
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            )
    }

    private var conditionText: String {
        notification.conditionDisplayName ?? "Post"
    }
    
    @ViewBuilder
    private var buttons: some View {
        if notification.state == .accepted, isHomeAction {
            HStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onContact()
                } label: {
                    if isContactLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Contact")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SwoopyPrimaryButtonStyle(minHeight: 48))
                .disabled(isPerformingAction || !isContactEnabled)
                .opacity((isPerformingAction || !isContactEnabled) ? 0.5 : 1.0)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SwoopyOutlineButtonStyle(minHeight: 48))
                .disabled(isPerformingAction)
                .opacity(isPerformingAction ? 0.5 : 1.0)
            }
            .frame(height: 48)
            
        } else if notification.state == .pending_approval {
            // Show Approve/Reject for pending notifications
            HStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onApprove()
                } label: {
                    Text("Approve")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle(
                    backgroundColor: AppTheme.ColorToken.primary,
                    foregroundColor: .white
                ))
                .disabled(isPerformingAction)
                .opacity(isPerformingAction ? 0.5 : 1.0)
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReject()
                } label: {
                    Text("Skip")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SwoopyOutlineButtonStyle(minHeight: 48))
                .disabled(isPerformingAction)
                .opacity(isPerformingAction ? 0.5 : 1.0)
            }
            .frame(height: 48)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Button Styles

private struct PrimaryActionButtonStyle: ButtonStyle {
    let backgroundColor: Color
    let foregroundColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    let borderColor: Color
    let foregroundColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(Color.clear)
            .foregroundColor(foregroundColor)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
