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
    @EnvironmentObject private var api: ApiService
    // Content data
    let postID: String?
    let images: [String]
    let primaryInfo: String
    let statusInfo: String
    let statusColor: Color
    let description: String?
    let mode: LocationMode
    let exactLocation: CLLocationCoordinate2D?
    let ownerName: String
    let ownerAvatarUrl: URL?
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
    @StateObject private var locationViewModel: LocationDescriptionViewModel
    @State private var isReportPostSheetPresented = false
    @State private var isReportPostSuccessVisible = false
    @State private var reportSuccessTask: Task<Void, Never>? = nil

    // Design tokens
    private let overlayScale: CGFloat = 0.90
    private let primaryColor = Color(hex: "00513F")
    private let accentColor = Color(hex: "B4DD4E")
    private let mutedColor = Color(hex: "656565")
    private let dangerColor = Color(hex: "C44242")
    private let successColor = Color(hex: "6AA54A")
    private let reportToastDuration: UInt64 = 2_500_000_000

    private let reportPostReasons: [ReportPostReason] = [
        ReportPostReason(id: "spam", title: "Spam or misleading", category: .spam),
        ReportPostReason(id: "illegal", title: "Illegal or unsafe", category: .illegal),
        ReportPostReason(id: "inappropriate", title: "Inappropriate content", category: .inappropriate)
    ]
    
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
            case completed    // No actions, success message
        }
    }
    
    init(
        postID: String?,
        images: [String],
        primaryInfo: String,
        statusInfo: String,
        statusColor: Color,
        description: String?,
        mode: LocationMode,
        exactLocation: CLLocationCoordinate2D?,
        ownerName: String,
        ownerAvatarUrl: URL?,
        memberSince: Date?,
        pickupsCount: Int?,
        variant: Variant,
        onDismiss: @escaping () -> Void,
        onPrimaryAction: @escaping () -> Void,
        onSecondaryAction: @escaping () -> Void,
        onTertiaryAction: (() -> Void)?
    ) {
        self.postID = postID
        self.images = images
        self.primaryInfo = primaryInfo
        self.statusInfo = statusInfo
        self.statusColor = statusColor
        self.description = description
        self.mode = mode
        self.exactLocation = exactLocation
        self.ownerName = ownerName
        self.ownerAvatarUrl = ownerAvatarUrl
        self.memberSince = memberSince
        self.pickupsCount = pickupsCount
        self.variant = variant
        self.onDismiss = onDismiss
        self.onPrimaryAction = onPrimaryAction
        self.onSecondaryAction = onSecondaryAction
        self.onTertiaryAction = onTertiaryAction
        _locationViewModel = StateObject(wrappedValue: LocationDescriptionViewModel(postID: postID, coordinate: exactLocation, mode: mode))
    }

    var body: some View {
        GeometryReader { outerGeometry in
            let cardWidth = min(outerGeometry.size.width * 0.92, 600)
            let isSmall = outerGeometry.size.height < 700
            let cardHeight = outerGeometry.size.height * (isSmall ? 0.82 : 0.85)
            
            // Exact 50/50 split for image/details
            GeometryReader { innerGeometry in
                let imageHeight = floor(innerGeometry.size.height * 0.5)
                let detailsHeight = innerGeometry.size.height - imageHeight
                
                VStack(spacing: 0) {
                    // Image carousel - non-cropping, rounded top corners
                    imageCarousel(height: imageHeight)
                        .frame(height: imageHeight)
                    
                    // Content area - NOT scrollable overall
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                // Meta block
                                metaSection
                                
                                // Optional description
                                if let description = description, !description.isEmpty {
                                    descriptionSection(description)
                                }
                                
                                // Location or Shared By
                                locationSection
                                sharedBySection
                                if case .feed = variant {
                                    reportPostSection(buttonWidth: (cardWidth - 48 - 12) / 2)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                        }
                        .frame(maxHeight: .infinity)
                        
                        // Buttons row - pinned to bottom (84pt total with padding)
                        buttonsSection
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .background(Color(.systemBackground))
                    }
                    .frame(height: detailsHeight)
                }
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
            .overlay(alignment: .topTrailing) {
                closeButton
            }
            .overlay {
                if isReportPostSuccessVisible {
                    ZStack {
                        Color(.systemBackground)
                            .ignoresSafeArea()
                        ReportPostToast(
                            title: "Thanks for looking out for others 💚",
                            message: "Your report helps keep Swoopy safe and respectful for everyone.",
                            onDismiss: { dismissReportSuccess(triggerDismissal: true) }
                        )
                        .padding(.horizontal, 24)
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .sheet(isPresented: $isReportPostSheetPresented) {
                ReportPostReasonSheet(
                    reasons: reportPostReasons,
                    actionColor: AppColor.brandGreen,
                    onSelect: { reason in
                        handleReportReasonSelection(reason)
                    },
                    onCancel: {
                        Haptics.play(.tabSelect)
                        isReportPostSheetPresented = false
                    }
                )
                .presentationDetents([.fraction(0.45)])
                .presentationDragIndicator(.hidden)
            }
        }
        .onDisappear {
            reportSuccessTask?.cancel()
            reportSuccessTask = nil
        }
    }
}

// MARK: - BigCardOverlay Extensions

extension BigCardOverlay {
    
    
    @ViewBuilder
    private func imageCarousel(height: CGFloat) -> some View {
        ZStack {
            TabView(selection: $currentImageIndex) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, imageUrl in
                    AsyncImage(url: URL(string: imageUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: height)
                                .clipped()
                        default:
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: height)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .frame(height: height)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 28
                )
            )

            // Custom dots overlay
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<images.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentImageIndex ? accentColor : accentColor.opacity(0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 16)
                .allowsHitTesting(false)
            }

            // Tap zones overlay (explicit 60/40 with high priority, non-looping)
            HStack(spacing: 0) {
                // Left 60% - previous (no loop)
                Color.clear
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard images.count > 1, currentImageIndex > 0 else { return }
                        withAnimation { currentImageIndex -= 1 }
                    }

                // Right 40% - next (no loop)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let last = images.count - 1
                        guard images.count > 1, currentImageIndex < last else { return }
                        withAnimation { currentImageIndex += 1 }
                    }
            }
            .frame(height: height)
        }
    }

    // MARK: - Description Block (conditionally scrollable)
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

    // Conditionally scrollable description block with a max height
    @ViewBuilder
    private func descriptionBlock(_ description: String, maxHeight: CGFloat) -> some View {
        Group {
            if maxHeight > 0 {
                ScrollView {
                    descriptionSection(description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
            } else {
                descriptionSection(description)
            }
        }
    }
    
    // MARK: - Location Section
    
    @ViewBuilder
    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .street ? "Location" : "Pickup Area")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            if let coordinate = exactLocation {
                let span = MKCoordinateSpan(latitudeDelta: mode == .street ? 0.005 : 0.015,
                                            longitudeDelta: mode == .street ? 0.005 : 0.015)
                Map(position: .constant(.region(MKCoordinateRegion(center: coordinate, span: span)))) {
                    if #available(iOS 17.0, *) {
                        MapCircle(center: coordinate, radius: mode == .street ? 35 : 120)
                            .foregroundStyle(primaryColor.opacity(0.12))
                    }
                    Annotation("", coordinate: coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(primaryColor)
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }

            Text(locationViewModel.friendlyText)
                .font(.footnote)
                .foregroundStyle(AppTheme.ColorToken.muted)
                .multilineTextAlignment(.leading)
        }
    }
    
    // MARK: - Shared By Section
    
    @ViewBuilder
    private var sharedBySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared By")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            HStack(spacing: 12) {
                // Avatar
                if let avatarUrl = ownerAvatarUrl {
                    AsyncImage(url: avatarUrl) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        default:
                            RoundedRectangle(cornerRadius: 10)
                                .fill(primaryColor.opacity(0.15))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text(String(ownerName.prefix(1)))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(primaryColor)
                                )
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(primaryColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Text(String(ownerName.prefix(1)))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(primaryColor)
                        )
                }
                
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
                        .foregroundColor(primaryColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(accentColor)
                        .clipShape(Capsule())
                }
            }
            
            // Privacy note for HOME mode only
            if mode == .home {
                Text("Home listings keep addresses private. You'll get a location and confirm details from the owner.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func reportPostSection(buttonWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report Post?")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Your safety matters. If this post seems spam, illegal, or inappropriate, please report it.")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(mutedColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Haptics.play(.primaryAction)
                    isReportPostSheetPresented = true
                } label: {
                    Text("Make a report")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .background(dangerColor)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .frame(width: buttonWidth)
                .disabled(isReportPostSheetPresented || postID == nil)
                .opacity((isReportPostSheetPresented || postID == nil) ? 0.75 : 1.0)

                Spacer(minLength: 0)
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
            HStack(spacing: 8) {
                Button("Pick up", action: onPrimaryAction)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .buttonStyle(SwoopyPrimaryButtonStyle())
                
                Button("Cancel", action: onSecondaryAction)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .buttonStyle(SwoopyOutlineButtonStyle())
                
                Button("Directions", action: onTertiaryAction ?? {})
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .buttonStyle(SwoopyPillSecondaryStyle())
                    .disabled(onTertiaryAction == nil)
                    .opacity(onTertiaryAction == nil ? 0.6 : 1.0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            
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
        case .completed:
            VStack(spacing: 12) {
                Label("Reservation complete", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(successColor)

                Button(action: onDismiss) {
                    Text("Close")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))
            }
        }
    }
    
    @ViewBuilder
    private var feedButtons: some View {
        HStack(spacing: 12) {
            // Pass button on LEFT
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
            
            // Save for me button on RIGHT
            Button(action: onPrimaryAction) {
                Text("Save for me")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
            }
            .background(primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 26))
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatMemberSince(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private func handleReportReasonSelection(_ reason: ReportPostReason) {
        isReportPostSheetPresented = false
        Haptics.play(.tabSelect)
        submitReport(for: reason)
        presentReportSuccessOverlay()
    }

    private func submitReport(for reason: ReportPostReason) {
        guard let postID else { return }
        Task {
            let payload = ReportPayload(postId: postID, reportedUserId: nil, category: reason.category, notes: nil)
            do {
                try await api.reportPost(payload)
            } catch {
                DLog("[REPORT] post_report_error=\(error.localizedDescription)")
            }
        }
    }

    private func presentReportSuccessOverlay() {
        reportSuccessTask?.cancel()
        reportSuccessTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isReportPostSuccessVisible = true
        }
        Haptics.play(.success)
        reportSuccessTask = Task {
            do {
                try await Task.sleep(nanoseconds: reportToastDuration)
            } catch {
                return
            }
            await MainActor.run {
                dismissReportSuccess(triggerDismissal: true)
            }
        }
    }

    private func dismissReportSuccess(triggerDismissal: Bool = false) {
        reportSuccessTask?.cancel()
        reportSuccessTask = nil
        guard isReportPostSuccessVisible else {
            if triggerDismissal { onSecondaryAction() }
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isReportPostSuccessVisible = false
        }
        if triggerDismissal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onSecondaryAction()
            }
        }
    }
} // <- Added closing brace for extension BigCardOverlay

