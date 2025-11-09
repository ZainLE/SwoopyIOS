import Foundation

public protocol OnboardingStorage {
    func hasCompletedIntro(userId: String) async -> Bool
    func setComplete(_ isComplete: Bool, for userId: String) async
    func reset(for userId: String) async
}

public actor UserDefaultsOnboardingStorage: OnboardingStorage {
    private let defaults: UserDefaults
    private let keyPrefix = "onboarding_completed_v2"

    public init(appGroup: String? = nil) {
        if let group = appGroup, let d = UserDefaults(suiteName: group) {
            self.defaults = d
        } else {
            self.defaults = .standard
        }
    }

    private func key(_ userId: String) -> String {
        "\(keyPrefix):\(userId)"
    }

    public func hasCompletedIntro(userId: String) async -> Bool {
        defaults.bool(forKey: key(userId))
    }

    public func setComplete(_ isComplete: Bool, for userId: String) async {
        defaults.set(isComplete, forKey: key(userId))
    }

    public func reset(for userId: String) async {
        defaults.removeObject(forKey: key(userId))
    }
}
