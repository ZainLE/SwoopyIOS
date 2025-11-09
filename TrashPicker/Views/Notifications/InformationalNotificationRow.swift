import SwiftUI

struct InformationalNotificationRow: View {
    let notification: AppNotification
    let relativeTime: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = notification.counterpartyAvatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Circle().fill(Color.gray.opacity(0.3))
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                if let title = notification.itemTitle, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
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
        switch notification.type {
        case .street_pickup_confirmed:
            return "Street pickup confirmed."
        case .request_declined:
            return "\(notification.counterpartyName ?? "Someone") declined your request."
        case .request_cancelled_after_acceptance:
            return "\(notification.counterpartyName ?? "Someone") canceled after acceptance."
        case .home_pickup_request:
            return notification.counterpartyName ?? "Home request"
        default:
            return notification.counterpartyName ?? "Notification"
        }
    }
}
