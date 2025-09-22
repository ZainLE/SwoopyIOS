//
//  FeedCard.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CloudKit

struct FeedCard: View {
    let item: CKTrashItem
    let onReserve: () -> Void
    let onPass: () -> Void
    let isTopCard: Bool // New parameter to control button visibility
    
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    
    // Design tokens
    private let brandDark = Color(red: 0/255, green: 81/255, blue: 63/255)
    private let brandLime = Color(red: 180/255, green: 221/255, blue: 78/255)
    
    // Card dimensions
    private let cardWidth: CGFloat = 353
    private let cardHeight: CGFloat = 476
    private let imageHeight: CGFloat = 460 // Increased to cover ~97% of card
    private let cornerRadius: CGFloat = 28
    
    var body: some View {
        VStack(spacing: 16) {
            // Card with image and overlays
            ZStack {
                // Card background
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.systemBackground))
                    .frame(width: cardWidth, height: cardHeight)
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 6)
                
                ZStack {
                    // Main image covering almost entire card
                    if let url = item.photoURL {
                        DownsampledImage(url: url, maxDimension: max(cardWidth, imageHeight))
                            .scaledToFill()
                            .frame(width: cardWidth, height: imageHeight)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(.secondary.opacity(0.15))
                            .frame(width: cardWidth, height: imageHeight)
                    }
                    
                    // Overlay content at bottom
                    VStack {
                        Spacer()
                        
                        // Bottom content with gradient background
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                // Distance and condition on same line
                                if let distanceText = distanceString {
                                    Text(distanceText)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                
                                Spacer()
                                
                                // Condition pill aligned with distance
                                Text(conditionDisplayText)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(brandDark)
                                    .frame(width: 64, height: 30)
                                    .background(brandLime)
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                    .accessibilityLabel("Condition: \(conditionDisplayText)")
                            }
                            
                            // Posted time line
                            Text("Posted \(timeAgoString)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color.clear, Color.black.opacity(0.6)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
            .frame(width: cardWidth, height: cardHeight)
            .offset(dragOffset)
            .rotationEffect(.degrees(Double(dragOffset.width / 18)))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        isDragging = true
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        isDragging = false
                        let threshold: CGFloat = 115
                        
                        if value.translation.width > threshold {
                            // Right swipe - Reserve
                            performReserve()
                        } else if value.translation.width < -threshold {
                            // Left swipe - Pass
                            performPass()
                        } else {
                            // Snap back
                            withAnimation(.easeOut(duration: 0.18)) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
            
            // Buttons below card - only show for top card
            if isTopCard {
                HStack(spacing: 16) {
                    // Pass button (left)
                    Button(action: performPass) {
                        Text("Pass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                    }
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 59)
                            .stroke(brandDark, lineWidth: 3)
                    )
                    .accessibilityLabel("Pass on this item")
                    
                    // Save for Me button (right)
                    Button(action: performReserve) {
                        Text("Save for Me")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                    }
                    .background(brandDark)
                    .clipShape(RoundedRectangle(cornerRadius: 59))
                    .accessibilityLabel("Save this item for me")
                }
                .frame(width: cardWidth)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var conditionDisplayText: String {
        guard let condition = item.condition else { return "Unknown" }
        
        switch condition.lowercased() {
        case "needs fixing", "needs_fixing":
            return "Needs Fixing"
        case "usable":
            return "Usable"
        case "good":
            return "Good"
        case "like new", "like_new":
            return "Like New"
        default:
            return condition.capitalized
        }
    }
    
    private var distanceString: String? {
        // This would typically come from a computed distance based on user location
        // For now, generate a realistic distance based on the item's city
        let distances = ["0,3 km away", "0,8 km away", "1,2 km away", "1,5 km away", "2,1 km away"]
        let hash = abs(item.id.uuid.hashValue)
        return distances[hash % distances.count]
    }
    
    private var timeAgoString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }
    
    // MARK: - Actions
    
    private func performReserve() {
        // Medium haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Animate card off to the right
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = CGSize(width: 900, height: 0)
        }
        
        // Call the reserve callback after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onReserve()
        }
    }
    
    private func performPass() {
        // Light haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        // Animate card off to the left
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = CGSize(width: -900, height: 0)
        }
        
        // Call the pass callback after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onPass()
        }
    }
}

#Preview {
    // Mock CKTrashItem for preview
    let mockItem = CKTrashItem(
        id: CKRecord.ID(UUID()),
        title: "Preview Item",
        category: "furniture",
        photoURL: URL(string: "https://picsum.photos/400/400"),
        coordinate: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
        city: "Barcelona",
        createdAt: Date().addingTimeInterval(-3600), // 1 hour ago
        expiresAt: Date().addingTimeInterval(86400), // 24 hours from now
        status: "open",
        reservedUntil: nil,
        reservedBy: nil,
        uploader: nil,
        pickedUpAt: nil,
        interestedCount: 3,
        desc: "A nice piece of furniture",
        condition: "good"
    )
    
    FeedCard(
        item: mockItem,
        onReserve: { print("Reserved") },
        onPass: { print("Passed") },
        isTopCard: true
    )
    .padding()
}

