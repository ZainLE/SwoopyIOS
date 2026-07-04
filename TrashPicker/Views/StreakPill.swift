//
//  StreakPill.swift
//  TrashPicker
//
//  Home-screen top-left streak indicator: a bare flame glyph + week count
//  (no button chrome — it reads as a status, not a control). The streak is
//  WEEKLY by design: consecutive weeks with at least one confirmed pickup as
//  poster (`streak_weeks` on GET /me/profile). Last value is cached per user
//  in UserDefaults so it renders instantly on launch. Single tap shows an
//  explainer card; 5 rapid taps within ~2s trigger a hidden full-screen
//  flame-burst (rendered by StreakEggOverlay at screen level — the pill just
//  broadcasts the trigger).
//

import SwiftUI

// MARK: - API

extension ApiService {
    /// Caller's current pickup streak in weeks (`streak_weeks`, always present,
    /// 0 when no streak). Decoded standalone so the shared Profile model
    /// doesn't need to change.
    func getStreakWeeks(token: String) async throws -> Int {
        guard token.isEmpty == false else { throw ApiServiceError.noAuthToken }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json"
        ]
        let request = try buildRequest(path: "/me/profile", method: .GET, headers: headers)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ApiServiceError.unknownError
        }
        struct Payload: Decodable {
            let streakWeeks: Int?
            enum CodingKeys: String, CodingKey { case streakWeeks = "streak_weeks" }
        }
        return try JSONDecoder().decode(Payload.self, from: data).streakWeeks ?? 0
    }
}

// MARK: - Egg broadcast

extension Notification.Name {
    /// Posted by StreakPill when the rapid-tap easter egg fires; the home
    /// screen listens and runs the full-screen StreakEggOverlay.
    static let streakEggBurst = Notification.Name("streakEggBurst")
}

// MARK: - Pill

struct StreakPill: View {
    @EnvironmentObject private var api: ApiService
    @EnvironmentObject private var svc: SupabaseService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var streak: Int?
    @State private var showInfo = false

    // Easter egg state
    @State private var recentTaps: [Date] = []
    @State private var tooltipTask: Task<Void, Never>?
    @State private var eggRunning = false
    @State private var flameSwell = false
    @State private var numberDance = false

    private static let eggTapCount = 5
    private static let eggTapWindow: TimeInterval = 2.0

    private var displayedStreak: Int { streak ?? 0 }
    private var isLit: Bool { displayedStreak > 0 }

    private var flameColor: Color {
        isLit ? Color(hex: "FF8A00") : Color(hex: "9A9AA0")
    }

    var body: some View {
        // Deliberately no capsule/material background: this is a flame sitting
        // in the toolbar, not a button. The tap targets stay via contentShape.
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(flameColor)
                .scaleEffect(flameSwell ? 1.35 : 1)

            // .primary, not brandDark: with no material backing, the count
            // must read directly on the nav bar in both light and dark mode.
            Text("\(displayedStreak)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.primary)
                .opacity(isLit ? 1 : 0.6)
                .monospacedDigit()
                .scaleEffect(numberDance ? 1.3 : 1)
                .rotationEffect(.degrees(numberDance ? -12 : 0))
        }
        // Legibility over busy light/dark content without a background pill.
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streak, \(displayedStreak) \(displayedStreak == 1 ? "week" : "weeks")")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showInfo) {
            infoCard
                .presentationCompactAdaptation(.popover)
        }
        .task {
            loadCachedStreak()
            await fetchStreak()
        }
        .onDisappear { tooltipTask?.cancel() }
    }

    // MARK: Info card (weekly framing)

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(flameColor)

                Text(infoTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Text(infoBody)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(width: 290, alignment: .leading)
    }

    private var infoTitle: String {
        switch displayedStreak {
        case 0: return "No streak yet"
        case 1: return "1-week streak"
        default: return "\(displayedStreak)-week streak"
        }
    }

    private var infoBody: String {
        if isLit {
            return "One of your finds picked up every week for \(displayedStreak) \(displayedStreak == 1 ? "week" : "weeks") straight. Keep it alive this week!"
        }
        return "Get one of your finds picked up this week to start one."
    }

    // MARK: Data

    private var cacheKey: String? {
        svc.userId.map { "streakPill.cachedWeeks.\($0.uuidString.lowercased())" }
    }

    private func loadCachedStreak() {
        guard streak == nil, let cacheKey,
              let cached = UserDefaults.standard.object(forKey: cacheKey) as? Int else { return }
        streak = cached
    }

    @MainActor
    private func fetchStreak() async {
        guard svc.hasAuthToken, let token = svc.currentAccessTokenOrNil() else { return }
        guard let value = try? await api.getStreakWeeks(token: token) else { return }
        streak = value
        if let cacheKey {
            UserDefaults.standard.set(value, forKey: cacheKey)
        }
    }

    // MARK: Taps

    private func handleTap() {
        Haptics.play(.tabSelect)

        let now = Date()
        recentTaps = recentTaps.filter { now.timeIntervalSince($0) < Self.eggTapWindow } + [now]
        tooltipTask?.cancel()

        if recentTaps.count >= Self.eggTapCount {
            recentTaps = []
            triggerEgg()
            return
        }

        // Show the explainer only if no follow-up tap lands quickly, so a
        // rapid burst heads straight for the egg instead of fighting the card.
        guard recentTaps.count == 1, eggRunning == false else { return }
        tooltipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard Task.isCancelled == false else { return }
            showInfo = true
        }
    }

    // MARK: Easter egg

    /// Haptic pattern + a small local flame/number celebration; the actual
    /// fire show is full-screen, run by the home screen via the notification.
    private func triggerEgg() {
        guard eggRunning == false else { return }
        showInfo = false
        eggRunning = true

        // ALWAYS post — the overlay adapts to Reduce Motion itself. (Gating
        // the post here is exactly how "haptics fire but no flames appear"
        // happens.)
        DLog("[STREAK EGG] posting burst notification")
        NotificationCenter.default.post(name: .streakEggBurst, object: nil)

        Task { @MainActor in
            Haptics.play(.primaryAction)
            if reduceMotion == false {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                    flameSwell = true
                    numberDance = true
                }
            }

            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 180_000_000)
                Haptics.play(.tabSelect)
                if reduceMotion == false {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                        numberDance.toggle()
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
            Haptics.play(.success)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                flameSwell = false
                numberDance = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            eggRunning = false
        }
    }
}

