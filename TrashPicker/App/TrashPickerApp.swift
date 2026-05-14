import SwiftUI
import UIKit
import OneSignalFramework
import SmartlookAnalytics
import FirebaseCore
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCrashlytics

@main
struct TrashPickerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        let sharedSupabase = SupabaseService.shared
        let sharedApi = ApiService(supabaseService: sharedSupabase)
        _svc = StateObject(wrappedValue: sharedSupabase)
        _api = StateObject(wrappedValue: sharedApi)
        _notificationService = StateObject(wrappedValue: ReservationNotificationService(api: sharedApi))
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
        // AUDIT: log bundle id
        AuditLog.flow("bundleId=\(Bundle.main.bundleIdentifier ?? "nil")")
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
        
        // Enforce Light Mode globally across all windows
        AppearanceEnforcer.forceLight()
        
        // Pre-warm haptic engine to eliminate first-tap latency
        Haptics.prewarm()
    }

    @StateObject private var svc: SupabaseService
    @StateObject private var api: ApiService
    @StateObject private var notificationService: ReservationNotificationService
    @StateObject private var ck  = CKTrashService()
    @StateObject private var draftStore = UploadDraftStore()
    @StateObject private var loc = LocationManager()
    @StateObject private var consent = ConsentManager.shared
    @StateObject private var appState = AppState.shared
    
    @State private var showConsentAlert = false

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environmentObject(svc)
                .environmentObject(api)
                .environmentObject(notificationService)
                .environmentObject(ck)
                .environmentObject(draftStore)
                .environmentObject(loc)
                .environmentObject(consent)
                .environmentObject(appState)
                .onOpenURL { url in
                    // 1) Firebase Phone Auth or other Firebase handlers
                    let handled = Auth.auth().canHandle(url)
                    DLog("[OPEN_URL] kind=firebaseauth scheme=\(url.scheme ?? "") host=\(url.host ?? "") handled=\(handled)")
                    if handled { return }
                    
                    // 2) Supabase OAuth callbacks only
                    if url.scheme == "swoopy", url.host == "auth" {
                        DLog("[OPEN_URL] kind=supabase scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
                        Task {
                            await svc.handleOAuthRedirect(url)
                        }
                        return
                    }
                    
                    // 3) Everything else: optional app deep links or ignore
                    AuthDeepLinkHandler.handle(url)
                    DLog("[OPEN_URL] kind=other scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
                }
                .tint(AppTheme.ColorToken.primary)
                .preferredColorScheme(.light) // SwiftUI-level Light Mode enforcement
                .onAppear {
                    // Show consent alert on first launch if consent is unknown
                    if consent.analytics == .unknown {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showConsentAlert = true
                        }
                    }
                }
                .alert("Help improve Swoopy?", isPresented: $showConsentAlert) {
                    Button("Allow analytics") {
                        consent.setProvidedByAlert()
                    }
                    Button("Not now", role: .cancel) {
                        consent.setDeniedByAlert()
                    }
                } message: {
                    Text("Allow anonymous usage, crash, and performance data to fix bugs and enhance your experience.")
                }
        }
    }
}

