import UIKit
import FirebaseAuth

/// Provides Firebase Phone Auth with a UIDelegate so reCAPTCHA is presented
/// inside the app (as a modal web view) instead of opening Safari.
final class FirebaseAuthUIDelegate: NSObject, AuthUIDelegate {
    static let shared = FirebaseAuthUIDelegate()

    func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let topVC = UIApplication.shared.topMostViewController else {
            completion?()
            return
        }
        topVC.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let topVC = UIApplication.shared.topMostViewController else {
            completion?()
            return
        }
        topVC.dismiss(animated: flag, completion: completion)
    }
}

private extension UIApplication {
    var topMostViewController: UIViewController? {
        guard
            let windowScene = connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        return topVC(from: root)
    }

    func topVC(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topVC(from: presented)
        }
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return topVC(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return topVC(from: selected)
        }
        return vc
    }
}