// MARK: - Full-screen egg overlay

/// Full-screen flame rain: dozens of flame icons fall across the ENTIRE
/// screen top-to-bottom with gravity-feel acceleration, slight horizontal
/// drift and rotation, in mixed sizes/opacities, then cleanly fade out.
/// Runs ~1.6s (the span of the pill's haptic pattern) and dismisses itself;
/// tapping dismisses early. Rendered with TimelineView + Canvas — one draw
/// pass per frame regardless of flame count. Under Reduce Motion it renders
/// a calmer variant (fewer flames, gentler fall, no spin) instead of hiding.
struct StreakEggOverlay: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let duration: Double = 1.6

    @State private var startDate: Date?

    private struct Flame {
        let xFraction: CGFloat   // horizontal lane, 0...1
        let delay: Double        // stagger before this flame starts, seconds
        let launchSpeed: CGFloat // initial downward speed, screen-heights/s
        let size: CGFloat        // font size, pt
        let drift: CGFloat       // horizontal drift, -1...1 (fraction of width/s)
        let spin: Double         // radians/s, signed
        let maxOpacity: Double
        let color: Color
    }

    private static let palette: [Color] = [
        Color(hex: "FF7A00"),
        Color(hex: "FF9500"),
        Color(hex: "FFB340"),
        Color(hex: "FFC53D")
    ]

    /// Downward acceleration, screen-heights/s² — the "physics pulling them
    /// down" feel. Tuned so a zero-speed flame crosses a full screen within
    /// the show's duration.
    private static let gravity: CGFloat = 1.15

    /// Deterministic pseudo-random field (golden-ratio hashing) — same show
    /// every time, no RNG needed.
    private static func makeFlames(count: Int) -> [Flame] {
        (0..<count).map { index in
            let h1 = fract(Double(index) * 0.6180339887)
            let h2 = fract(Double(index) * 0.7548776662 + 0.37)
            let h3 = fract(Double(index) * 0.5698402910 + 0.71)
            return Flame(
                xFraction: CGFloat(h1),
                delay: h2 * 0.5,
                launchSpeed: 0.15 + CGFloat(h3) * 0.55,
                size: 14 + CGFloat(h2) * 30,
                drift: CGFloat(h3 - 0.5) * 2,
                spin: (h1 - 0.5) * 2 * 4.0,
                maxOpacity: 0.5 + h1 * 0.5,
                color: palette[index % palette.count]
            )
        }
    }

    private static let fullField: [Flame] = makeFlames(count: 48)
    private static let calmField: [Flame] = makeFlames(count: 14)

    private static func fract(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                guard let startDate else { return }
                let elapsed = timeline.date.timeIntervalSince(startDate)
                let progress = min(elapsed / Self.duration, 1.0)

                // Clean fade over the last quarter of the show.
                let fadeOut = progress > 0.75 ? (1 - progress) / 0.25 : 1.0

                let flames = reduceMotion ? Self.calmField : Self.fullField
                let gravity = reduceMotion ? Self.gravity * 0.4 : Self.gravity

                for flame in flames {
                    let t = CGFloat(elapsed - flame.delay)
                    guard t > 0 else { continue }

                    // y(t) = y0 + v0·t + ½·g·t² — starts just above the top.
                    let yFraction = -0.1 + flame.launchSpeed * t + 0.5 * gravity * t * t
                    let y = yFraction * size.height
                    guard y < size.height + flame.size else { continue }

                    let x = flame.xFraction * size.width
                        + flame.drift * 0.08 * size.width * t
                    let rotation = reduceMotion ? 0 : flame.spin * Double(t)

                    let fadeIn = min(Double(t) / 0.12, 1.0)
                    let opacity = flame.maxOpacity * fadeIn * fadeOut
                    guard opacity > 0.01 else { continue }

                    let resolved = context.resolve(
                        Text(Image(systemName: "flame.fill"))
                            .font(.system(size: flame.size, weight: .bold))
                            .foregroundColor(flame.color.opacity(opacity))
                    )

                    var flameContext = context
                    flameContext.translateBy(x: x, y: y)
                    flameContext.rotate(by: .radians(rotation))
                    flameContext.draw(resolved, at: .zero)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onFinished() }
        .allowsHitTesting(true)
        .accessibilityHidden(true)
        .onAppear {
            DLog("[STREAK EGG] overlay appeared, starting flame rain")
            startDate = Date()
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            onFinished()
        }
    }
}
