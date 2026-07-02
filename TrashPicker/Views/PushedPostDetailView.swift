//
//  PushedPostDetailView.swift
//  TrashPicker
//
//  Post detail presented when the user taps a push notification
//  ("post_picked_up" routes to a completed state, "new_post_nearby"
//  routes to a reservable detail).
//

import SwiftUI
import CoreLocation

struct PushedPostDetail: Identifiable, Equatable {
    enum Context: Equatable {
        case pickedUp
        case nearby
    }

    let id = UUID()
    let postId: String
    let context: Context
}

struct PushedPostDetailView: View {
    let detail: PushedPostDetail
    let onDismiss: () -> Void

    @EnvironmentObject private var api: ApiService

    private enum LoadState {
        case loading
        case loaded(Post)
        case unavailable
    }

    @State private var loadState: LoadState = .loading
    @State private var isReserving = false

    private let primaryColor = Color(hex: "00513F")

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            switch loadState {
            case .loading:
                ProgressView()
                    .tint(primaryColor)
            case .loaded(let post):
                overlay(for: post)
            case .unavailable:
                unavailableCard
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let post = try await api.getPost(detail.postId)
            loadState = .loaded(post)
        } catch {
            DLog("[PUSH_ROUTE] pushed post load failed postId=\(detail.postId) error=\(error.localizedDescription)")
            loadState = .unavailable
        }
    }

    @ViewBuilder
    private func overlay(for post: Post) -> some View {
        let images = post.images
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { $0.url.absoluteString }

        BigCardOverlay(
            postID: post.id,
            images: images,
            primaryInfo: primaryInfo(for: post),
            statusInfo: statusInfo(for: post),
            statusColor: detail.context == .pickedUp ? Color(hex: "6AA54A") : primaryColor,
            description: post.description,
            mode: post.mode == .street ? .street : .home,
            exactCoordinate: post.exactCoordinate,
            approxCoordinate: post.approxCoordinate,
            ownerName: post.owner?.fullName ?? "Anonymous User",
            ownerAvatarUrl: post.owner?.avatarUrl,
            ownerId: post.ownerId,
            memberSince: post.createdAt,
            pickupsCount: post.owner?.pickedCount,
            variant: detail.context == .pickedUp ? .reservations(.completed) : .feed,
            completedMessage: detail.context == .pickedUp ? "Item picked up 🎉" : nil,
            onDismiss: onDismiss,
            onPrimaryAction: { handlePrimaryAction(for: post) },
            onSecondaryAction: onDismiss,
            onTertiaryAction: nil
        )
    }

    private func primaryInfo(for post: Post) -> String {
        if post.mode == .home {
            return "From home (address hidden)"
        }
        if let distanceKm = post.distance {
            return DistanceFormatterHelper.formattedDistance(fromMeters: distanceKm * 1_000)
        }
        return "Street find"
    }

    private func statusInfo(for post: Post) -> String {
        switch detail.context {
        case .pickedUp:
            return "Picked up"
        case .nearby:
            if let createdAt = post.createdAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                return "Posted \(formatter.localizedString(for: createdAt, relativeTo: Date()))"
            }
            return "Posted nearby"
        }
    }

    private func handlePrimaryAction(for post: Post) {
        switch detail.context {
        case .pickedUp:
            onDismiss()
        case .nearby:
            guard isReserving == false else { return }
            isReserving = true
            Task { @MainActor in
                defer { isReserving = false }
                do {
                    _ = try await api.reservePost(post.id)
                    Haptics.play(.success)
                    var reserved = HiddenPostsStore.shared.loadReserved()
                    reserved.insert(post.id)
                    HiddenPostsStore.shared.saveReserved(reserved)
                    FeedViewModel.requestFeedRefresh()
                    NotificationCenter.default.post(name: .refreshReservations, object: nil)
                    onDismiss()
                    NotificationCenter.default.post(name: .pushRouteToTab, object: AppTab.reservations)
                } catch {
                    Haptics.play(.error)
                    DLog("[PUSH_ROUTE] reserve from push failed postId=\(post.id) error=\(error.localizedDescription)")
                    onDismiss()
                }
            }
        }
    }

    private var unavailableCard: some View {
        VStack(spacing: 16) {
            Image(systemName: detail.context == .pickedUp ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 44))
                .foregroundColor(primaryColor)

            Text(detail.context == .pickedUp
                 ? "Item picked up 🎉"
                 : "This item is no longer available")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)

            Text(detail.context == .pickedUp
                 ? "Your item found a new home. Thanks for sharing it!"
                 : "Someone may have beaten you to it — keep an eye out for the next one.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onDismiss) {
                Text("Close")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
            }
            .background(primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
    }
}
