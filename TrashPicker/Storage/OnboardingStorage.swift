import Foundation

enum OnboardingStorage {
    private static let key = "onboarding_completed_v1"
    static var defaults: UserDefaults { UserDefaults.standard }

    static func isComplete() -> Bool {
        defaults.bool(forKey: key)
    }
    static func markComplete() {
        defaults.set(true, forKey: key)
    }
}
