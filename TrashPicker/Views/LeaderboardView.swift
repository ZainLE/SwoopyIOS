//
//  LeaderboardView.swift
//  TrashPicker
//
//  Weekly city leaderboard (GET /leaderboard). One point = one confirmed
//  pickup for the poster. Top 3 move up a tier on Monday, bottom 3 move down.
//

import SwiftUI

// MARK: - Tiers

enum LeaderboardTier: String, CaseIterable {
    case starter, contributor, champion, legend

    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .starter: return Color(hex: "8E8E93")      // gray
        case .contributor: return Color(hex: "6AA54A")  // green
        case .champion: return Color(hex: "2F6FD0")     // blue
        case .legend: return Color(hex: "C9A227")       // gold
        }
    }

    /// SF Symbol shown wherever the tier appears with an icon (e.g. Profile).
    var icon: String {
        switch self {
        case .starter: return "leaf.fill"
        case .contributor: return "star.fill"
        case .champion: return "medal.fill"
        case .legend: return "crown.fill"
        }
    }

    /// Position on the tier ladder (0 = starter).
    var ladderIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// The tier above this one; nil once at the top.
    var next: LeaderboardTier? {
        let all = Self.allCases
        let nextIndex = ladderIndex + 1
        return nextIndex < all.count ? all[nextIndex] : nil
    }
}

struct TierBadge: View {
    let tier: LeaderboardTier

    var body: some View {
        Text(tier.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tier.color)
            .clipShape(Capsule())
    }
}

// MARK: - Leaderboard page

struct LeaderboardView: View {
    @EnvironmentObject private var api: ApiService
    @EnvironmentObject private var svc: SupabaseService

    private enum LoadState {
        case loading
        case loaded(LeaderboardResponse)
        case failed
    }

    @State private var loadState: LoadState = .loading

    private let primaryColor = Color(hex: "00513F")
    private let accentColor = Color(hex: "B4DD4E")
    private let mutedColor = Color(hex: "656565")

