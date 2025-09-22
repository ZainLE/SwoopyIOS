//
//  FeedCard.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CloudKit
import CoreLocation
import UIKit // for UIImpactFeedbackGenerator

struct FeedCard: View {
    // Injected from parent
    let item: CKTrashItem
    @ObservedObject var deckState: DeckState
    let isActiveCard: Bool // Whether this is the active (top) card

    // Local UI state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var currentImageIndex = 0
    @State private var isExpanded = false

    // Card position relative to the deck
    private var isNextCard: Bool { !isActiveCard }
    private var shouldShowStaged: Bool { isNextCard && (isDragging || deckState.isAnimating) }

    // Design tokens
    private let primary = Color(hex: 0x00513F)      // #00513F
    private let accent = Color(hex: 0xB4DD4E)       // #B4DD4E
    private let mutedText = Color(hex: 0x656565)    // #656565

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
    private var imageHeight: CGFloat { isExpanded ? expandedImageHeight : collapsedImageHeight }
    private var expandedContentHeight: CGFloat {
        let descriptionLines = (item.desc?.count ?? 0) / 40 + 1
        return CGFloat(max(descriptionLines * 20 + 60, 100))
    }
    private var cardHeight: CGFloat {
        if isExpanded {
            let contentHeight = expandedImageHeight + infoBarHeight + expandedContentHeight + 32
            let maxHeight = screenHeight - 200
            return min(contentHeight, maxHeight)
        }
        return collapsedCardHeight
    }

    // MARK: - Computed Strings

    private var conditionDisplayText: String {
        let condition = item.condition
        switch condition?.lowercased() {
        case "needs fixing", "needs_fixing": return "Needs Fixing"
        case "usable": return "Usable"
        case "good": return "Good"
        case "like new", "like_new": return "Like New"
        default: return condition?.capitalized ?? "Unknown"
        }
    }

    private var distanceString: String {
        // Deterministic "fake" distance until we wire real location logic
        let distances = ["0,3 km away", "0,8 km away", "1,2 km away", "1,5 km away", "2,1 km away"]
        let key = String(describing: item.id) // Works for UUID/CKRecord.ID/etc.
        let hash = abs(key.hashValue)
        return distances[hash % distances.count]
    }

    private var timeAgoString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            // IMAGE AREA
            ZStack {
                if let url = item.photoURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.secondary.opacity(0.15))
                    }
                    .frame(width: cardWidth, height: imageHeight)
                    .offset(y: -5)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .frame(width: cardWidth, height: imageHeight)
                        .offset(y: -5)
                }

                // Invisible tap zones for image paging
                HStack(spacing: 0) {
                    // Left 40% - previous photo
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: cardWidth * 0.4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            previousPhoto()
                            if !isExpanded { expandCard() }
                        }

                    // Middle 20% - just expand
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: cardWidth * 0.2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isExpanded { expandCard() }
                        }

                    // Right 40% - next photo
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: cardWidth * 0.4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            nextPhoto()
                            if !isExpanded { expandCard() }
                        }
                }

                // Pager dots
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index == currentImageIndex ? primary : primary.opacity(0.35))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            .frame(height: imageHeight)
            .clipped()

            // INFO BAR
            HStack {
                // Left side
                VStack(alignment: .leading, spacing: 4) {
                    if item.mode?.lowercased() == "home" {
                        Text("From home (address hidden)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                    } else {
                        Text(distanceString)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    Text("Posted \(timeAgoString)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(mutedText)
                }

                Spacer()

                // Right pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)

                    Text(conditionDisplayText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(primary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("Condition: \(conditionDisplayText)")
            }
            .padding(.horizontal, chromeSidePadding)
            .padding(.vertical, 16)
            .frame(height: infoBarHeight)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .onTapGesture { toggleExpansion() }

            // EXPANDED CONTENT
            if isExpanded {
                FeedCardExpandedContent(item: item)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .background(Color.white)
                    .opacity(isExpanded ? 1 : 0)
                    .offset(y: isExpanded ? 0 : 12)
                    .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isExpanded)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(Color.white)
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
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in }
                .onEnded { _ in }
        )
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard isActiveCard && deckState.canAct else { return }
                    let wasDragging = isDragging
                    isDragging = abs(value.translation.width) > 6 || abs(value.translation.height) > 6
                    dragOffset = value.translation

                    if !wasDragging && isDragging {
                        // reveal animation handled by .animation modifier
                    }
                }
                .onEnded { value in
                    guard isActiveCard && deckState.canAct else { return }
                    isDragging = false
                    let threshold: CGFloat = 115

                    if value.translation.width > threshold {
                        Task { await triggerReserve() }
                    } else if value.translation.width < -threshold {
                        Task { await triggerPass() }
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
    }

    // MARK: - Actions

    @MainActor
    private func triggerReserve() async {
        do {
            try await deckState.triggerReserve()
            withAnimation(.easeOut(duration: 0.3)) {
                dragOffset = CGSize(width: cardWidth + 100, height: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                deckState.completeCardTransition()
                dragOffset = .zero
            }
        } catch {
            // DeckState handles error reporting/logging
        }
    }

    @MainActor
    private func triggerPass() async {
        await deckState.triggerPass()
        withAnimation(.easeOut(duration: 0.3)) {
            dragOffset = CGSize(width: -(cardWidth + 100), height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            deckState.completeCardTransition()
            dragOffset = .zero
        }
    }

    // MARK: - Expansion / Photos

    private func nextPhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        currentImageIndex = (currentImageIndex + 1) % 3
    }

    private func previousPhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        currentImageIndex = currentImageIndex == 0 ? 2 : currentImageIndex - 1
    }

    private func advancePhoto() { nextPhoto() }

    private func expandCard() {
        guard !isExpanded else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            isExpanded = true
        }
    }

    private func toggleExpansion() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            isExpanded.toggle()
        }
    }
}

// MARK: - Expanded Content (renamed to avoid conflicts)
struct FeedCardExpandedContent: View {
    let item: CKTrashItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.title)
                .font(.title2)
                .fontWeight(.bold)

            if let description = item.desc, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Category")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.category.capitalized) // non-optional
                        .font(.body)
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("Interested")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(item.interestedCount ?? 0) people")
                        .font(.body)
                }
            }
        }
    }
}

//
//#Preview {
//    // Mock CKTrashItem for preview — CKTrashItem.id is CKRecord.ID
//    let mockItem = CKTrashItem(
//        id: CKRecord.ID(UUID().uuidString),
//        title: "Preview Item",
//        category: "furniture",
//        photoURL: URL(string: "https://picsum.photos/400/400"),
//        coordinate: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
//        city: "Barcelona",
//        createdAt: Date().addingTimeInterval(-3600), // 1 hour ago
//        expiresAt: Date().addingTimeInterval(86400), // 24 hours from now
//        status: "open",
//        reservedUntil: nil,
//        reservedBy: nil,
//        uploader: nil,
//        pickedUpAt: nil,
//        interestedCount: 3,
//        desc: "A nice piece of furniture that would look great in any home.",
//        condition: "good",
//        mode: "street"
//    )
//
//    FeedCard(
//        item: mockItem,
//        deckState: DeckState(),
//        isActiveCard: true
//    )
//    .padding()
//}

