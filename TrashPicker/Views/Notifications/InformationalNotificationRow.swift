import SwiftUI

struct InformationalNotificationRow: View {
    let notification: AppNotification
    let relativeTime: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumb, style: .continuous))

                if notification.counterpartyAvatarURL != nil || notification.counterpartyName != nil {
                    avatarBadge
                        .frame(width: 24, height: 24)
                        .background(Color(.systemBackground))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(.systemGray4), lineWidth: 1))
                        .offset(x: 6, y: 6)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(primaryText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                if let body = bodyText, !body.isEmpty {
                    Text(body)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Text(relativeTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
    
    private var primaryText: String {
        if let title = notification.payload?.title, !title.isEmpty {
            return title
        }
        switch notification.type {
        case .street_pickup_confirmed:
            return "The item you posted has been picked up"
        case .street_reserved:
            return "Someone reserved your item"
        case .request_declined:
            return "Your reservation was declined"
        case .request_cancelled_after_acceptance:
            return "The reservation was canceled"
        case .home_pickup_request:
            return notification.counterpartyName ?? "Home request"
        case .request_approved:
            return "Your reservation has been approved"
        case .pickup_completed:
            return "Reservation completed"
        default:
            return notification.itemTitle ?? "Update"
        }
    }
    
    private var bodyText: String? {
        if let body = notification.payload?.body, !body.isEmpty {
            return body
        }
        switch notification.type {
        case .street_pickup_confirmed:
            return "Thanks for sharing! Your street pickup is done."
        case .street_reserved:
            return "Arrange pickup with the taker."
        case .request_approved:
            return "Contact the giver to arrange pickup."
        case .request_declined:
            return "You can request another item."
        case .request_cancelled_after_acceptance:
            return "The giver canceled after accepting."
        case .pickup_completed:
            return "Reservation completed successfully."
        default:
            return notification.itemTitle
        }
    }
    
    @ViewBuilder
    private var thumbnail: some View {
        if let url = notification.itemThumbURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderThumb
                }
            }
        } else {
            placeholderThumb
        }
    }
    
    private var placeholderThumb: some View {
        RoundedRectangle(cornerRadius: AppRadius.thumb, style: .continuous)
            .fill(Color.gray.opacity(0.2))
            .overlay(Image(systemName: "photo").foregroundColor(.gray))
    }

    @ViewBuilder
    private var avatarBadge: some View {
        if let url = notification.counterpartyAvatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    avatarInitialsFallback
                }
            }
            .clipShape(Circle())
        } else {
            avatarInitialsFallback
        }
    }

    private var avatarInitialsFallback: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Group {
                    if let initial = notification.counterpartyName?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .first {
                        Text(String(initial).uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            )
    }
}
