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
        case .starter: return Color(hex: "1E3A5F")      // deep cool blue
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
    @Environment(\.colorScheme) private var colorScheme

    private enum LoadState {
        case loading
        case loaded(LeaderboardResponse)
        case failed
    }

    @State private var loadState: LoadState = .loading

    /// Rows as currently rendered. Usually mirrors the response order, but the
    /// rank-up animation briefly holds the caller's row at its previous
    /// position before sliding it up (Task: Duolingo-style rank-up).
    @State private var displayEntries: [LeaderboardEntry] = []
    @State private var pulsingMyRow = false
    @State private var rankUpTask: Task<Void, Never>?

    private let primaryColor = Color(hex: "00513F")
    private let accentColor = Color(hex: "B4DD4E")
    private let mutedColor = Color(hex: "656565")

    /// Never slide the caller's row more than this many positions — beyond
    /// that the theater stops reading as "my row moved" inside a LazyVStack.
    private static let maxRankUpSlide = 4

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
        .onDisappear { rankUpTask?.cancel() }
    }

    @MainActor
    private func load() async {
        do {
            let response = try await api.getLeaderboard()
            loadState = .loaded(response)
            prepareDisplayEntries(response)
        } catch {
            DLog("[LEADERBOARD] load failed: \(error.localizedDescription)")
            if case .loaded = loadState { return } // keep stale data on refresh failure
            loadState = .failed
        }
    }

    // MARK: - Rank-up animation

    /// Scoped by userId (prevents cross-account leakage) and week start (a new
    /// week resets everyone's rank, so last week's number is meaningless).
    private func lastSeenRankKey(weekStart: String?) -> String? {
        guard let myUserId else { return nil }
        return "leaderboard.lastSeenRank.\(myUserId).\(weekStart ?? "unknown-week")"
    }

    /// Decides what the list initially shows. If the caller's rank improved
    /// since the last visit and their row is visible, render it at its old
    /// position first, then slide it up so the progress is felt, not implied.
    @MainActor
    private func prepareDisplayEntries(_ response: LeaderboardResponse) {
        rankUpTask?.cancel()
        pulsingMyRow = false

        let entries = response.entries
        let myIndex = entries.firstIndex(where: isCallerRow)
        let currentRank = myIndex.flatMap { entries[$0].rank } ?? response.me?.rank

        var lastSeenRank: Int?
        if let key = lastSeenRankKey(weekStart: response.weekStart) {
            lastSeenRank = UserDefaults.standard.object(forKey: key) as? Int
            if let currentRank {
                UserDefaults.standard.set(currentRank, forKey: key)
            }
        }

        guard
            let myIndex,
            let currentRank,
            let lastSeenRank,
            currentRank < lastSeenRank
        else {
            displayEntries = entries
            return
        }

        let steps = min(lastSeenRank - currentRank, Self.maxRankUpSlide)
        let startIndex = min(entries.count - 1, myIndex + steps)
        guard startIndex > myIndex else {
            displayEntries = entries
            return
        }

        var initial = entries
        let myRow = initial.remove(at: myIndex)
        initial.insert(myRow, at: startIndex)
        displayEntries = initial
        runRankUpAnimation(from: startIndex, to: myIndex)
    }

    /// Slides the caller's row up one position at a time with a spring, a
    /// haptic tick per row passed, and a success haptic + highlight pulse on
    /// arrival.
    @MainActor
    private func runRankUpAnimation(from startIndex: Int, to endIndex: Int) {
        rankUpTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)

            var index = startIndex
            while index > endIndex {
                guard Task.isCancelled == false else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    displayEntries.swapAt(index, index - 1)
                }
                Haptics.play(.tabSelect)
                index -= 1
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            guard Task.isCancelled == false else { return }
            Haptics.play(.success)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                pulsingMyRow = true
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            withAnimation(.easeOut(duration: 0.4)) {
                pulsingMyRow = false
            }
        }
    }

    /// The caller's in-list row, matched strictly by user id (case-insensitive).
    /// Never fall back to rank equality: ties share a rank, so that would mark
    /// someone else's row as "(you)". If the caller's row can't be identified
    /// by id, the pinned "You" row below the list covers them instead.
    private func isCallerRow(_ entry: LeaderboardEntry) -> Bool {
        guard let myUserId, let entryId = entry.userId?.lowercased() else { return false }
        return entryId == myUserId
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
        let isMeInList = response.entries.contains(where: isCallerRow)
        let rows = displayEntries.isEmpty ? response.entries : displayEntries

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
                        ForEach(rows) { entry in
                            entryRow(
                                rank: entry.rank,
                                name: displayName(for: entry),
                                avatarUrl: entry.avatarUrl.flatMap { URL(string: $0) },
                                tier: entry.tier,
                                pickups: entry.weeklyPickups,
                                isMe: isCallerRow(entry)
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

    /// Visual treatment for a podium position (#1–#3). SOLID colors only — no
    /// gradients. Light mode gets rich metal fills (real gold for #1); dark
    /// mode gets deliberate deep variants with bright metal accents so the
    /// podium still reads as gold/silver/bronze, not as muddy gray.
    private struct PodiumAccent {
        let fill: Color        // solid row background
        let stroke: Color      // row border + avatar ring
        let accent: Color      // rank number + crown/medal icon
        let icon: String
        let strokeWidth: CGFloat
        let avatarSize: CGFloat
    }

    private func podiumAccent(_ rank: Int?) -> PodiumAccent? {
        let dark = colorScheme == .dark
        switch rank {
        case 1:
            return PodiumAccent(
                fill: dark ? Color(hex: "4A3B0A") : Color(hex: "E6B422"),
                stroke: dark ? Color(hex: "FFD34D") : Color(hex: "B8860B"),
                accent: dark ? Color(hex: "FFD34D") : Color(hex: "6E5106"),
                icon: "crown.fill",
                strokeWidth: 2,
                avatarSize: 44
            )
        case 2:
            return PodiumAccent(
                fill: dark ? Color(hex: "2F343C") : Color(hex: "D7DCE2"),
                stroke: dark ? Color(hex: "A8B0BC") : Color(hex: "9AA3AE"),
                accent: dark ? Color(hex: "C3CAD4") : Color(hex: "5C6570"),
                icon: "medal.fill",
                strokeWidth: 1.5,
                avatarSize: 40
            )
        case 3:
            return PodiumAccent(
                fill: dark ? Color(hex: "3E2E1E") : Color(hex: "D99A5B"),
                stroke: dark ? Color(hex: "D08E4E") : Color(hex: "A9713A"),
                accent: dark ? Color(hex: "E0A56A") : Color(hex: "6F4517"),
                icon: "medal.fill",
                strokeWidth: 1.5,
                avatarSize: 40
            )
        default:
            return nil
        }
    }

    private func entryRow(
        rank: Int?,
        name: String,
        avatarUrl: URL?,
        tier: String?,
        pickups: Int,
        isMe: Bool
    ) -> some View {
        let accent = podiumAccent(rank)
        let isPulsing = isMe && pulsingMyRow

        return HStack(spacing: 12) {
            HStack(spacing: 3) {
                if let accent {
                    Image(systemName: accent.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(accent.accent)
                }
                Text(rank.map { "#\($0)" } ?? "–")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(accent?.accent ?? mutedColor)
            }
            .frame(width: 44, alignment: .leading)

            avatar(avatarUrl, name: name, size: accent?.avatarSize ?? 38)
                .overlay(
                    Circle().strokeBorder(
                        accent?.stroke ?? .clear,
                        lineWidth: accent?.strokeWidth ?? 0
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(isMe && name != "You" ? "\(name) (you)" : name)
                    .font(.system(size: 15, weight: isMe || accent != nil ? .semibold : .medium))
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
        .background(rowBackground(accent: accent, isMe: isMe))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isPulsing ? accentColor : (accent?.stroke ?? .clear),
                    lineWidth: isPulsing ? 2.5 : (accent?.strokeWidth ?? 0)
                )
        )
        .scaleEffect(isPulsing ? 1.03 : 1)
    }

    /// Solid fills only — no gradients on podium rows.
    private func rowBackground(accent: PodiumAccent?, isMe: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(
                accent?.fill
                    ?? (isMe ? accentColor.opacity(0.35) : Color(.secondarySystemBackground))
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
    private func avatar(_ url: URL?, name: String, size: CGFloat = 38) -> some View {
        if let url {
            ResilientAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                default:
                    avatarFallback(name, size: size)
                }
            }
        } else {
            avatarFallback(name, size: size)
        }
    }

    private func avatarFallback(_ name: String, size: CGFloat = 38) -> some View {
        Circle()
            .fill(primaryColor.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryColor)
            )
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
