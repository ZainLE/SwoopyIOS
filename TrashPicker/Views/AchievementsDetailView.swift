//
//  AchievementsDetailView.swift
//  TrashPicker
//
//  Achievements detail page pushed from the profile's tier card: the full
//  labeled tier ladder up top, then the badge collection. The grid simply
//  grows as future badges are added.
//

import SwiftUI

/// One badge in the achievements catalog, with earned state resolved from
/// the server profile. Built by ProfileView (which also runs unlock
/// detection) and passed in.
struct ProfileAchievementBadge: Identifiable {
    let id: String
    let title: String
    let icon: String
    let hint: String
    let meaning: String
    let theme: AchievementTheme
    let earned: Bool
}

struct AchievementsDetailView: View {
    let tier: LeaderboardTier
    let badges: [ProfileAchievementBadge]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tierLadderCard
                badgesSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var earnedCount: Int { badges.filter(\.earned).count }

    // MARK: Tier ladder

    private var tierLadderCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tier.displayName) tier")
                    .font(AppFont.h3)
                    .foregroundColor(AppColor.text)

                Text("Top 3 on the weekly leaderboard move up a tier — bottom 3 move down.")
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ladder

            NavigationLink(destination: LeaderboardView()) {
                HStack {
                    Text("See this week's leaderboard")
                        .font(AppFont.sub.weight(.semibold))
                        .foregroundColor(AppColor.brandGreen)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColor.brandGreen)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// Reached tiers show their solid color, unreached stay gray, so done vs
    /// still-to-come reads instantly. The current tier gets a glow and a bold
    /// colored label.
    private var ladder: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(LeaderboardTier.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.ladderIndex <= tier.ladderIndex ? step.color : Color(.systemGray4))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 6) {
                ForEach(LeaderboardTier.allCases, id: \.self) { step in
                    let reached = step.ladderIndex <= tier.ladderIndex
                    let isCurrent = step == tier

                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(reached ? step.color : Color(.systemGray5))
                                .frame(width: 34, height: 34)

                            Image(systemName: step.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(reached ? .white : Color(.systemGray))
                        }
                        .shadow(color: isCurrent ? step.color.opacity(0.45) : .clear, radius: 6, y: 2)

                        Text(step.displayName)
                            .font(.system(size: 11, weight: isCurrent ? .bold : .medium))
                            .foregroundColor(isCurrent ? step.color : (reached ? AppColor.text : AppColor.muted))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tier ladder: \(tier.displayName), level \(tier.ladderIndex + 1) of \(LeaderboardTier.allCases.count)")
    }

    // MARK: Badges

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Badges")
                    .font(AppFont.h3)
                    .foregroundColor(AppColor.text)

                Spacer()

                Text("\(earnedCount) of \(badges.count) unlocked")
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
            }

            AchievementBadgeGrid(badges: badges)

            Text("Badges unlock as your finds get picked up — the first confirmed pickup earns your first one.")
                .font(AppFont.caption)
                .foregroundColor(AppColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Badge grid

/// Two-column badge grid. Earned badges are full solid color; locked badges
/// are clearly gray with a padlock and their unlock hint. Cards spring in
/// with a slight stagger on first appearance (skipped under Reduce Motion).
struct AchievementBadgeGrid: View {
    let badges: [ProfileAchievementBadge]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                AchievementBadgeCard(badge: badge)
                    .scaleEffect(appeared ? 1 : 0.88)
                    .opacity(appeared ? 1 : 0)
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.45, dampingFraction: 0.75).delay(Double(index) * 0.07),
                        value: appeared
                    )
            }
        }
        .onAppear { appeared = true }
    }
}

private struct AchievementBadgeCard: View {
    let badge: ProfileAchievementBadge

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AchievementMedallion(icon: badge.icon, theme: badge.theme, size: 56, earned: badge.earned)

                if !badge.earned {
                    ZStack {
                        Circle()
                            .fill(Color(.secondarySystemGroupedBackground))

                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(.systemGray))
                    }
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color(.systemGray3), lineWidth: 1))
                    .offset(x: 3, y: 3)
                }
            }

            VStack(spacing: 2) {
                Text(badge.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(badge.earned ? AppColor.text : Color(.systemGray))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(badge.earned ? "Unlocked" : badge.hint)
                    .font(.system(size: 11, weight: badge.earned ? .semibold : .regular))
                    .foregroundColor(badge.earned ? badge.theme.accent : Color(.systemGray))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 26, alignment: .top)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))

                if badge.earned {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(badge.theme.accent.opacity(0.1))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    badge.earned ? badge.theme.accent.opacity(0.4) : Color(.systemGray4),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.title), \(badge.earned ? "unlocked" : "locked — \(badge.hint)")")
    }
}
