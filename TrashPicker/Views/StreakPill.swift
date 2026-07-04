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

            Text("\(displayedStreak)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(AppTheme.ColorToken.brandDark)
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

        if reduceMotion == false {
            NotificationCenter.default.post(name: .streakEggBurst, object: nil)
        }

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

/// Full-screen flame burst: warm flames rise and sweep the whole display for
/// ~1.6s, then it dismisses itself (tap dismisses early). Rendered with
/// TimelineView + Canvas so the particle field costs one draw pass per frame.
/// The host skips presenting this entirely when Reduce Motion is on.
struct StreakEggOverlay: View {
    let onFinished: () -> Void

    static let duration: Double = 1.6

    @State private var startDate: Date?

    private struct Particle {
        let xFraction: CGFloat     // horizontal lane
        let delay: Double          // stagger, seconds
        let speed: CGFloat         // screen-heights per second
        let size: CGFloat          // font size
        let swayAmplitude: CGFloat
        let swayFrequency: Double
        let color: Color
    }

    private static let palette: [Color] = [
        Color(hex: "FF7A00"),
        Color(hex: "FF9500"),
        Color(hex: "FFB340"),
        Color(hex: "FFC53D")
    ]

    /// Deterministic pseudo-random field — same show every time, no RNG.
    private static let particles: [Particle] = (0..<36).map { index in
        let h1 = fract(Double(index) * 0.6180339887)        // golden-ratio hash
        let h2 = fract(Double(index) * 0.7548776662 + 0.37)
        let h3 = fract(Double(index) * 0.5698402910 + 0.71)
        return Particle(
            xFraction: CGFloat(h1),
            delay: h2 * 0.45,
            speed: 0.75 + CGFloat(h3) * 0.85,
            size: 18 + CGFloat(h2) * 30,
            swayAmplitude: 10 + CGFloat(h1) * 22,
            swayFrequency: 3.5 + h3 * 3.0,
            color: palette[index % palette.count]
        )
    }

    private static func fract(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                guard let startDate else { return }
                let elapsed = timeline.date.timeIntervalSince(startDate)
                let progress = min(elapsed / Self.duration, 1.0)

                // Warm wash that breathes in and back out over the run.
                let washOpacity = 0.18 * sin(progress * .pi)
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(hex: "FF7A00").opacity(washOpacity))
                )

                // Global fade-out over the last quarter.
                let fadeOut = progress > 0.75 ? (1 - progress) / 0.25 : 1.0

                for particle in Self.particles {
                    let localTime = elapsed - particle.delay
                    guard localTime > 0 else { continue }

                    let travel = CGFloat(localTime) * particle.speed * size.height
                    let y = size.height + particle.size - travel
                    guard y > -particle.size else { continue }

                    let sway = CGFloat(sin(localTime * particle.swayFrequency * 2 * .pi))
                        * particle.swayAmplitude
                    let x = particle.xFraction * size.width + sway

                    let fadeIn = min(localTime / 0.15, 1.0)
                    let opacity = fadeIn * fadeOut

                    let flame = context.resolve(
                        Text(Image(systemName: "flame.fill"))
                            .font(.system(size: particle.size, weight: .bold))
                            .foregroundColor(particle.color.opacity(opacity))
                    )
                    context.draw(flame, at: CGPoint(x: x, y: y))
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onFinished() }
        .accessibilityHidden(true)
        .onAppear { startDate = Date() }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            onFinished()
        }
    }
}
