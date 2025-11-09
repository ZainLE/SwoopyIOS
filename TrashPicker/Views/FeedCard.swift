//
//  FeedCard.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CloudKit
import CoreLocation
import UIKit // for UIImpactFeedbackGenerator
import Combine

struct FeedCard: View {
    // Injected from parent - can be either CKTrashItem or Post
    let item: Any
    @ObservedObject var deckState: DeckState
    let isActiveCard: Bool // Whether this is the active (top) card
    let isReserving: Bool
    let onPass: () -> Void
    let onReserve: () -> Void
    @Environment(AppRouter.self) private var router
#if DEBUG
    @Environment(\.feedDebugContext) private var feedDebugContext
#endif
    @ObservedObject private var locationService = LocationService.shared

    // Local UI state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var currentImageIndex = 0
    @State private var showDetailOverlay = false
    @State private var currentTime = Date() // For time remaining updates
    @State private var distanceText: String?
    
    // Timer for updating time remaining every 60 seconds
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // Card position relative to the deck
    private var isNextCard: Bool { !isActiveCard }
    private var shouldShowStaged: Bool { isNextCard && (isDragging || deckState.isAnimating) }

    // Layout
    private let chromeSidePadding: CGFloat = 16
    private var screenWidth: CGFloat { UIScreen.main.bounds.width }
    private var screenHeight: CGFloat { UIScreen.main.bounds.height }
    private var cardWidth: CGFloat { screenWidth - (chromeSidePadding * 2) }

    private let collapsedCardHeight: CGFloat = 476
    private let infoBarHeight: CGFloat = 90
    private let collapsedImageHeight: CGFloat = 360
    private let expandedImageHeight: CGFloat = 420
    private let cardRadius: CGFloat = 28

    // Dynamic heights
    private var imageHeight: CGFloat { collapsedImageHeight }
    private var cardHeight: CGFloat { collapsedCardHeight }

    // MARK: - Computed Properties for Both Item Types
    
    private var itemId: String {
        if let ckItem = item as? CKTrashItem {
            return String(describing: ckItem.id)
        } else if let post = item as? Post {
            return post.id
        }
        return ""
    }
    
    private var itemTitle: String {
        if let ckItem = item as? CKTrashItem {
            return ckItem.title
        } else if let post = item as? Post {
            return post.title
        }
        return ""
    }
    
