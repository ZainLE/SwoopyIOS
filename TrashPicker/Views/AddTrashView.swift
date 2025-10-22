//
//  AddTrashView.swift
//  TrashPicker
//
//  Created by Zain Latif on 19/9/25.
//
//  NOTE: Now uses CameraOverlay (AVCam-style) for all camera operations.
//

import SwiftUI
import MapKit
import PhotosUI
import CoreLocation

struct AddTrashView: View {
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var loc: LocationManager
    @Environment(\.dismiss) private var dismiss
    
    // NEW: Accept initial images from camera capture
    var initialImages: [UIImage] = []
    var onDone: ((_ posted: Bool) -> Void)? = nil

    // MARK: - Form State
    @State private var slots: [UIImage?] = [nil, nil, nil]         // exactly 3 slots
    @State private var slotMenuIndex: Int? = nil
    @State private var showCamera = false
    @State private var showLibrary = false

    enum ItemCondition: String, CaseIterable, Codable {
        case needsFixing = "Needs Fixing"
        case usable = "Usable"
        case good = "Good"
        case likeNew = "Like New"
    }
    @State private var condition: ItemCondition = .good            // required

    @State private var descriptionText: String = ""                // optional (≤100)
    @State private var showDescriptionExpanded = false             // description chip state
    private let descriptionLimit = 100

    enum PickupMode: String, CaseIterable, Codable {
        case street = "Street"
        case home = "Home"
    }
    @State private var pickupMode: PickupMode? = nil               // required

    // Map / Location
    @State private var coord: CLLocationCoordinate2D? = nil
    @State private var camera: MapCameraPosition = .region(.init(
        center: .init(latitude: 41.387, longitude: 2.170),
        span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
    ))
    @State private var homeRadiusMeters: Double = 500
    @State private var addressLine: String = ""                    // backend/geo-derived (read-only in UI)

    // UX
    @State private var showValidation = false
    @State private var validationText = ""
    @State private var saving = false
    @State private var error: String?
    @State private var showSuccess = false

    // MARK: - Computed
    private var photos: [UIImage] { slots.compactMap { $0 } }
    private var formIsValid: Bool {
        guard !photos.isEmpty else { return false }
        guard let mode = pickupMode else { return false }
        guard coord != nil else { return false }
        if mode == .home { return !addressLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppTheme.Spacing.l) {
                    // 1) Photo Upload Section with top-right camera icon
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                        HStack {
                            Text("Photos")
                                .font(AppTheme.Typography.headline)
                                .foregroundColor(AppTheme.ColorToken.text)
                            
                            Spacer()
                            
                            // Top-right photo icon
                            Button(action: {
                                // Find first empty slot or use slot 0
                                let emptySlot = slots.firstIndex(of: nil) ?? 0
                                slotMenuIndex = emptySlot
                            }) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(AppTheme.ColorToken.primary)
                                    .frame(width: 40, height: 40)
                                    .background(AppTheme.ColorToken.accent.opacity(0.2))
                                    .clipShape(Circle())
                            }
                        }
                        
                        // 3 photo tiles (4:3 aspect ratio, 12pt radius, dashed border)
                        PhotoTilesView(
                            slots: $slots,
                            openMenu: { index in slotMenuIndex = index }
                        )
                        
                        if photos.isEmpty && saving == false && showValidation {
                            Text("At least one photo is required.")
                                .font(AppTheme.Typography.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.m)
                    
                    // 2) Condition Selector Pills
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Text("Condition")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                            .padding(.horizontal, AppTheme.Spacing.m)
                        
                        ConditionPillsView(selection: $condition)
                            .padding(.horizontal, AppTheme.Spacing.m)
                    }
                    
                    // 3) Description Chip
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Text("Description (Optional)")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                            .padding(.horizontal, AppTheme.Spacing.m)
                        
                        DescriptionChipView(
                            text: $descriptionText,
                            isExpanded: $showDescriptionExpanded,
                            limit: descriptionLimit
                        )
                        .padding(.horizontal, AppTheme.Spacing.m)
                    }
                    
                    // 4) Pickup Location Segmented Control
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                        Text("Pickup Location")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                            .padding(.horizontal, AppTheme.Spacing.m)
                        
