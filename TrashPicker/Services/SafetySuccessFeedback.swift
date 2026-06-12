import SwiftUI

@MainActor
final class SafetySuccessFeedback: ObservableObject {
    static let shared = SafetySuccessFeedback()

    struct Message {
        let icon: String
        let iconColor: Color
        let title: String
        let body: String
    }

    @Published var pending: Message?

    private init() {}

    func show(icon: String, iconColor: Color, title: String, body: String) {
        pending = Message(icon: icon, iconColor: iconColor, title: title, body: body)
    }

    func clear() {
        pending = nil
    }
}
