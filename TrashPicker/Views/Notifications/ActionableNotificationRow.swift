import SwiftUI

struct ActionableNotificationRow: View {
    let notification: AppNotification
    let relativeTime: String
    let isPerformingAction: Bool
    let onApprove: () -> Void
    let onReject: () -> Void
    let onContact: () -> Void
    let onCancel: () -> Void
    
    private var hasContactPhone: Bool {
        guard let phone = notification.exposedContactPhone?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !phone.isEmpty
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
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    
                    // Time ago
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Mode pill
                modePill
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
        // FIXED: Better image loading with proper error handling
        if let thumbURL = notification.itemThumbURL {
            AsyncImage(url: thumbURL) { phase in
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
    
    @ViewBuilder
    private var requesterAvatar: some View {
        if let url = notification.counterpartyAvatarURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "person.fill").font(.system(size: 14)).foregroundColor(.gray))
            }
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .overlay(Image(systemName: "person.fill").font(.system(size: 14)).foregroundColor(.gray))
        }
    }
    
    @ViewBuilder
    private var modePill: some View {
        let isHome = (notification.mode ?? "home") == "home" || notification.type == .home_pickup_request
        let modeLabel = isHome ? "Home pickup" : "Street pickup"
        let modeIcon = isHome ? "house.fill" : "mappin.circle.fill"
        
        HStack(spacing: 4) {
            Image(systemName: modeIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(modeLabel)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.ColorToken.primary.opacity(0.12))
        .foregroundColor(AppTheme.ColorToken.primary)
        .clipShape(Capsule())
    }
    
    @ViewBuilder
    private var buttons: some View {
        // CRITICAL FIX: Check notification.state for already-approved notifications
        // Show Contact/Cancel if state is .accepted (even after app restart)
        if notification.state == .accepted {
            HStack(spacing: 12) {
                Button(action: onContact) {
                    HStack(spacing: 6) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Contact")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle(
                    backgroundColor: AppTheme.ColorToken.primary,
                    foregroundColor: .white
                ))
                .disabled(isPerformingAction || !hasContactPhone)
                .opacity((isPerformingAction || !hasContactPhone) ? 0.5 : 1.0)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle(
                    borderColor: .red,
                    foregroundColor: .red
                ))
                .disabled(isPerformingAction)
                .opacity(isPerformingAction ? 0.5 : 1.0)
            }
            .frame(height: 48)
            
            if hasContactPhone {
                Text("Use this number to arrange pickup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            
        } else if notification.state == .pending_approval {
            // Show Approve/Reject for pending notifications
            HStack(spacing: 12) {
                Button(action: onApprove) {
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
                
                Button(action: onReject) {
                    Text("Reject")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle(
                    borderColor: .red,
                    foregroundColor: .red
                ))
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