private struct RootGateView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var api: ApiService
    @EnvironmentObject var notificationService: ReservationNotificationService
    @EnvironmentObject var appState: AppState
    @StateObject private var boot = BootCoordinator.shared
    @StateObject private var appFlow = AppFlowCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var hasLoggedInteractive = false
    @State private var hasBootSequenceStarted = false

    var body: some View {
        appShell
        .onAppear {
            PushIntentRouter.shared.configure(notificationService: notificationService)
            PushRegistrationManager.shared.configure(api: api, supabase: svc)
            startBootSequenceIfNeeded()
            markFirstInteractiveIfNeeded()
            if svc.phase == .signedIn {
                PushRegistrationManager.shared.syncRegistration(trigger: "appStart")
            }
        }
        .onChange(of: svc.phase) { _, newPhase in
            if newPhase != .checking {
                markFirstInteractiveIfNeeded()
            }
            if newPhase == .signedIn {
                AppBoot.markShellToSignedIn()
                CrashlyticsService.setUserId(svc.userId?.uuidString)
                Task {
                    try? await notificationService.fetchNotifications()
                }
                boot.start(svc: svc, api: api)
                PushRegistrationManager.shared.syncRegistration(trigger: "signedIn")
            } else if newPhase == .signedOut {
                CrashlyticsService.setUserId(nil)
                notificationService.reset()
                boot.start(svc: svc, api: api)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                startBootSequenceIfNeeded()
                if svc.phase == .signedIn {
                    Task {
                        try? await notificationService.fetchNotifications()
                    }
                    PushRegistrationManager.shared.syncRegistration(trigger: "appActive")
                }
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
        case .loadingProfile:
            loadingSplash
        case .profileError:
            ProfileErrorGateView(
                message: appFlow.profileErrorMessage,
                onRetry: {
                    Task { await appFlow.retryProfileLoad() }
                },
                onSignOut: {
                    Task { @MainActor in await svc.signOut() }
                }
            )
        case .profileCapture:
            OnboardingFlow()
        case .phoneVerification:
            PhoneOTPVerificationView(initialPhone: svc.serverProfile?.phone, supabase: svc) {
                // After verifying, the refreshed profile will move the flow forward
            }
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
        Group {
            switch appState.authFlow {
            case .resetPassword:
                ResetPasswordView()
            default:
                content
            }
        }
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
    private var didLogAPNSToken = false
    private let pushClickListener = PushClickListener()
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Initialize Firebase early for Auth/URL handling
        installAppCheckProvider()
        FirebaseApp.configure()
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        logRuntimeSecurityState()
        logFirebaseURLSchemePresence()
        Task.detached {
            do {
                let token = try await AppCheck.appCheck().token(forcingRefresh: false)
                DLog("[APP_CHECK_TOKEN] success size=\(token.token.count)")
            } catch {
                DLog("[APP_CHECK_TOKEN] fail reason=\(error.localizedDescription)")
            }
        }
        
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
        configurePushOpenHandling()
        UIApplication.shared.registerForRemoteNotifications()

        // Smartlook Analytics initialization
        // NOTE: Mask sensitive fields (addresses, precise location) in Smartlook recordings.
        if let projectKey = Bundle.main.object(forInfoDictionaryKey: "SmartlookProjectKey") as? String,
           projectKey.isEmpty == false {
            Smartlook.instance.preferences.projectKey = projectKey
            #if DEBUG
            DLog("[ANALYTICS] Smartlook initialized with Info.plist key (length=\(projectKey.count))")
            #endif
        } else {
            #if DEBUG
            DLog("[ANALYTICS] ⚠️ SmartlookProjectKey missing/empty in Info.plist — skipping Smartlook init")
            #endif
        }
        
        // Apply current consent state at boot (native consent system)
        Task { @MainActor in
            let currentState = ConsentManager.shared.analytics
            ConsentRuntime.applyAnalytics(currentState)
            
            #if DEBUG
            DLog("[ANALYTICS] App launched - consent state: \(currentState)")
            #endif
        }
        
        return true
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

    private func configurePushOpenHandling() {
        OneSignal.Notifications.addClickListener(pushClickListener)
    }
}

private final class PushClickListener: NSObject, OSNotificationClickListener {
    func onClick(event: OSNotificationClickEvent) {
        let additionalData = event.notification.additionalData ?? [:]
        DLog("[PUSH] received keys=\(additionalData.keys)")
        guard let intent = PendingPushIntent.from(additionalData: additionalData, source: .push) else {
            DLog("[PUSH] ignored reason=missing_ids")
            return
        }
        DLog("[PUSH] received intent=\(intent.debugSummary)")
        let store = PushIntentStore()
        if store.setIfNew(intent) {
            DLog("[PUSH] stored intent=\(intent.debugSummary)")
            NotificationCenter.default.post(
                name: .pushIntentStored,
                object: nil,
                userInfo: ["reason": "pushReceived"]
            )
        } else if let notificationId = intent.notificationId {
            DLog("[PUSH] ignored reason=duplicate notificationId=\(notificationId.uuidString)")
        }
    }
}

/// Log build/environment state relevant to Firebase Phone Auth/App Check
private func logRuntimeSecurityState() {
    #if DEBUG
    let buildType = "DEBUG"
    #else
    let buildType = "RELEASE"
    #endif
    DLog("[RUNTIME_STATE] build=\(buildType)")
}

private func installAppCheckProvider() {
    let iosVersion = UIDevice.current.systemVersion
    #if DEBUG
    installDebugAppCheckProvider(iosVersion: iosVersion)
    #else
    installReleaseAppCheckProvider(iosVersion: iosVersion)
    #endif
}

#if DEBUG
private func installDebugAppCheckProvider(iosVersion: String) {
    if let debugClass = NSClassFromString("FIRAppCheckDebugProviderFactory") as? NSObject.Type,
       let debugFactory = debugClass.init() as? AppCheckProviderFactory {
        AppCheck.setAppCheckProviderFactory(debugFactory)
        DLog("[APP_CHECK_PROVIDER] installed=true provider=Debug iosVersion=\(iosVersion) build=DEBUG")
        return
    }
    DLog("[APP_CHECK_PROVIDER] installed=false provider=DebugMissing iosVersion=\(iosVersion) build=DEBUG")
    if let deviceCheckFactory = DeviceCheckProviderFactory() as AppCheckProviderFactory? {
        AppCheck.setAppCheckProviderFactory(deviceCheckFactory)
        DLog("[APP_CHECK_PROVIDER] installed=true provider=DeviceCheck iosVersion=\(iosVersion) build=DEBUG")
    }
}
#else
private func installReleaseAppCheckProvider(iosVersion: String) {
    // Prefer App Attest when available; fall back to Device Check
    if #available(iOS 14.0, *) {
        if let attestClass = NSClassFromString("FIRAppAttestProviderFactory") as? NSObject.Type,
           let attestFactory = attestClass.init() as? AppCheckProviderFactory {
            AppCheck.setAppCheckProviderFactory(attestFactory)
            DLog("[APP_CHECK_PROVIDER] installed=true provider=AppAttest iosVersion=\(iosVersion) build=RELEASE")
            return
        }
    }
    if let deviceCheckFactory = DeviceCheckProviderFactory() as AppCheckProviderFactory? {
        AppCheck.setAppCheckProviderFactory(deviceCheckFactory)
        DLog("[APP_CHECK_PROVIDER] installed=true provider=DeviceCheck iosVersion=\(iosVersion) build=RELEASE")
    }
}
#endif

/// Validate Firebase URL scheme is registered to avoid runtime crashes for phone auth
private func logFirebaseURLSchemePresence() {
    let expectedScheme = firebaseExpectedURLScheme() ?? "nil"
    let isPresent = expectedScheme != "nil" ? bundleContainsURLScheme(expectedScheme) : false
    DLog("[FIREBASE_CONFIG] expectedScheme=\(expectedScheme) present=\(isPresent)")
}

private func firebaseExpectedURLScheme() -> String? {
    guard
        let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
        let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
        let sender = plist["GCM_SENDER_ID"] as? String,
        let appId = plist["GOOGLE_APP_ID"] as? String
    else { return nil }
    
    // GOOGLE_APP_ID format: 1:<sender>:ios:<appIdSuffix>
    let parts = appId.split(separator: ":")
    guard parts.count >= 4 else { return nil }
    let suffix = parts.last ?? Substring("")
    return "app-1-\(sender)-ios-\(suffix)"
}

private func bundleContainsURLScheme(_ scheme: String) -> Bool {
    guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
        return false
    }
    for type in types {
        if let schemes = type["CFBundleURLSchemes"] as? [String], schemes.contains(scheme) {
            return true
        }
    }
    return false
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}

