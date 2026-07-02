//
//  LeaderboardView.swift
//  TrashPicker
//
//  Weekly city leaderboard (GET /leaderboard). One point = one confirmed
//  pickup for the poster. Top 3 move up a tier on Monday, bottom 3 move down.
//

import SwiftUI

// MARK: - Tiers

enum LeaderboardTier: String {
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

    @ViewBuilder
    private func board(_ response: LeaderboardResponse) -> some View {
        let isMeInList = response.entries.contains { $0.userId?.lowercased() == myUserId }

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
                                name: entry.firstName ?? "Someone",
                                avatarUrl: entry.avatarUrl.flatMap { URL(string: $0) },
                                tier: entry.tier,
                                pickups: entry.weeklyPickups,
                                isMe: entry.userId?.lowercased() == myUserId
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

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
                Text(isMe ? "\(name) (you)" : name)
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
/// caller's current rank when available. Tapping opens the leaderboard.
struct LeaderboardPill: View {
    @EnvironmentObject private var api: ApiService
    @EnvironmentObject private var svc: SupabaseService

    @State private var myRank: Int?
    @State private var showLeaderboard = false
    @State private var didFetch = false

    var body: some View {
        Button {
            Haptics.play(.tabSelect)
            showLeaderboard = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LeaderboardTier.legend.color)

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
        .sheet(isPresented: $showLeaderboard, onDismiss: {
            Task { await fetchRank(force: true) }
        }) {
            NavigationStack {
                LeaderboardView()
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