                        Picker("Pickup Location", selection: Binding(
                            get: { pickupMode },
                            set: { newValue in
                                pickupMode = newValue
                                guard let new = newValue else { return }
                                // Auto-center & auto-select to user location
                                if loc.authorization == .notDetermined { loc.request() }
                                let fallback = CLLocationCoordinate2D(latitude: 41.387, longitude: 2.170)
                                let c = loc.userLocation?.coordinate ?? fallback
                                coord = c
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    camera = .region(.init(center: c, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
                                }
                                if new == .home {
                                    Task { addressLine = await reverseGeocodeCity(for: c) ?? "" }
                                }
                            }
                        )) {
                            Text(PickupMode.street.rawValue).tag(PickupMode?.some(.street))
                            Text(PickupMode.home.rawValue).tag(PickupMode?.some(.home))
                        }
                        .pickerStyle(.segmented)
                        .tint(AppTheme.ColorToken.primary)
                        .padding(.horizontal, AppTheme.Spacing.m)
                        
                        if pickupMode == nil && saving == false && showValidation {
                            Text("Please choose where pickup is from.")
                                .font(AppTheme.Typography.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, AppTheme.Spacing.m)
                        }
                        
                        // Map Preview
                        if let mode = pickupMode {
                            VStack(spacing: AppTheme.Spacing.s) {
                                InlineMap(
                                    mode: mode,
                                    camera: $camera,
                                    coord: $coord,
                                    radius: $homeRadiusMeters,
                                    colorCircle: AppTheme.ColorToken.accent
                                )
                                .frame(height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card))
                                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.card).stroke(.quaternary))
                                .padding(.horizontal, AppTheme.Spacing.m)