// MARK: - Report Support

private struct ReportPostReason: Identifiable, Hashable {
    let id: String
    let title: String
    let category: ReportPayload.Category
}

private struct ReportPostReasonSheet: View {
    let reasons: [ReportPostReason]
    let actionColor: Color
    let onSelect: (ReportPostReason) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(AppColor.muted)
                            .accessibilityLabel("Close")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 4)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's wrong with this post?")
                        .font(AppFont.h3)
                        .foregroundColor(AppColor.text)
                    Text("Choose a reason so we can take a look.")
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                }
                
                VStack(spacing: 12) {
                    ForEach(reasons) { reason in
                        Button {
                            onSelect(reason)
                        } label: {
                            Text(reason.title)
                                .font(AppFont.body.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .background(actionColor)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}

private struct ReportPostToast: View {
    let title: String
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppFont.h3)
                    .foregroundColor(AppColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColor.muted)
                    .padding(8)
                    .background(Color(.systemGray5), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 18, y: 8)
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

// MARK: - Close Button

private extension BigCardOverlay {
    var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(primaryColor)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        }
        .padding(.top, 9)
        .padding(.trailing, 16)
        .accessibilityLabel("Close")
    }
}

// MARK: - LocationDescriptionViewModel

private final class LocationDescriptionViewModel: ObservableObject {
    @Published var friendlyText: String

    private static var cache: [String: String] = [:]

    init(postID: String?, coordinate: CLLocationCoordinate2D?, mode: BigCardOverlay.LocationMode) {
        if let postID, let cached = Self.cache[postID] {
            friendlyText = cached
            return
        }

        guard let coordinate else {
            friendlyText = mode == .home ? "Approximate location" : "Nearby"
            return
        }

        friendlyText = "Locating…"

        Task.detached { [weak self] in
            let description = await Self.reverseGeocode(coordinate: coordinate, mode: mode)
            await MainActor.run {
                if let postID {
                    Self.cache[postID] = description
                }
                self?.friendlyText = description
            }
        }
    }

    private static func reverseGeocode(coordinate: CLLocationCoordinate2D, mode: BigCardOverlay.LocationMode) async -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current)
            if let placemark = placemarks.first {
                var components: [String] = []
                if let neighborhood = placemark.subLocality, !neighborhood.isEmpty {
                    components.append(neighborhood)
                }
                if mode == .street {
                    if let street = placemark.thoroughfare, !street.isEmpty {
                        components.append(street)
                    }
                }
                if let city = placemark.locality, !city.isEmpty, !components.contains(city) {
                    components.append(city)
                }
                if components.isEmpty, let region = placemark.administrativeArea, !region.isEmpty {
                    components.append(region)
                }
                if !components.isEmpty {
                    return components.joined(separator: ", ")
                }
            }
        } catch {
            // Ignore errors, fallback below
        }

        return mode == .home ? "Near you" : "Nearby"
    }
}
