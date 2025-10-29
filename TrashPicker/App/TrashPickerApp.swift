import SwiftUI
import UIKit

@main
struct TrashPickerApp: App {
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
                "figure.walk",
                "checkmark.seal.fill"
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