    private var myUserId: String? {
        svc.userId?.uuidString.lowercased()
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .tint(primaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView(
                    "Leaderboard unavailable",
                    systemImage: "trophy",
                    description: Text("Check your connection and try again.")
                )
            case .loaded(let response):
                board(response)
            }
        }
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        do {
            let response = try await api.getLeaderboard()
            loadState = .loaded(response)
        } catch {
            DLog("[LEADERBOARD] load failed: \(error.localizedDescription)")
            if case .loaded = loadState { return } // keep stale data on refresh failure
            loadState = .failed
        }
    }

    /// The caller's in-list row: matched by user id, with the caller's rank
    /// from `me` as a fallback so a missing/differently-formatted user_id
    /// can't produce a duplicate pinned "You" row.
    private func isCallerRow(_ entry: LeaderboardEntry, me: LeaderboardMe?) -> Bool {
        if let myUserId, let entryId = entry.userId?.lowercased(), entryId == myUserId {
            return true
        }
        if let meRank = me?.rank, let entryRank = entry.rank, meRank == entryRank {
            return true
        }
        return false
    }

    private func displayName(for entry: LeaderboardEntry) -> String {
        let trimmed = entry.firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            return trimmed
        }
        return "Someone"
    }

    @ViewBuilder
    private func board(_ response: LeaderboardResponse) -> some View {
        let isMeInList = response.entries.contains { isCallerRow($0, me: response.me) }

        VStack(spacing: 0) {
            header(response)

            if response.entries.isEmpty {
                ContentUnavailableView(
                    "No pickups yet this week",
                    systemImage: "trophy",
                    description: Text("Share an item and get it picked up to earn your first point.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(response.entries) { entry in
                            entryRow(
                                rank: entry.rank,
                                name: displayName(for: entry),
                                avatarUrl: entry.avatarUrl.flatMap { URL(string: $0) },
                                tier: entry.tier,
                                pickups: entry.weeklyPickups,
                                isMe: isCallerRow(entry, me: response.me)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            // Pin the caller's own rank only when their row isn't already visible.
            if let me = response.me, isMeInList == false {
                pinnedMeRow(me)
            }
        }
    }

    private func header(_ response: LeaderboardResponse) -> some View {
        VStack(spacing: 4) {
            Text(weekLabel(from: response.weekStart))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            Text("Top 3 move up a tier on Monday")
                .font(.system(size: 13))
                .foregroundColor(mutedColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(accentColor.opacity(0.25))
    }

    private func entryRow(
        rank: Int?,
        name: String,
        avatarUrl: URL?,
        tier: String?,
        pickups: Int,
        isMe: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text(rank.map { "#\($0)" } ?? "–")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(rankColor(rank))
                .frame(width: 40, alignment: .leading)

            avatar(avatarUrl, name: name)

            VStack(alignment: .leading, spacing: 3) {
                Text(isMe && name != "You" ? "\(name) (you)" : name)
                    .font(.system(size: 15, weight: isMe ? .semibold : .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let tier = tier.flatMap({ LeaderboardTier(rawValue: $0.lowercased()) }) {
                    TierBadge(tier: tier)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(pickups)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(primaryColor)
                Text(pickups == 1 ? "pickup" : "pickups")
                    .font(.system(size: 11))
                    .foregroundColor(mutedColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isMe ? accentColor.opacity(0.35) : Color(.secondarySystemBackground))
        )
    }

    private func pinnedMeRow(_ me: LeaderboardMe) -> some View {
        VStack(spacing: 0) {
            Divider()
            entryRow(
                rank: me.rank,
                name: "You",
                avatarUrl: nil,
                tier: me.tier,
                pickups: me.weeklyPickups ?? 0,
                isMe: true
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func avatar(_ url: URL?, name: String) -> some View {
        if let url {
            ResilientAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                default:
                    avatarFallback(name)
                }
            }
        } else {
            avatarFallback(name)
        }
    }

    private func avatarFallback(_ name: String) -> some View {
        Circle()
            .fill(primaryColor.opacity(0.15))
            .frame(width: 38, height: 38)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryColor)
            )
    }

    private func rankColor(_ rank: Int?) -> Color {
        switch rank {
        case 1, 2, 3: return LeaderboardTier.legend.color
        default: return mutedColor
        }
    }

    private func weekLabel(from weekStart: String?) -> String {
        guard let weekStart else { return "This week" }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "Europe/Madrid")
        guard let date = parser.date(from: weekStart) else { return "This week" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "Week of \(formatter.string(from: date))"
    }
}

// MARK: - Home screen entry pill

/// Small floating pill for the home screen's top-left: trophy plus the
/// caller's current rank when available. Styled like the home screen's other
/// floating controls (brand-dark SF Symbol on ultra-thin material). Tapping
/// asks the host screen to push the leaderboard via the shared binding; the
/// rank refetches when the page pops so the pill never shows a stale rank.
struct LeaderboardPill: View {
    @Binding var isOpen: Bool

    @EnvironmentObject private var api: ApiService
    @EnvironmentObject private var svc: SupabaseService

    @State private var myRank: Int?
    @State private var didFetch = false

    var body: some View {
        Button {
            Haptics.play(.tabSelect)
            isOpen = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trophy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.ColorToken.brandDark)

                if let myRank {
                    Text("#\(myRank)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.ColorToken.brandDark)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(myRank.map { "Leaderboard, your rank \($0)" } ?? "Leaderboard")
        .task { await fetchRank() }
        .onChange(of: isOpen) { _, open in
            if open == false {
                Task { await fetchRank(force: true) }
            }
        }
    }

    @MainActor
    private func fetchRank(force: Bool = false) async {
        guard force || didFetch == false else { return }
        didFetch = true
        guard svc.hasAuthToken else { return }
        if let response = try? await api.getLeaderboard() {
            myRank = response.me?.rank
        }
    }
}
