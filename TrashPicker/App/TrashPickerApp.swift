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
    @State private var showSplash = true
    @State private var hasLoggedInteractive = false
    @State private var splashTask: Task<Void, Never>?
    @State private var hasScheduledSplash = false // Guard to prevent re-showing splash

    var body: some View {
        ZStack {
            content
                .onAppear {
                    markFirstInteractiveIfNeeded()
                }

            if showSplash {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Image("SwoopyLogo")
                        .resizable().scaledToFit()
                        .frame(width: 140, height: 140)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showSplash)
        .onAppear {
            // Guard: only run boot sequence once per process (prevent re-triggering on modal dismiss)
            guard !hasScheduledSplash else {
                #if DEBUG
                print("[BOOT] onAppear skipped (already booted)")
                #endif
                return
            }
            hasScheduledSplash = true
            
            #if DEBUG
            print("[BOOT] onAppear executing (first launch)")
            #endif
            
            // Boot metrics: mark first frame and start stage orchestration
            BootCoordinator.shared.markFirstFrame()
            BootCoordinator.shared.start(svc: svc, api: api)
            markFirstInteractiveIfNeeded()
            scheduleSplashDismiss()
            if svc.phase == .signedIn {
                AppBoot.markShellToSignedIn()
            }
        }
        .onChange(of: svc.phase) { _, newPhase in
            if newPhase != .checking {
                markFirstInteractiveIfNeeded()
            }
            if newPhase == .signedIn {
                AppBoot.markShellToSignedIn()
            }
        }
        .onDisappear {
            splashTask?.cancel()
        }
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

    private var shouldShowAuth: Bool {
        // Only show auth if explicitly signed out AND session check completed
        // During .checking, show RootView with empty/skeleton state
        svc.phase == .signedOut && svc.didCheckSession
    }

    @ViewBuilder
    private var content: some View {
        // ALWAYS render RootView unless explicitly signed out
        // This ensures shell is interactive immediately, even during .checking phase
        if shouldShowAuth {
            AuthView()
        } else {
            // Show RootView for both .checking and .signedIn phases
            // Feed will show empty/skeleton state while loading
            RootView()
        }
    }

    private func scheduleSplashDismiss() {
        splashTask?.cancel()
        showSplash = true
        let graceStart = Date()
        splashTask = Task {
            #if DEBUG
            // DEBUG: 300ms visual splash for development
            try? await Task.sleep(nanoseconds: 300_000_000)
            #else
            // RELEASE: Dismiss splash immediately, no auth grace hold
            try? await Task.sleep(nanoseconds: 100_000_000)
            #endif
            let ms = Int(Date().timeIntervalSince(graceStart) * 1000)
            await MainActor.run {
                withAnimation {
                    showSplash = false
                }
                #if DEBUG
                print("[AUTH] authGraceHoldMs=\(ms)")
                #endif
            }
        }
    }

    private func markFirstInteractiveIfNeeded() {
        guard hasLoggedInteractive == false else { return }
        hasLoggedInteractive = true
        AppBoot.markFirstInteractive()
    }
}

