//
//  AchievementCelebration.swift
//  TrashPicker
//
//  Shared visual identity for achievements (bright medallion gradients),
//  the glossy medallion component, and the unlock celebration overlay with
//  a self-drawn confetti burst. Used by ProfileView's Achievements section.
//

import SwiftUI
import UIKit

// MARK: - Palette

extension Color {
    /// Appearance-adaptive color from two hex strings; the dark variant
    /// should be brighter so small text stays legible on dark backgrounds.
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
    }
}

/// Visual identity for one achievement: a rich solid medallion fill plus an
/// adaptive accent used for small text in that badge's hue.
struct AchievementTheme: Equatable {
    let fill: Color
    let accent: Color
}

/// Deep, saturated solid badge hues — no gradients, and deliberately no
/// red/crimson anywhere: nothing in this section should read as danger.
enum AchievementPalette {
    /// Deep emerald — First Pickup.
    static let green = AchievementTheme(
        fill: Color(hex: "0E9153"),
        accent: Color(light: "0E8A4A", dark: "5FD98F")
    )
    /// Deep teal — 10 Items Diverted and the impact stat.
    static let teal = AchievementTheme(
        fill: Color(hex: "0B8E96"),
        accent: Color(light: "0A8F92", dark: "4AD7E0")
    )
    /// Warm amber (never red) — 3-Week Streak.
    static let amber = AchievementTheme(
        fill: Color(hex: "E8890B"),
        accent: Color(light: "C06B00", dark: "FFB25C")
    )
    /// Trophy gold — Top 3 Finish.
    static let gold = AchievementTheme(
        fill: Color(hex: "D4A017"),
        accent: Color(light: "9E7A00", dark: "F2C94C")
    )

    /// Rich solid gold for the top-3 weekly rank chip, with a dark bronze
    /// text color that stays readable on it in both appearances.
    static let rankGold = Color(hex: "E3A81B")
    static let rankGoldText = Color(hex: "4A3400")

    /// Confetti mix — the badge hues plus sky blue and violet for variety.
    static let confetti: [Color] = [
        Color(hex: "2BB673"), Color(hex: "B4DD4E"), Color(hex: "3ED3E8"),
        Color(hex: "4DA3FF"), Color(hex: "9B6BFF"), Color(hex: "FFC531")
    ]
}

// MARK: - Medallion

/// Circular badge medallion. Earned: a rich solid fill with a white glyph
/// and a soft glow in the badge's hue. Locked: clearly grayed out — gray
/// fill, gray glyph, no glow — so earned vs locked reads instantly.
struct AchievementMedallion: View {
    let icon: String
    let theme: AchievementTheme
    let size: CGFloat
    var earned: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(earned ? theme.fill : Color(.systemGray5))

            if earned {
                Circle()
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
            }

            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(earned ? .white : Color(.systemGray))
                .shadow(color: .black.opacity(earned ? 0.18 : 0), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(
            color: earned ? theme.fill.opacity(0.45) : .clear,
            radius: size * 0.16,
            y: size * 0.05
        )
    }
}

// MARK: - Confetti

/// Self-drawn confetti burst (no dependencies). Fires once on appear and
/// pauses its render timeline once every particle has expired, so nothing
/// keeps ticking after the celebration settles.
struct ConfettiBurstView: View {
    private struct Particle {
        let launchX: CGFloat
        let velocity: CGVector
        let spin: Double
        let initialAngle: Double
        let size: CGSize
        let color: Color
        let isRound: Bool
        let delay: Double
        let lifetime: Double
    }

    private static let gravity: CGFloat = 950

    private let particles: [Particle]
    @State private var startDate = Date()
    @State private var finished = false

    init(count: Int = 90) {
        particles = (0..<count).map { _ in
            Particle(
                launchX: .random(in: -30...30),
                velocity: CGVector(dx: .random(in: -320...320), dy: .random(in: -750 ... -280)),
                spin: .random(in: -7...7),
                initialAngle: .random(in: 0...(2 * .pi)),
                size: Bool.random()
                    ? CGSize(width: .random(in: 6...11), height: .random(in: 9...15))
                    : CGSize(width: .random(in: 6...10), height: .random(in: 6...10)),
                color: AchievementPalette.confetti.randomElement() ?? .green,
                isRound: Int.random(in: 0..<3) == 0,
                delay: .random(in: 0...0.15),
                lifetime: .random(in: 1.6...2.6)
            )
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: finished)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startDate)
                let emitter = CGPoint(x: size.width / 2, y: size.height * 0.38)

                for particle in particles {
                    let t = elapsed - particle.delay
                    guard t > 0, t < particle.lifetime else { continue }

                    let x = emitter.x + particle.launchX + particle.velocity.dx * CGFloat(t)
                    let y = emitter.y + particle.velocity.dy * CGFloat(t) + 0.5 * Self.gravity * CGFloat(t * t)
                    guard y < size.height + 20 else { continue }

                    let progress = t / particle.lifetime
                    var ctx = context
                    ctx.opacity = progress > 0.72 ? max(0, 1 - (progress - 0.72) / 0.28) : 1
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(particle.initialAngle + particle.spin * t))

                    let rect = CGRect(
                        x: -particle.size.width / 2,
                        y: -particle.size.height / 2,
                        width: particle.size.width,
                        height: particle.size.height
                    )
                    let path = particle.isRound
                        ? Path(ellipseIn: rect)
                        : Path(roundedRect: rect, cornerRadius: 1.5)
                    ctx.fill(path, with: .color(particle.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            startDate = Date()
            let total = (particles.map { $0.delay + $0.lifetime }.max() ?? 3) + 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + total) { finished = true }
        }
    }
}

// MARK: - Celebration overlay

/// One newly earned badge queued for celebration.
struct AchievementUnlock: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let meaning: String
    let theme: AchievementTheme

    static func == (lhs: AchievementUnlock, rhs: AchievementUnlock) -> Bool {
        lhs.id == rhs.id
    }
}

/// Full-screen celebration shown when a badge flips to earned since the user
/// last saw their profile: confetti burst, the medallion springing in, and a
/// one-line explanation of what they did. Confetti and the spring are skipped
/// under Reduce Motion.
struct AchievementCelebrationOverlay: View {
    let unlock: AchievementUnlock
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var medallionShown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            if !reduceMotion {
                ConfettiBurstView()
                    .ignoresSafeArea()
            }

            VStack(spacing: 20) {
                AchievementMedallion(icon: unlock.icon, theme: unlock.theme, size: 96)
                    .scaleEffect(medallionShown ? 1 : 0.25)
                    .rotationEffect(.degrees(medallionShown ? 0 : -14))

                VStack(spacing: 6) {
                    Text("Achievement unlocked")
                        .font(.system(size: 12, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundColor(unlock.theme.accent)

                    Text(unlock.title)
                        .font(AppFont.h2)
                        .foregroundColor(AppColor.text)
                        .multilineTextAlignment(.center)

                    Text(unlock.meaning)
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onDismiss) {
                    Text("Nice!")
                        .font(AppFont.label)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(unlock.theme.fill)
                        .clipShape(Capsule())
                        .shadow(color: unlock.theme.fill.opacity(0.35), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss celebration")
            }
            .padding(28)
            .frame(maxWidth: 330)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 28, y: 14)
            .padding(.horizontal, 24)
            .onAppear {
                if reduceMotion {
                    medallionShown = true
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.08)) {
                        medallionShown = true
                    }
                }
            }
        }
        .accessibilityAction(.escape) { onDismiss() }
    }
}
