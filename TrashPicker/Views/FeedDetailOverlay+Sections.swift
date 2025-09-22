import SwiftUI
import MapKit
import CoreLocation

// MARK: - FeedDetailOverlay Extensions

extension FeedDetailOverlay {
    
    // MARK: - Image Carousel
    
    @ViewBuilder
    var imageCarousel: some View {
        let imageHeight: CGFloat = UIScreen.main.bounds.height > 800 ? 400 : 360
        
        ZStack {
            TabView(selection: $currentImageIndex) {
                ForEach(0..<3, id: \.self) { index in
                    AsyncImage(url: item.photoURL) { image in
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
            .frame(height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .matchedGeometryEffect(id: "image-\(item.id)", in: imageTransition)
            
            // Custom dots
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == currentImageIndex ? primaryColor : primaryColor.opacity(0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 16)
            }
            
            // Tap zones
            HStack {
                // Left 40%
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        if currentImageIndex > 0 {
                            withAnimation {
                                currentImageIndex -= 1
                            }
                        }
                    }
                
                // Center 20% (no-op)
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: imageHeight * 0.2)
                
                // Right 40%
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        if currentImageIndex < 2 {
                            withAnimation {
                                currentImageIndex += 1
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, 24) // Match content padding for alignment
        .padding(.top, 20)
    }
    
    // MARK: - Meta Section
    
    @ViewBuilder
    var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Line 1: Distance/Mode info (16pt Semibold per spec)
            Text(primaryInfoText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            // Line 2: Posted time (12pt Regular per spec)
            Text("Posted \(formatRelativeTime(item.createdAt)) ago")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(mutedColor)
        }
    }
    
    // MARK: - Description Section
    
    @ViewBuilder
    func descriptionSection(_ description: String) -> some View {
        Text(description)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Location Section
    
    @ViewBuilder
    var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            switch item.mode?.lowercased() {
            case "street":
                VStack(alignment: .leading, spacing: 8) {
                    // Simple map placeholder
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
                    
                    Text("Lat: \(item.coordinate.latitude, specifier: "%.4f"), Lng: \(item.coordinate.longitude, specifier: "%.4f")")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
            case "home":
                Text("Home listings keep addresses private. You'll get a location and confirm details directly from the owner.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                
            default:
                Text("Location information not available")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(mutedColor)
            }
        }
    }
    
    // MARK: - Shared By Section
    
    @ViewBuilder
    var sharedBySection: some View {
        HStack(spacing: 12) {
            // Avatar
            RoundedRectangle(cornerRadius: 8)
                .fill(primaryColor.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Text("U") // Placeholder since CKTrashItem doesn't have owner name
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Anonymous User")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("Member since \(formatMemberSince(item.createdAt))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("\(item.interestedCount) Interested")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(primaryColor)
                .clipShape(Capsule())
        }
    }
    
    // MARK: - Buttons Section
    
    @ViewBuilder
    var buttonsSection: some View {
        HStack(spacing: 12) {
            Button(action: onSave) {
                Text("Save for me")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
            }
            .background(primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            
            Button(action: onPass) {
                Text("Pass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryColor)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 26))
        }
    }
    
    // MARK: - Computed Properties
    
    var primaryInfoText: String {
        switch item.mode?.lowercased() {
        case "street":
            // Use deterministic fake distance like in FeedCard
            let distances = ["0.3 km away", "0.8 km away", "1.2 km away", "1.5 km away", "2.1 km away"]
            let key = String(describing: item.id)
            let hash = abs(key.hashValue)
            return distances[hash % distances.count]
        case "home":
            return "From home (address hidden)"
        default:
            return "Location unknown"
        }
    }
    
    // MARK: - Helper Methods
    
    func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    func formatMemberSince(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
}