                                if mode == .home {
                                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "house.fill")
                                                .foregroundStyle(AppTheme.ColorToken.mutedGray)
                                            Text(addressLine.isEmpty ? "Approximate address will appear here" : addressLine)
                                                .font(AppTheme.Typography.body)
                                                .foregroundStyle(addressLine.isEmpty ? AppTheme.ColorToken.mutedGray : AppTheme.ColorToken.text)
                                        }
                                        Text("Your exact address stays private. We show a 500m radius to nearby users.")
                                            .font(AppTheme.Typography.footnote)
                                            .foregroundStyle(AppTheme.ColorToken.mutedGray)
                                    }
                                    .padding(.horizontal, AppTheme.Spacing.m)
                                }
                            }
                        }
                    }
                    
                    // 5) Share Your Find Button
                    Button(action: submit) {
                        HStack(spacing: AppTheme.Spacing.s) {
                            if saving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.ColorToken.textInv))
                                    .scaleEffect(0.8)
                            }
                            Text("Share Your Find")
                                .font(AppTheme.Typography.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(formIsValid && !saving ? AppTheme.ColorToken.primary : AppTheme.ColorToken.mutedGray)
                        .foregroundColor(AppTheme.ColorToken.textInv)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.button))
                    }
                    .disabled(!formIsValid || saving)
                    .padding(.horizontal, AppTheme.Spacing.m)
                    .padding(.bottom, AppTheme.Spacing.xl)

                    if let e = error {
                        Text(e)
                            .foregroundStyle(.red)
                            .font(AppTheme.Typography.footnote)
                            .padding(.horizontal, AppTheme.Spacing.m)
                    }
                }
            }
            .navigationTitle("Share Your Find")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(AppTheme.ColorToken.primary)
                }
            }
            .confirmationDialog(menuTitle, isPresented: Binding(
                get: { slotMenuIndex != nil },
                set: { if !$0 { slotMenuIndex = nil } }
            ), titleVisibility: .visible) {
                if let idx = slotMenuIndex {
                    if slots[idx] == nil {
                        Button("Take Photo") {
                            Task {
                                let ok = await CameraSessionManager.shared.ensurePermission()
                                if ok {
                                    CameraSessionManager.shared.configureIfNeeded()
                                    showCamera = true
                                }
                            }
                        }
                        Button("Choose from Library") { showLibrary = true }
                    } else {
                        Button("Replace Photo") { showLibrary = true }
                        Button("Remove Photo", role: .destructive) {
                            slots[idx] = nil
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraOverlay(
                    onCaptured: { image in
                        if let idx = slotMenuIndex {
                            slots[idx] = image
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        showCamera = false
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
            }
            .sheet(isPresented: $showLibrary) {
                LibraryPicker(limit: 1) { images in
                    if let idx = slotMenuIndex, let img = images.first {
                        slots[idx] = img
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    showLibrary = false
                }
            }
            .overlay(alignment: .top) {
                if showSuccess {
                    Label("Your find was shared!", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, AppTheme.Spacing.m)
                        .padding(.vertical, AppTheme.Spacing.s)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(AppTheme.ColorToken.accent.opacity(0.5)))
                        .padding(.top, AppTheme.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showSuccess)
            .alert("Can't Share", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationText)
            }
            .onAppear {
                // Prefill with initial images from camera capture
                if slots.allSatisfy({ $0 == nil }) && !initialImages.isEmpty {
                    for (index, image) in initialImages.prefix(3).enumerated() {
                        slots[index] = image
                    }
                }
            }
        }
    }

    private var menuTitle: String {
        if let idx = slotMenuIndex, slots[idx] == nil { return "Add Photo" }
        return "Photo"
    }

    // MARK: - Actions

    private func submit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard formIsValid else {
            showValidation = true
            if photos.isEmpty { validationText = "Please add at least one photo." }
            else if pickupMode == nil { validationText = "Choose pickup location." }
            else if coord == nil { validationText = "We couldn’t get your location yet." }
            else if pickupMode == .some(.home), addressLine.isEmpty { validationText = "We’re still resolving your address. Try again in a moment." }
            return
        }

        Task { await save() }
    }

    private func save() async {
        guard let c = coord, let img = photos.first else { return }
        saving = true
        error = nil
        defer { saving = false }

        do {
            // Keep CK service happy (title/category placeholders)
            try await ck.createTrash(
                image: img,
                title: "Shared item",
                category: "Other",
                coordinate: c,
                city: addressLine // if street, this may be locality; fine as label
            )

            // Reset + success
            slots = [nil, nil, nil]
            descriptionText = ""
            pickupMode = nil
            coord = nil
            await ck.fetchFeed()

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { showSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                showSuccess = false
                onDone?(true) // Notify that posting was successful
                dismiss() // Dismiss to feed
            }
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func reverseGeocodeCity(for c: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: c.latitude, longitude: c.longitude)
            )
            if let p = placemarks.first {
                // Compose a friendly, masked-ish line (locality + country code or postal code)
                let parts = [p.subLocality, p.locality, p.postalCode, p.country].compactMap { $0 }
                return parts.joined(separator: ", ")
            }
        } catch { }
        return nil
    }

    // MARK: - Subviews

    private func requiredHeader(_ title: String) -> some View {
        HStack(spacing: 2) {
            Text(title)
            Text("*").foregroundStyle(AppTheme.ColorToken.primary)
        }
    }
}

// MARK: - Photo Tiles (3 slots with 4:3 aspect ratio)

private struct PhotoTilesView: View {
    @Binding var slots: [UIImage?]
    var openMenu: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let totalSpacing: CGFloat = 2 * AppTheme.Spacing.s // two gaps
            let tileWidth = (geo.size.width - totalSpacing) / 3
            let tileHeight = tileWidth * 3/4 // 4:3 aspect ratio

            HStack(spacing: AppTheme.Spacing.s) {
                ForEach(0..<3, id: \.self) { idx in
                    PhotoTileView(
                        image: slots[idx],
                        width: tileWidth,
                        height: tileHeight
                    )
                    .onTapGesture { openMenu(idx) }
                    .accessibilityLabel(slots[idx] == nil
                        ? "Add photo \(idx + 1) of 3"
                        : "Photo \(idx + 1), tap to replace or remove")
                }
            }
            .frame(height: tileHeight)
        }
        .frame(height: 120)
    }
}

