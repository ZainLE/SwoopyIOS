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
    @Environment(\.scenePhase) private var scenePhase
    
    private enum BootPhase {
        case splash
        case app
    }
    
    private static let introDuration: TimeInterval = 2.2
    private static let showIntroOnColdLaunch = true
    
    @State private var bootPhase: BootPhase
    @State private var hasLoggedInteractive = false
    @State private var hasBootSequenceStarted = false
    @State private var introTask: Task<Void, Never>?
    @State private var introStartedAt: Date?
    
    init() {
        _bootPhase = State(initialValue: Self.showIntroOnColdLaunch ? .splash : .app)
    }

    var body: some View {
        ZStack {
            if bootPhase == .app {
                appShell
                    .transition(.opacity)
                    .zIndex(0)
            }
            
            if bootPhase == .splash {
                splashShell
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: bootPhase)
        .onAppear {
            startBootSequenceIfNeeded()
            startIntroIfNeeded()
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
                startIntroIfNeeded()
            }
        }
        .onDisappear {
            introTask?.cancel()
            introTask = nil
        }
    }

    private var shouldShowAuth: Bool {
        svc.phase == .signedOut && svc.didCheckSession
    }

    @ViewBuilder
    private var content: some View {
        if shouldShowAuth {
            AuthView()
        } else {
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
        
        #if DEBUG
        print("[BOOT] onAppear executing (first launch)")
        #endif
        
        BootCoordinator.shared.markFirstFrame()
        BootCoordinator.shared.start(svc: svc, api: api)
        if svc.phase == .signedIn {
            AppBoot.markShellToSignedIn()
        }
    }
    
    private func startIntroIfNeeded() {
        guard Self.showIntroOnColdLaunch else {
            bootPhase = .app
            return
        }
        guard bootPhase == .splash else { return }
        guard introTask == nil else { return }
        
        let start = Date()
        introStartedAt = start
        print("[ANIM] intro_start")
        
        introTask = Task {
            let delay = UInt64(Self.introDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                completeIntroIfNeeded()
            }
        }
    }
    
    @MainActor
    private func completeIntroIfNeeded() {
        guard bootPhase == .splash else { return }
        introTask?.cancel()
        introTask = nil
        let elapsedMs = Int(Date().timeIntervalSince(introStartedAt ?? Date()) * 1000)
        print("[ANIM] intro_end t=\(elapsedMs)ms")
        Haptics.play(.tabReselect)
        withAnimation(.easeInOut(duration: 0.45)) {
            bootPhase = .app
        }
    }
    
    // TrashPickerApp.swift (snippet)
    private var splashShell: some View {
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
        
        .accessibilityHidden(true)          // ← enough to keep VO quiet
        .background(Color(.systemBackground).ignoresSafeArea())
    }
    
    private var appShell: some View {
        content
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
                        print("[OneSignal] User accepted notifications: \(accepted)")
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
        
        print("""
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
        print("[OneSignal] \(context) playerId=\(playerId) token=\(token) optedIn=\(optedIn)")
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

