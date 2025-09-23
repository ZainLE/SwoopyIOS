//
//  BigCardOverlay.swift
//  TrashPicker
//
//  Unified big card overlay component for both Reservations and Feed expansions
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - BigCardOverlay

struct BigCardOverlay: View {
    // Content data
    let images: [String]
    let primaryInfo: String
    let statusInfo: String
    let statusColor: Color
    let description: String?
    let mode: LocationMode
    let exactLocation: CLLocationCoordinate2D?
    let ownerName: String
    let memberSince: Date?
    let pickupsCount: Int?
    let variant: Variant
    
    // Actions
    let onDismiss: () -> Void
    let onPrimaryAction: () -> Void
    let onSecondaryAction: () -> Void
    let onTertiaryAction: (() -> Void)?
    
    // State
    @State private var currentImageIndex = 0
    @State private var dragOffset: CGSize = .zero
    @Namespace private var imageTransition
    
    // Design tokens
    private let overlayScale: CGFloat = 0.90
    private let primaryColor = Color(hex: "00513F")
    private let accentColor = Color(hex: "B4DD4E")
    private let mutedColor = Color(hex: "656565")
    private let dangerColor = Color(hex: "C44242")
    private let successColor = Color(hex: "6AA54A")
    
    enum LocationMode {
        case street
        case home
    }
    
    enum Variant {
        case reservations(ReservationButtonSet)
        case feed
        
        enum ReservationButtonSet {
            case streetActive // Pick up, Cancel, Directions
            case homePending  // Contact (disabled), Cancel
            case homeActive   // Contact, Cancel
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(geometry.size.width * overlayScale, 600)
            let cardHeight = geometry.size.height * overlayScale
            let imageHeight: CGFloat = geometry.size.height > 800 ? 400 : 360
            
            VStack(spacing: 0) {
                // Image carousel - edge to edge with card radius on top
                imageCarousel(height: imageHeight)
                
                // Content area - scrollable
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Meta block
                        metaSection
                        
                        // Optional description
                        if let description = description, !description.isEmpty {
                            descriptionSection(description)
                        }
                        
                        // Location section
                        locationSection
                        
                        // Shared by section
                        sharedBySection
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                
                // Buttons row - pinned to bottom
                buttonsSection
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
            .offset(y: dragOffset.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = value.translation
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 120 {
                            onDismiss()
                        } else {
                            withAnimation(.spring()) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
            .overlay(
                // Close button
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(primaryColor)
                                .frame(width: 36, height: 36)
                                .background(primaryColor.opacity(0.12), in: Circle())
                        }
                        .padding(.top, 18)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
            )
        }
    }
}

// MARK: - BigCardOverlay Extensions

extension BigCardOverlay {
    
    // MARK: - Image Carousel
    
    @ViewBuilder
    private func imageCarousel(height: CGFloat) -> some View {
        ZStack {
            TabView(selection: $currentImageIndex) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, imageUrl in
                    AsyncImage(url: URL(string: imageUrl)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                    }
                    .tag(index)
                }
            }
            .frame(height: height)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 28
                )
            )
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            
            // Custom dots
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<images.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentImageIndex ? primaryColor : primaryColor.opacity(0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 16)
            }
            
            // Tap zones
            HStack(spacing: 0) {
                // Left 40% - previous
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        if currentImageIndex > 0 {
                            withAnimation {
                                currentImageIndex -= 1
                            }
                        } else {
                            // Wrap to last
                            withAnimation {
                                currentImageIndex = images.count - 1
                            }
                        }
                    }
                
                // Middle 20% - no-op
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: height * 0.2)
                
                // Right 40% - next
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        if currentImageIndex < images.count - 1 {
                            withAnimation {
                                currentImageIndex += 1
                            }
                        } else {
                            // Wrap to first
                            withAnimation {
                                currentImageIndex = 0
                            }
                        }
                    }
            }
        }
    }
    
    // MARK: - Meta Section
    
    @ViewBuilder
    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Line 1: Distance/Mode info (16pt Semibold)
            Text(primaryInfo)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            // Line 2: Status info (12pt)
            Text(statusInfo)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(statusColor)
        }
    }
    
    // MARK: - Description Section
    
    @ViewBuilder
    private func descriptionSection(_ description: String) -> some View {
        Text(description)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Location Section
    
    @ViewBuilder
    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            switch mode {
            case .street:
                if let coordinate = exactLocation {
                    VStack(alignment: .leading, spacing: 8) {
                        // Map snapshot placeholder
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 120)
                            .overlay(
                                VStack {
                                    Image(systemName: "map")
                                        .font(.system(size: 24))
                                        .foregroundColor(.secondary)
                                    Text("Map Preview")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            )
                        
                        Text("Lat: \(coordinate.latitude, specifier: "%.4f"), Lng: \(coordinate.longitude, specifier: "%.4f")")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
            case .home:
                Text("Home listings keep addresses private. You'll get a location and confirm details directly from the owner.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - Shared By Section
    
    @ViewBuilder
    private var sharedBySection: some View {
        HStack(spacing: 12) {
            // Avatar
            RoundedRectangle(cornerRadius: 8)
                .fill(primaryColor.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(ownerName.prefix(1)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(ownerName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                
                if let memberSince = memberSince {
                    Text("Member since \(formatMemberSince(memberSince))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if let pickupsCount = pickupsCount {
                Text("\(pickupsCount) Pickups")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(primaryColor)
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - Buttons Section
    
    @ViewBuilder
    private var buttonsSection: some View {
        switch variant {
        case .reservations(let buttonSet):
            reservationButtons(buttonSet)
        case .feed:
            feedButtons
        }
    }
    
    @ViewBuilder
    private func reservationButtons(_ buttonSet: Variant.ReservationButtonSet) -> some View {
        switch buttonSet {
        case .streetActive:
            HStack(spacing: 12) {
                Button(action: onPrimaryAction) {
                    Text("Pick up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                
                Button(action: onSecondaryAction) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(primaryColor, lineWidth: 2)
                )
                
                if let tertiaryAction = onTertiaryAction {
                    Button(action: tertiaryAction) {
                        Text("Directions")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(primaryColor)
                            .frame(height: 52)
                            .frame(maxWidth: .infinity)
                    }
                    .background(accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                }
            }
            
        case .homePending:
            HStack(spacing: 12) {
                Button(action: onPrimaryAction) {
                    Text("Contact")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(true)
                
                Button(action: onSecondaryAction) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(primaryColor, lineWidth: 2)
                )
            }
            
        case .homeActive:
            HStack(spacing: 12) {
                Button(action: onPrimaryAction) {
                    Text("Contact")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                
                Button(action: onSecondaryAction) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(primaryColor, lineWidth: 2)
                )
            }
        }
    }
    
    @ViewBuilder
    private var feedButtons: some View {
        HStack(spacing: 12) {
            Button(action: onPrimaryAction) {
                Text("Save for me")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
            }
            .background(primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            
            Button(action: onSecondaryAction) {
                Text("Pass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryColor)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
            }
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(primaryColor, lineWidth: 2)
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatMemberSince(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
