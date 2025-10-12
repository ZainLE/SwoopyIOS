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

    // Local UI state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var currentImageIndex = 0
    @State private var showDetailOverlay = false
    @State private var currentTime = Date() // For time remaining updates
    
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
            return post.condition.rawValue
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
    
    private var itemCoordinate: CLLocationCoordinate2D? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.coordinate
        } else if let post = item as? Post {
            // For Post, we need to construct coordinate from exactLocation or approxLocation
            if let exact = post.exactLocation, 
               let lat = Double(exact.lat ?? ""), 
               let lng = Double(exact.lng ?? "") {
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            } else if let approx = post.approxLocation,
                      let lat = Double(approx.lat ?? ""),
                      let lng = Double(approx.lng ?? "") {
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
        }
        return nil
    }
    
    private var itemOwnerName: String? {
        if let ckItem = item as? CKTrashItem {
            return nil // CKTrashItem doesn't have owner info
        } else if let post = item as? Post {
            return post.owner?.firstName
        }
        return nil
    }
    
    private var itemInterestedCount: Int? {
        if let ckItem = item as? CKTrashItem {
            return ckItem.interestedCount
        } else if let post = item as? Post {
            return nil // Post doesn't have interested count
        }
        return nil
    }

    // MARK: - Computed Strings

    private var conditionDisplayText: String {
        let condition = itemCondition
        switch condition?.lowercased() {
        case "bad", "needs fixing", "needs_fixing": return "Needs Fixing"
        case "usable": return "Usable"
        case "good": return "Good"
        case "excellent", "like new", "like_new": return "Like New"
        default: return condition?.capitalized ?? "Unknown"
        }
    }

    private var distanceString: String {
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
        .onReceive(timer) { _ in currentTime = Date() }
        .overlay(reservingOverlayView())
        .overlay(detailOverlayView())
    }

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
            // Left 40% - previous photo
            Color.clear
                .frame(width: cardWidth * 0.4)
                .contentShape(Rectangle())
                .onTapGesture {
                    previousPhoto()
                    showDetailOverlay = true
                }

            // Middle 20% - expand
            Color.clear
                .frame(width: cardWidth * 0.2)
                .contentShape(Rectangle())
                .onTapGesture { showDetailOverlay = true }

            // Right 40% - next photo
            Color.clear
                .frame(width: cardWidth * 0.4)
                .contentShape(Rectangle())
                .onTapGesture {
                    nextPhoto()
                    showDetailOverlay = true
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
                        .fill(index == currentImageIndex ? AppTheme.ColorToken.primary : AppTheme.ColorToken.primary.opacity(0.35))
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
        Group {
            if showDetailOverlay {
                ZStack {
                    // Backdrop
                    Color.black.opacity(0.35)
                        .ignoresSafeArea(.all)
                        .onTapGesture { showDetailOverlay = false }
                        .zIndex(1)

                    // Big card overlay
                    BigCardOverlay(
                        images: itemImageURLs.map { $0.absoluteString },
                        primaryInfo: feedPrimaryInfo,
                        statusInfo: timeAgoString.isEmpty ? "" : "Posted \(timeAgoString)",
                        statusColor: AppTheme.ColorToken.mutedGray,
                        description: itemDescription,
                        mode: itemMode?.lowercased() == "street" ? .street : .home,
                        exactLocation: itemCoordinate,
                        ownerName: itemOwnerName ?? "Anonymous User",
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
                    .zIndex(2)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDetailOverlay)
            }
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

}