    private var itemCondition: String? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.condition
        } else if let post = item as? Post {
            return post.condition.displayName
        }
        return nil
    }
    
    private var itemMode: String? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.mode
        } else if let post = item as? Post {
            return post.mode.rawValue
        }
        return nil
    }
    
    private var itemCreatedAt: Date? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.createdAt
        } else if let post = item as? Post {
            return post.createdAt
        }
        return nil
    }
    
    private var itemExpiresAt: Date? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.expiresAt
        } else if item is Post {
            return nil
        }
        return nil
    }
    
    private var itemDescription: String? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.desc
        } else if let post = item as? Post {
            return post.description
        }
        return nil
    }
    
    private var itemPrimaryImageURL: URL? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.photoURL
        } else if let post = item as? Post {
            return post.primaryImageURL
        }
        return nil
    }
    
    private var itemImageURLs: [URL] {
        if let ckItem = item as? CKTrashItem {
            return ckItem.photoURL.map { [$0] } ?? []
        } else if let post = item as? Post {
            return post.images.sorted { $0.orderIndex < $1.orderIndex }.map { $0.url }
        }
        return []
    }
    
    private var itemExactCoordinate: CLLocationCoordinate2D? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.coordinate
        } else if let post = item as? Post {
            return post.exactCoordinate
        }
        return nil
    }

    private var itemApproxCoordinate: CLLocationCoordinate2D? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.coordinate
        } else if let post = item as? Post {
            return post.approxCoordinate
        }
        return nil
    }
    
    private var itemOwnerName: String? {
        if let ckItem = item as? CKTrashItem {
            return nil // CKTrashItem doesn't have owner info
        } else if let post = item as? Post {
            return post.owner?.fullName
        }
        return nil
    }
    
    private var itemOwnerAvatarUrl: URL? {
        if let post = item as? Post {
            return post.owner?.avatarUrl
        }
        return nil
    }
    
    private var itemInterestedCount: Int? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.interestedCount
        } else if let post = item as? Post {
            return post.owner?.pickedCount
        }
        return nil
    }

    // MARK: - Computed Strings

    private var conditionDisplayText: String {
        let condition = itemCondition
        switch condition?.lowercased() {
        case "bad", "needs fixing", "needs_fixing":
            return "Needs fixing"
        case "good":
            return "Good"
        case "excellent", "like new", "like_new":
            return "Like new"
        default:
            return condition?.capitalized ?? "Unknown"
        }
    }

    private var distanceString: String {
        distanceText ?? fallbackDistanceString
    }

    private var fallbackDistanceString: String {
        // Use real distance from Post or deterministic fake for CKTrashItem
        if let post = item as? Post, let distance = post.distance {
            return String(format: "%.1f km away", distance)
        }
        
        // Deterministic "fake" distance for CKTrashItem until we wire real location logic
        let distances = ["0,3 km away", "0,8 km away", "1,2 km away", "1,5 km away", "2,1 km away"]
        let key = itemId
        let hash = abs(key.hashValue)
        return distances[hash % distances.count]
    }

    private var pickupCoordinate: CLLocationCoordinate2D? {
        if let post = item as? Post {
            return post.exactCoordinate ?? post.approxCoordinate
        }
        if let ckItem = item as? CKTrashItem {
            return ckItem.coordinate
        }
        return nil
    }

    private var postedAgoText: String? {
        guard let created = itemCreatedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: created, relativeTo: Date())
    }

    private var timeAgoString: String {
        postedAgoText ?? ""
    }
    
    private var expiresInText: String? {
        // For Post, use expiresAt (Date?)
        if let post = item as? Post {
            guard let exp = post.expiresAt else { return nil }
            let now = currentTime
            if exp <= now { return "expired" }
            
            let interval = exp.timeIntervalSince(now)
            if interval < 3600 {
                let mins = Int(interval / 60)
                return "expires in \(mins)m"
            } else if interval < 86400 {
                let hours = Int(interval / 3600)
                return "expires in \(hours)h"
            } else {
                let days = Int(interval / 86400)
                return "expires in \(days)d"
            }
        }
        
        // For CKTrashItem, use itemExpiresAt
        guard let exp = itemExpiresAt else { return nil }
        let now = currentTime
        if exp <= now { return "expired" }
        
        let interval = exp.timeIntervalSince(now)
        if interval < 3600 {
            let mins = Int(interval / 60)
            return "expires in \(mins)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "expires in \(hours)h"
        } else {
            let days = Int(interval / 86400)
            return "expires in \(days)d"
        }
    }
    
    private var feedPrimaryInfo: String {
        if itemMode?.lowercased() == "home" {
            return "From home (address hidden)"
        } else {
            return distanceString
        }
    }

    // MARK: - View

    var body: some View {
        ZStack(alignment: .top) {
            // Background white for info bar
            Color.white
            
            VStack(spacing: 0) {
                imageAreaView()
                    .frame(height: imageHeight)

                infoBarView()
                    .padding(.horizontal, chromeSidePadding)
                    .padding(.vertical, 16)
                    .frame(height: infoBarHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .onTapGesture { showDetailOverlay = true }
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: cardHeight)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: imageHeight)
        .offset(dragOffset)
        .rotationEffect(.degrees(Double(dragOffset.width / 18)))
        // Staged reveal animation for next card
        .opacity(isNextCard && !shouldShowStaged ? 0 : 1)
        .scaleEffect(isNextCard && !shouldShowStaged ? 0.98 : 1.0)
        .offset(y: isNextCard && !shouldShowStaged ? 10 : 0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: shouldShowStaged)
        .gesture(mainDragGesture())
#if DEBUG
        .onAppear { logDistanceDebug() }
        .onChange(of: feedDebugContext?.debugId ?? "") { _, _ in
            logDistanceDebug()
        }
#endif
        .onReceive(timer) { _ in currentTime = Date() }
        .overlay(reservingOverlayView())
        .fullScreenCover(isPresented: $showDetailOverlay) {
            expandedCardView()
        }
        .task {
            await refreshDistance(forceRefresh: true)
        }
        .onReceive(locationService.$lastFix) { _ in
            Task { await refreshDistance(forceRefresh: false) }
        }
    }

#if DEBUG
    private func logDistanceDebug() {
        guard let post = item as? Post,
              let context = feedDebugContext,
              let entry = context.entries.first(where: { $0.id == post.id }) else { return }
        let coordString = entry.coordinate.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "n/a"
        let serverString = entry.serverDistanceKm.map { String(format: "%.3f", $0) } ?? "nil"
        let localString = entry.localDistanceKm.map { String(format: "%.3f", $0) } ?? "nil"
        let source = entry.serverDistanceKm != nil ? "server" : "local"
        DLog("[DISTANCE UI] debugId=\(context.debugId) postId=\(post.id) coord=\(coordString) server=\(serverString)km ui=\(localString)km source=\(source)")
    }
#endif

    // MARK: - Sections

    @ViewBuilder
    private func imageAreaView() -> some View {
        ZStack {
            imageContentView()

            tapZonesView()
            pagerDotsView()
        }
        .frame(width: cardWidth, height: imageHeight)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: cardRadius, topTrailingRadius: cardRadius))
    }

    @ViewBuilder
    private func imageContentView() -> some View {
        let urls = itemImageURLs
        if let url = (urls.indices.contains(currentImageIndex) ? urls[currentImageIndex] : urls.first) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: imageHeight)
                        .clipped()
                default:
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .frame(width: cardWidth, height: imageHeight)
                }
            }
        } else {
            Rectangle()
                .fill(.secondary.opacity(0.15))
                .frame(width: cardWidth, height: imageHeight)
        }
    }

    @ViewBuilder
    private func tapZonesView() -> some View {
        HStack(spacing: 0) {
            // Left ~60% - previous photo (NO expand)
            Color.clear
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    previousPhoto()
                    // Do NOT expand
                }

            // Right 40% - next photo (NO expand)
            Color.clear
                .frame(width: cardWidth * 0.4)
                .contentShape(Rectangle())
                .onTapGesture {
                    nextPhoto()
                    // Do NOT expand
                }
        }
    }

    @ViewBuilder
    private func pagerDotsView() -> some View {
        VStack {
            Spacer()
            let count = itemImageURLs.count
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(index == currentImageIndex ? AppTheme.ColorToken.accent : AppTheme.ColorToken.accent.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom,16)
        }
    }

    @ViewBuilder
    private func infoBarView() -> some View {
        HStack {
            // Left side
            VStack(alignment: .leading, spacing: 4) {
                if itemMode?.lowercased() == "home" {
                    Text("From home (address hidden)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                } else {
                    Text(distanceString)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                }

                if let posted = postedAgoText {
                    Text("Posted \(posted)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color(hex: "#00513F"))
                }
            }

            Spacer()

            // Right pill - light green background with dark green text
            Text(conditionDisplayText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "#00513F"))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color(hex: "#B4DD4E"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("Condition: \(conditionDisplayText)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the info bar expands the card
            showDetailOverlay = true
        }
    }

    // MARK: - Gestures

    private func mainDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard isActiveCard && deckState.canAct && !showDetailOverlay && !isReserving else { return }
                let wasDragging = isDragging
                isDragging = abs(value.translation.width) > 6 || abs(value.translation.height) > 6
                dragOffset = value.translation
                if !wasDragging && isDragging {
                    // reveal animation handled by .animation modifier
                }
            }
            .onEnded { value in
                guard isActiveCard && deckState.canAct && !showDetailOverlay && !isReserving else { return }
                isDragging = false
                let threshold: CGFloat = 115

                if value.translation.width > threshold {
                    onReserve()
                    withAnimation(.easeOut(duration: 0.3)) {
                        dragOffset = CGSize(width: cardWidth + 100, height: 0)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        dragOffset = .zero
                    }
                } else if value.translation.width < -threshold {
                    onPass()
                    withAnimation(.easeOut(duration: 0.3)) {
                        dragOffset = CGSize(width: -(cardWidth + 100), height: 0)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        dragOffset = .zero
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func reservingOverlayView() -> some View {
        Group {
            if isReserving && isActiveCard {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.9)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(.trailing, 16)
                            .padding(.top, 16)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func detailOverlayView() -> some View {
        // Empty - overlay is now handled at parent level
        EmptyView()
    }
    
    @ViewBuilder
    private func expandedCardView() -> some View {
        ZStack {
            // Backdrop with blur effect
            Color.black.opacity(0.25)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .blur(radius: 10)
                .onTapGesture { showDetailOverlay = false }
            
            // Big card overlay
            BigCardOverlay(
                postID: itemId,
                images: itemImageURLs.map { $0.absoluteString },
                primaryInfo: feedPrimaryInfo,
                statusInfo: timeAgoString.isEmpty ? "" : "Posted \(timeAgoString)",
                statusColor: Color(hex: "#00513F"),
                description: itemDescription,
                mode: itemMode?.lowercased() == "street" ? .street : .home,
                exactCoordinate: itemExactCoordinate,
                approxCoordinate: itemApproxCoordinate,
                ownerName: itemOwnerName ?? "Anonymous User",
                ownerAvatarUrl: itemOwnerAvatarUrl,
                memberSince: itemCreatedAt,
                pickupsCount: itemInterestedCount,
                variant: .feed,
                onDismiss: {
                    showDetailOverlay = false
                },
                onPrimaryAction: {
                    showDetailOverlay = false
                    onReserve()
                },
                onSecondaryAction: {
                    showDetailOverlay = false
                    onPass()
                },
                onTertiaryAction: nil
            )
        }
    }
    
    // MARK: - Actions
    // Actions are now handled by parent SwipeDeckView

    // MARK: - Expansion / Photos

    private func nextPhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let count = itemImageURLs.count
        guard count > 0 else { return }
        currentImageIndex = (currentImageIndex + 1) % count
    }

    private func previousPhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let count = itemImageURLs.count
        guard count > 0 else { return }
        currentImageIndex = currentImageIndex == 0 ? (count - 1) : (currentImageIndex - 1)
    }

    private func advancePhoto() { nextPhoto() }

    private func refreshDistance(forceRefresh: Bool) async {
        guard let coordinate = pickupCoordinate else {
            await MainActor.run { distanceText = nil }
            return
        }

        var userCoordinate: CLLocationCoordinate2D?
        if forceRefresh {
            if let fresh = try? await LocationService.shared.currentCoordinate() {
                userCoordinate = fresh
            }
        }

        if userCoordinate == nil {
            userCoordinate = locationService.lastFix?.coordinate ?? LocationService.shared.lastKnownCoordinate
        }

        guard let userCoordinate else {
            await MainActor.run { distanceText = nil }
            return
        }

        let formatted = DistanceFormatterHelper.formattedDistance(from: userCoordinate, to: coordinate)
        await MainActor.run {
            distanceText = formatted
        }
    }

}
