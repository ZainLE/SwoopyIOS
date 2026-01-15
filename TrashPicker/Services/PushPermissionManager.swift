import Foundation
import OneSignalFramework
import UIKit
import UserNotifications

@MainActor
final class PushPermissionManager: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let userDefaults: UserDefaults
    private let permissionPromptKey = "OneSignal.didPromptForPush"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    func requestPermissionIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        guard userDefaults.bool(forKey: permissionPromptKey) == false else { return }
        userDefaults.set(true, forKey: permissionPromptKey)

        OneSignal.Notifications.requestPermission({ accepted in
            DLog("[PUSH] permission accepted=\(accepted)")
            if accepted {
                UIApplication.shared.registerForRemoteNotifications()
                Task { @MainActor in
                    PushRegistrationManager.shared.syncRegistration(trigger: "permissionAccepted")
                }
            }
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }, fallbackToSettings: false)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var shouldShowPromptBanner: Bool {
        authorizationStatus == .notDetermined
    }

    var shouldShowDisabledBanner: Bool {
        authorizationStatus == .denied
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}