private struct PhotoTileView: View {
    let image: UIImage?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                    .fill(AppTheme.ColorToken.surface)
                    .frame(width: width, height: height)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                            .dashBorder()
                            .foregroundStyle(AppTheme.ColorToken.mutedGray.opacity(0.5))
                    )
                    .overlay {
                        Image(systemName: "camera")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(AppTheme.ColorToken.mutedGray)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

// MARK: - Condition Pills

private struct ConditionPillsView: View {
    @Binding var selection: AddTrashView.ItemCondition

    var body: some View {
        FlowLayout(spacing: AppTheme.Spacing.s) {
            ForEach(AddTrashView.ItemCondition.allCases, id: \.self) { item in
                Button {
                    selection = item
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(item.rawValue)
                        .font(AppTheme.Typography.body.weight(.medium))
                        .padding(.horizontal, AppTheme.Spacing.m)
                        .padding(.vertical, AppTheme.Spacing.s)
                        .background(selection == item ? AppTheme.ColorToken.primary : AppTheme.ColorToken.surface)
                        .foregroundStyle(selection == item ? AppTheme.ColorToken.textInv : AppTheme.ColorToken.text)
                        .overlay(
                            Capsule()
                                .stroke(selection == item ? AppTheme.ColorToken.primary : AppTheme.ColorToken.mutedGray.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(selection == item ? 0.1 : 0), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Description Chip

private struct DescriptionChipView: View {
    @Binding var text: String
    @Binding var isExpanded: Bool
    let limit: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            // Chip that expands/collapses
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text(text.isEmpty ? "Add description..." : (text.count > 30 ? String(text.prefix(30)) + "..." : text))
                        .font(AppTheme.Typography.body)
                        .foregroundColor(text.isEmpty ? AppTheme.ColorToken.mutedGray : AppTheme.ColorToken.text)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, AppTheme.Spacing.s)
                .background(AppTheme.ColorToken.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.chip)
                        .stroke(AppTheme.ColorToken.mutedGray.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.chip))
            }
            .buttonStyle(.plain)
            
            // Expanded text area
            if isExpanded {
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.s) {
                    TextEditor(text: $text)
                        .frame(minHeight: 80, maxHeight: 120)
                        .padding(AppTheme.Spacing.s)
                        .background(AppTheme.ColorToken.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                                .stroke(AppTheme.ColorToken.mutedGray.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card))
                        .onChange(of: text) { _, new in
                            if new.count > limit {
                                text = String(new.prefix(limit))
                            }
                        }
                    
                    Text("\(text.count)/\(limit)")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// Simple flow layout (chips wrap to next line)
private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing; self.content = content
    }
    var body: some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content()
                    .padding(.trailing, spacing)
                    .alignmentGuide(.leading) { d in
                        if (abs(width - d.width) > geo.size.width) { width = 0; height -= d.height + spacing }
                        let result = width
                        if d.width != 0 { width -= d.width + spacing }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if height != 0 { }
                        return result
                    }
            }
        }
        .frame(minHeight: 10)
    }
}

// MARK: - Inline Map

private struct InlineMap: View {
    let mode: AddTrashView.PickupMode
    @Binding var camera: MapCameraPosition
    @Binding var coord: CLLocationCoordinate2D?
    @Binding var radius: Double
    let colorCircle: Color

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: .all) {
                if mode == .street, let c = coord {
                    Annotation("Selected", coordinate: c) {
                        Image(systemName: "mappin.circle.fill").font(.title2)
                    }
                }
                if mode == .home, let c = coord {
                    MapCircle(center: c, radius: radius)
                        .foregroundStyle(colorCircle.opacity(0.20))
                        .stroke(colorCircle.opacity(0.9), lineWidth: 2)
                }
                UserAnnotation()
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    // allow moving exact pin when Street
                    guard mode == .street else { return }
                    let p = value.location
                    if let newCoord = proxy.convert(p, from: .local) {
                        coord = newCoord
                    }
                }
            )
        }
    }
}

// MARK: - Pickers

private struct LibraryPicker: UIViewControllerRepresentable {
    let limit: Int
    var onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .images
        cfg.selectionLimit = max(1, limit)
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(limit: limit, onFinish: onFinish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let limit: Int; let onFinish: ([UIImage]) -> Void
        init(limit: Int, onFinish: @escaping ([UIImage]) -> Void) { self.limit = limit; self.onFinish = onFinish }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { self.onFinish([]); return }
            var images: [UIImage] = []; let group = DispatchGroup()
            for r in results.prefix(limit) {
                if r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                        if let img = obj as? UIImage { images.append(img) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { self.onFinish(images) }
        }
    }
}

// MARK: - Small helpers

private extension Shape {
    func dashBorder() -> some View {
        self
            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [6, 6]))
    }
}

