//
//  StreakPill.swift
//  TrashPicker
//
//  Home-screen top-left pill: the caller's weekly pickup streak (consecutive
//  weeks with at least one confirmed pickup as poster; `streak_weeks` on
//  GET /me/profile). Last value is cached per user in UserDefaults so the pill
//  renders instantly on launch. Single tap explains the streak; rapidly
//  tapping 5 times within ~2s triggers a hidden flame-burst easter egg.
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

// MARK: - Pill

struct StreakPill: View {
    @EnvironmentObject private var api: ApiService
    @EnvironmentObject private var svc: SupabaseService

    @State private var streak: Int?
    @State private var showInfo = false

    // Easter egg state
    @State private var recentTaps: [Date] = []
    @State private var tooltipTask: Task<Void, Never>?
    @State private var eggActive = false
    @State private var eggProgress: CGFloat = 0
    @State private var numberDance = false

    private static let eggTapCount = 5
    private static let eggTapWindow: TimeInterval = 2.0

    private var displayedStreak: Int { streak ?? 0 }
    private var isLit: Bool { displayedStreak > 0 }

    /// Warm amber-to-orange — fire, not alarm. Grays out at streak 0.
    private var flameStyle: LinearGradient {
        if isLit {
            return LinearGradient(
                colors: [Color(hex: "FFC53D"), Color(hex: "FF7A00")],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(hex: "B0B0B5"), Color(hex: "8E8E93")],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(flameStyle)
                    .scaleEffect(eggActive ? 1.45 : 1)
                    .overlay(burstParticles)

                Text("\(displayedStreak)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.ColorToken.brandDark)
                    .opacity(isLit ? 1 : 0.55)
                    .scaleEffect(numberDance ? 1.35 : 1)
                    .rotationEffect(.degrees(numberDance ? -14 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    Color(hex: "FF7A00").opacity(eggActive ? 0.8 : 0),
                    lineWidth: 1.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Streak, \(displayedStreak) \(displayedStreak == 1 ? "week" : "weeks")")
        .popover(isPresented: $showInfo) {
            infoContent
                .presentationCompactAdaptation(.popover)
        }
        .task {
            loadCachedStreak()
            await fetchStreak()
        }
        .onDisappear { tooltipTask?.cancel() }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                displayedStreak == 1
                    ? "1-week streak"
                    : "\(displayedStreak)-week streak",
                systemImage: "flame.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(
                isLit ? Color(hex: "FF7A00") : Color(hex: "8E8E93")
            )

            Text("Get at least one of your finds picked up each week to keep the flame burning.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 260, alignment: .leading)
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

        // Show the tooltip only if no follow-up tap lands quickly, so a rapid
        // burst heads straight for the egg instead of fighting the popover.
        guard recentTaps.count == 1, eggActive == false else { return }
        tooltipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard Task.isCancelled == false else { return }
            showInfo = true
        }
    }

    // MARK: Easter egg

    private func triggerEgg() {
        guard eggActive == false else { return }
        showInfo = false
        eggProgress = 0

        Task { @MainActor in
            Haptics.play(.primaryAction)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                eggActive = true
                numberDance = true
            }
            withAnimation(.easeOut(duration: 0.9)) {
                eggProgress = 1
            }

            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 180_000_000)
                Haptics.play(.tabSelect)
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                    numberDance.toggle()
                }
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
            Haptics.play(.success)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                numberDance = false
                eggActive = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            eggProgress = 0
        }
    }

    /// Tiny flame/spark shower flying out of the flame while the egg runs.
    /// Pure state-driven offsets — cheap, self-contained, nothing persistent.
    @ViewBuilder
    private var burstParticles: some View {
        if eggActive || eggProgress > 0 {
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let angle = (Double(index) / 8.0) * 2 * .pi + (index.isMultiple(of: 2) ? 0.3 : 0)
                    Image(systemName: index.isMultiple(of: 2) ? "flame.fill" : "sparkle")
                        .font(.system(size: index.isMultiple(of: 2) ? 10 : 7, weight: .bold))
                        .foregroundStyle(flameStyle)
                        .opacity(Double(1 - eggProgress))
                        .scaleEffect(0.5 + 0.7 * eggProgress)
                        .offset(
                            x: CGFloat(cos(angle)) * 24 * eggProgress,
                            y: CGFloat(sin(angle)) * 24 * eggProgress - 8 * eggProgress
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }
}
