import SwiftUI

// MARK: - ReservationDetailOverlay Extensions

extension ReservationDetailOverlay {
    
    // MARK: - Image Carousel
    
    @ViewBuilder
    var imageCarousel: some View {
        let imageHeight: CGFloat = UIScreen.main.bounds.height > 800 ? 400 : 360
        
        ZStack {
            TabView(selection: $currentImageIndex) {
                ForEach(Array(reservation.post.images.enumerated()), id: \.offset) { index, image in
                    AsyncImage(url: URL(string: image.url)) { image in
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
            .matchedGeometryEffect(id: "image-\(reservation.id)", in: imageTransition)
            
            // Custom dots
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<reservation.post.images.count, id: \.self) { index in
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
                        if currentImageIndex < reservation.post.images.count - 1 {
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
            Text("Posted \(formatRelativeTime(reservation.reservation.requestedAt)) ago")
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
            Text("Exact Location")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            switch reservation.post.mode {
            case .street:
                if let exactLocation = reservation.post.exactLocation {
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
                        
                        Text("Lat: \(exactLocation.lat, specifier: "%.4f"), Lng: \(exactLocation.lng, specifier: "%.4f")")
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
    var sharedBySection: some View {
        HStack(spacing: 12) {
            // Avatar
            RoundedRectangle(cornerRadius: 8)
                .fill(primaryColor.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(reservation.post.owner.name.prefix(1)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(reservation.post.owner.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                
                if let memberSince = reservation.post.owner.memberSince {
                    Text("Member since \(formatMemberSince(memberSince))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if let pickupsCount = reservation.post.owner.pickupsCount {
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
    var buttonsSection: some View {
        switch (reservation.post.mode, reservation.reservation.status) {
        case (.street, .active):
            HStack(spacing: 12) {
                Button(action: onPickUp) {
                    Text("Pick up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(dangerColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
                
                Button(action: onDirections) {
                    Text("Directions")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
            }
            
        case (.home, .pending):
            HStack(spacing: 12) {
                Button(action: onContact) {
                    Text("Contact")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(true)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(dangerColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
            }
            
        case (.home, .active):
            HStack(spacing: 12) {
                Button(action: onContact) {
                    Text("Contact")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
                
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(dangerColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1.0)
            }
            
        default:
            EmptyView()
        }
    }
    
    // MARK: - Computed Properties
    
    var primaryInfoText: String {
        switch reservation.post.mode {
        case .street:
            if let distance = reservation.post.distanceKm {
                return String(format: "≈ %.1f km away", distance)
            } else {
                return "Street pickup"
            }
        case .home:
            return "From home (address hidden)"
        }
    }
    
    var primaryColor: Color { Color(hex: "00513F") }
    var accentColor: Color { Color(hex: "B4DD4E") }
    var dangerColor: Color { Color(hex: "C44242") }
    var mutedColor: Color { Color(hex: "656565") }
    
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