extension AppDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard didLogAPNSToken == false else { return }
        didLogAPNSToken = true
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        DLog("[PUSH] APNs token received (required for Firebase phone auth reCAPTCHA-less flow) token=\(token)")
        #if DEBUG
        let tokenType: AuthAPNSTokenType = .sandbox
        #else
        let tokenType: AuthAPNSTokenType = .prod
        #endif
        Auth.auth().setAPNSToken(deviceToken, type: tokenType)
        DLog("[APNS_TOKEN_OK] forwardedToFirebase=true env=\(tokenType == .prod ? "prod" : "sandbox")")
        OneSignal.User.pushSubscription.optIn()
        // OneSignal Swift SDK v5+ handles APNs token internally; no manual setDeviceToken API.
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DLog("[PUSH] failedToRegister error=\(error.localizedDescription)")
    }
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if Auth.auth().canHandleNotification(userInfo) {
            DLog("[PUSH] handledByFirebaseAuth=true (OTP)")
            completionHandler(.noData)
            return
        }
        completionHandler(.newData)
    }
}

extension AppDelegate: OSPushSubscriptionObserver {
    func onPushSubscriptionDidChange(state: OSPushSubscriptionChangedState) {
        logPushSubscriptionState(context: "subscription-change")
        PushRegistrationManager.shared.handleSubscriptionChange(trigger: "subscriptionChange")
    }
}

extension AppDelegate {
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        let firebaseHandled = Auth.auth().canHandle(url)
        DLog("[OPEN_URL] kind=firebaseauth scheme=\(url.scheme ?? "") host=\(url.host ?? "") handled=\(firebaseHandled)")
        if firebaseHandled { return true }
        
        if url.scheme == "swoopy", url.host == "auth" {
            DLog("[OPEN_URL] kind=supabase scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
            Task {
                await SupabaseService.shared.handleOAuthRedirect(url)
            }
            return true
        }
        
        AuthDeepLinkHandler.handle(url)
        DLog("[OPEN_URL] kind=other scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
        return false
    }
}
