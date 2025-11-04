import SwiftUI
import UIKit
import OneSignalFramework

@main
struct TrashPickerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Install runtime debug guards (e.g., ban system image picker usage in DEBUG)
        #if DEBUG
        _CameraGuard.install()
        UserDefaults.standard.register(
            defaults: [
                "debug.distanceHUD": false,
                "debug.devHUD": false
            ]
        )
        #endif
        AppBoot.markLaunch()
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
        
        // Enforce Light Mode globally across all windows
        AppearanceEnforcer.forceLight()
        
        // Pre-warm haptic engine to eliminate first-tap latency
        Haptics.prewarm()
    }

    @StateObject private var svc = SupabaseService.shared
    @StateObject private var api = ApiService(supabaseService: SupabaseService.shared)
    @StateObject private var ck  = CKTrashService()
    @StateObject private var draftStore = UploadDraftStore()
    @StateObject private var loc = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environmentObject(svc)
                .environmentObject(api)
                .environmentObject(ck)
                .environmentObject(draftStore)
                .environmentObject(loc)
                .onOpenURL { url in
                    Task {
                        // Handle OAuth callback (Google, magic links, etc.)
                        await svc.handleOAuthRedirect(url)
                    }
                }
                .tint(AppTheme.ColorToken.primary)
                .preferredColorScheme(.light) // SwiftUI-level Light Mode enforcement
        }
    }
}

private struct RootGateView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var api: ApiService
    @StateObject private var boot = BootCoordinator.shared
    @StateObject private var appFlow = AppFlowCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var hasLoggedInteractive = false
    @State private var hasBootSequenceStarted = false

    var body: some View {
        appShell
        .onAppear {
            startBootSequenceIfNeeded()
            markFirstInteractiveIfNeeded()
        }
        .onChange(of: svc.phase) { _, newPhase in
            if newPhase != .checking {
                markFirstInteractiveIfNeeded()
            }
            if newPhase == .signedIn {
                AppBoot.markShellToSignedIn()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                startBootSequenceIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appFlow.phase {
        case .launching:
            loadingSplash
        case .auth:
            AuthView()
        case .profileCapture:
            OnboardingFlow()
        case .introShowcase:
            OnboardingFlowView()
        case .loading:
            loadingSplash
        case .main:
            RootView()
        }
    }
    
    private func markFirstInteractiveIfNeeded() {
        guard hasLoggedInteractive == false else { return }
        hasLoggedInteractive = true
        AppBoot.markFirstInteractive()
    }
    
    private func startBootSequenceIfNeeded() {
        guard hasBootSequenceStarted == false else { return }
        hasBootSequenceStarted = true
        
        DLog("[BOOT] onAppear executing (first launch)")
        
        BootCoordinator.shared.markFirstFrame()
        BootCoordinator.shared.start(svc: svc, api: api)
        if svc.phase == .signedIn {
            AppBoot.markShellToSignedIn()
        }
    }
    
    private var loadingSplash: some View {
        SplashView(
            logo: "SwoopyLogo",
            images: [
                "mappin.and.ellipse",
                "shippingbox",
                "leaf.fill",
                "sparkles",
                "person.2.fill",
                "house.fill",
                "FirstItem",
                "SecondItem"
            ]
        )
        
        .accessibilityHidden(true)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
    
    private var appShell: some View {
        content
            .environmentObject(appFlow)
            .overlay(alignment: .top) {
                if let msg = boot.bannerMessage {
                    Text(msg)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
#if DEBUG
            .overlay(alignment: .bottomTrailing) {
                if UserDefaults.standard.bool(forKey: "debug.devHUD") {
                    DeveloperHUD()
                        .padding(16)
                }
            }
#endif
    }
}

private struct LoadingStageView: View {
    var message: String?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.1)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
#if DEBUG
        .onTapGesture(count: 3) {
            let key = "debug.devHUD"
            let current = UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(!current, forKey: key)
            DLog("[DEV HUD] toggle -> \(!current)")
        }
#endif
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let userDefaults = UserDefaults.standard
    private let permissionPromptKey = "OneSignal.didPromptForPush"
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        OneSignal.Debug.setLogLevel(.LL_VERBOSE)
        
        UNUserNotificationCenter.current().delegate = self
        
        let appId = Bundle.main.object(forInfoDictionaryKey: "OneSignalAppID") as? String ?? ""
        precondition(
            UUID(uuidString: appId) != nil && appId.uppercased() != "YOUR_APP_ID",
            "Invalid OneSignalAppID in Info.plist. Set your real OneSignal App ID (UUID)."
        )
        logBootstrapInfo(appId: appId)
        
        OneSignal.initialize(appId, withLaunchOptions: launchOptions)
        OneSignal.User.pushSubscription.addObserver(self)
        logPushSubscriptionState(context: "post-init")
        
        requestNotificationPermissionIfNeeded()
        
        return true
    }
    
    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            
            switch settings.authorizationStatus {
            case .notDetermined:
                if self.userDefaults.bool(forKey: self.permissionPromptKey) {
                    return
                }
                self.userDefaults.set(true, forKey: self.permissionPromptKey)
                DispatchQueue.main.async {
                    OneSignal.Notifications.requestPermission({ accepted in
                        DLog("[OneSignal] User accepted notifications: \(accepted)")
                        if accepted {
                            UIApplication.shared.registerForRemoteNotifications()
                        }
                    }, fallbackToSettings: false)
                }
            default:
                self.logPushSubscriptionState(context: "permission-status-\(settings.authorizationStatus.rawValue)")
            }
        }
    }
    
    private func logBootstrapInfo(appId: String) {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let appIdentifierPrefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
        let teamId = appIdentifierPrefix?.split(separator: ".").first.map(String.init) ?? "unknown"
        #if DEBUG
        let buildEnvironment = "Debug"
        #else
        let buildEnvironment = "Release"
        #endif
        
        DLog("""
[OneSignal] Initializing
  AppID: \(appId)
  BundleID: \(bundleId)
  TeamID: \(teamId)
  Environment: \(buildEnvironment)
""")
    }
    
    private func logPushSubscriptionState(context: String) {
        let subscription = OneSignal.User.pushSubscription
        let playerId = subscription.id ?? "nil"
        let token = subscription.token ?? "nil"
        let optedIn = subscription.optedIn
        DLog("[OneSignal] \(context) playerId=\(playerId) token=\(token) optedIn=\(optedIn)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}

extension AppDelegate: OSPushSubscriptionObserver {
    func onPushSubscriptionDidChange(state: OSPushSubscriptionChangedState) {
        logPushSubscriptionState(context: "subscription-change")
    }
}
