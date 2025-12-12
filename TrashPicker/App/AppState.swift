import Foundation
import Combine

enum AuthFlow {
    case normal
    case onboarding
    case resetPassword
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var authFlow: AuthFlow = .normal

    private init() {}
}
