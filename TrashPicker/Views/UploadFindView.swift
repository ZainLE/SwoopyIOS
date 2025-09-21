import SwiftUI
import MapKit
import PhotosUI
import CoreLocation

// MARK: - UploadFindView

struct UploadFindView: View {
    @EnvironmentObject var loc: LocationManager
    
    let initialPhoto: UIImage?
    @StateObject private var vm = UploadFindViewModel()
    
    init(initialPhoto: UIImage? = nil) {
        self.initialPhoto = initialPhoto
    }
    @State private var showActionForTile: Int? = nil     // which tile (0..2)
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showValidation = false
    @State private var validationText = ""

    // Layout constants
    private let sidePadding: CGFloat = 20
    private let maxWidth: CGFloat = 600

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 16)

                // Title
                Text("Upload your find")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                // Provide image *
                sectionLabel("Provide image", required: true)
                helper("Upload or take up to 3 pictures of your item (front, detail, size). Clear photos help others decide quickly.")

                photoRow

                if showValidation && vm.photos.isEmpty {
                    validationHint("Please add at least one photo.")
                }

                // Condition *
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Condition", required: true)
                    ChipGroup(
                        items: Condition.allCases,
                        selection: $vm.condition,
                        label: { $0.title }
                    )
                }

                if showValidation && vm.condition == nil {
                    validationHint("Please select a condition.")
                }

                // Pickup Location *
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Pickup Location", required: true)
                    ModeChips(mode: $vm.mode)
                    mapCard
                }

                if showValidation && !vm.hasChosenModeOrLocation {
                    validationHint("Please confirm your pickup mode.")
                }

                // Provide Description (toggle row -> expands)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $vm.wantsDescription.animation()) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.wantsDescription ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Color.brandDark)
                            Text("Provide Description")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .toggleStyle(.switch)

                    if vm.wantsDescription {
                        helper("Write up to 100 characters (optional).")
                        ZStack(alignment: .bottomTrailing) {
                            TextField("Building a simple app with friends to share,", text: $vm.descriptionText, axis: .vertical)
                                .textInputAutocapitalization(.sentences)
                                .lineLimit(2...4)
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandDark.opacity(0.20), lineWidth: 1))

                            Text("\(vm.descriptionText.count)/100")
                                .font(.caption)
                                .foregroundStyle(Color.textMuted)
                                .padding(.trailing, 8)
                                .padding(.bottom, 6)
                        }
                    }
                }

                // CTA
                PrimaryCTAButton(title: "Share Your Find", enabled: vm.canSubmit) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !vm.canSubmit {
                        showValidation = true
                        validationText = "Please complete required fields."
                        return
                    }
                    Task { await vm.submit(using: MockUploader()) }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, sidePadding)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .scrollDismissesKeyboard(.immediately)
        .onAppear {
            if loc.authorization == .notDetermined { loc.request() }
            Task {
                vm.bootstrapLocation(loc.userLocation?.coordinate)
                
                // Add initial photo if provided
                if let initialPhoto = initialPhoto {
                    vm.putPhoto(initialPhoto, at: nil)
                }
            }
        }
        .onChange(of: loc.userLocation) { _, newValue in
            vm.bootstrapLocation(newValue?.coordinate)
        }
        // Prefill from camera notification (FAB flow)
        .onReceive(NotificationCenter.default.publisher(for: .prefillUploadImage)) { note in
            if let img = note.object as? UIImage, vm.photos.isEmpty {
                vm.putPhoto(img, at: nil)
            }
        }
        // Image sources (reuse existing pickers)
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let img = image { vm.putPhoto(img, at: showActionForTile) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPicker) {
            LibraryPicker(limit: 1) { images in
                if let img = images.first { vm.putPhoto(img, at: showActionForTile) }
            }
        }
    }

    // MARK: Sections

    private var photoRow: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { idx in
                let img = vm.photos[safe: idx]
                PhotoTile(image: img, height: 96) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showActionForTile = idx
                    showPhotoActions(for: idx, hasImage: (img != nil))
                }
            }
        }
    }

    private func showPhotoActions(for index: Int, hasImage: Bool) {
        guard let controller = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow?.rootViewController else { return }

        let ac = UIAlertController(title: "Photo", message: nil, preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "Take Photo", style: .default) { _ in showCamera = true })
        ac.addAction(UIAlertAction(title: "Choose Photo", style: .default) { _ in showPicker = true })
        if hasImage {
            ac.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in vm.removePhoto(at: index) })
        }
        ac.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        controller.present(ac, animated: true)
    }

    private var mapCard: some View {
        Group {
            if let mode = vm.mode {
                InlineUploadMap(
                    mode: mode,
                    selectedCoord: $vm.currentCoordinate,
                    addressText: $vm.addressText,
                    camera: $vm.camera,
                    onCoordinateChange: { coord in
                        vm.debouncedReverseGeocode(coord)
                    }
                )
                .environmentObject(loc)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.mode)
    }

    // MARK: Labels & helpers

    private func sectionLabel(_ text: String, required: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.subheadline.weight(.semibold))
            if required { Text("*").foregroundStyle(.red).font(.subheadline.weight(.semibold)) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helper(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Color.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func validationHint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
    }
}

// MARK: - ViewModel & Models

final class UploadFindViewModel: ObservableObject {
    @Published var photos: [UIImage] = []                // max 3
    @Published var condition: Condition? = nil           // required
    @Published var mode: PickupMode? = .street           // default selected (street)
    @Published var wantsDescription = false
    @Published var descriptionText = "" { didSet { if descriptionText.count > 100 { descriptionText = String(descriptionText.prefix(100)) } } }

    // Map state
    @Published var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                                                                          span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var addressText: String = "Locating address…"
    
    private var geocodeTask: Task<Void, Never>?

    var canSubmit: Bool { !photos.isEmpty && condition != nil && mode != nil }
    var hasChosenModeOrLocation: Bool { mode != nil }

    func putPhoto(_ img: UIImage, at index: Int?) {
        if let i = index, photos.indices.contains(i) {
            photos[i] = img
        } else if photos.count < 3 {
            photos.append(img)
        }
    }
    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
    }

    func bootstrapLocation(_ user: CLLocationCoordinate2D?) {
        guard currentCoordinate == nil else { return }
        ensureMapCentered(using: user)
    }

    func ensureMapCentered(using user: CLLocationCoordinate2D?) {
        let center = user ?? CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        currentCoordinate = center
        camera = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        debouncedReverseGeocode(center)
    }
    
    func debouncedReverseGeocode(_ coord: CLLocationCoordinate2D) {
        geocodeTask?.cancel()
        geocodeTask = Task { [coord] in
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms
            await reverseGeocode(coord)
        }
    }
    
    @MainActor
    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async {
        addressText = "Locating address…"
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            guard let p = placemarks.first else { 
                addressText = "Address unavailable"
                return 
            }
            // Build string safely:
            let parts = [p.name, p.thoroughfare, p.subLocality, p.locality].compactMap { $0 }.filter { !$0.isEmpty }
            addressText = parts.isEmpty ? "Address unavailable" : parts.joined(separator: ", ")
        } catch {
            addressText = "Address unavailable"
        }
    }

    @MainActor
    func submit(using uploader: FindUploader) async {
        guard let cond = condition, let m = mode, canSubmit else { return }
        let draft = UploadDraft(photos: photos, condition: cond, mode: m, description: descriptionText.isEmpty ? nil : descriptionText)
        try? await uploader.uploadDraft(draft) // no-op mock by default
    }
}

enum Condition: CaseIterable, Hashable, Identifiable {
    case needsFixing, usable, good, likeNew
    var id: Self { self }
    var title: String {
        switch self {
        case .needsFixing: return "Needs Fixing"
        case .usable:      return "Usable"
        case .good:        return "Good"
        case .likeNew:     return "Like New"
        }
    }
}

enum PickupMode: Hashable { case street, home }

protocol FindUploader {
    func uploadDraft(_ draft: UploadDraft) async throws
}
struct UploadDraft {
    let photos: [UIImage]
    let condition: Condition
    let mode: PickupMode
    let description: String?
}
struct MockUploader: FindUploader {
    func uploadDraft(_ draft: UploadDraft) async throws { /* no-op for now */ }
}

// MARK: - InlineUploadMap

private struct InlineUploadMap: View {
    @EnvironmentObject var loc: LocationManager
    let mode: PickupMode
    @Binding var selectedCoord: CLLocationCoordinate2D?
    @Binding var addressText: String
    @Binding var camera: MapCameraPosition
    
    @State private var isCentering = false
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
    
    // Callback to parent for geocoding
    var onCoordinateChange: ((CLLocationCoordinate2D) -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .home ? "Your home area is shown approximately (500 m radius)." :
                                 "Drag the map to adjust the exact pin.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
            
            Map(position: $camera, interactionModes: .all) {
                if mode == .home, let c = selectedCoord {
                    MapCircle(center: c, radius: 500)
                        .foregroundStyle(Color.brandDark.opacity(0.20))
                    Annotation("Home area", coordinate: c) {
                        Image(systemName: "house.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                } else if let c = selectedCoord {
                    Annotation("Pickup", coordinate: c) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
                UserAnnotation()
            }
            .transaction { $0.disablesAnimations = true }
            .onChange(of: camera, initial: false) { _, newCamera in
                if let region = newCamera.region {
                    selectedCoord = region.center
                    onCoordinateChange?(region.center)
                }
            }

            .overlay(alignment: .bottomTrailing) {
                Button {
                    loc.requestOnce { c in
                        guard let c else { return }
                        selectedCoord = c
                        camera = .region(.init(center: c, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
                        onCoordinateChange?(c)
                    }
                } label: {
                    Image(systemName: "location.circle.fill")
                        .font(.title2)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(10)
            }
            .task {
                if loc.authorization == .notDetermined { loc.request() }
                let center = loc.userLocation?.coordinate ?? selectedCoord ?? fallback
                selectedCoord = center
                camera = .region(.init(center: center, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
                onCoordinateChange?(center)
            }
            
            // Address text below the map
            Text(addressText)
                .font(.footnote)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
    }
}

// MARK: - Reusable pieces

private struct PhotoTile: View {
    let image: UIImage?
    let height: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.brandDark)
                }
            }
            .frame(width: (height * 4/3), height: height) // 4:3 tiles, fixed height
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandDark.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ChipGroup<Item: CaseIterable & Hashable>: View {
    let items: Item.AllCases
    @Binding var selection: Item?
    let label: (Item) -> String

    var body: some View {
        FlexibleRow(spacing: 8) {
            ForEach(Array(items), id: \.self) { item in
                let isOn = selection == item
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(isOn ? .white : Color.brandDark)
                        .background(
                            Capsule().fill(isOn ? Color.brandDark : .clear)
                        )
                        .overlay(
                            Capsule().stroke(Color.brandDark, lineWidth: isOn ? 0 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ModeChips: View {
    @Binding var mode: PickupMode?
    var body: some View {
        HStack(spacing: 8) {
            chip("On The Street", .street)
            chip("From Home", .home)
        }
    }
    @ViewBuilder private func chip(_ title: String, _ value: PickupMode) -> some View {
        let isOn = mode == value
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            mode = value
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(isOn ? .white : Color.brandDark)
                .background(Capsule().fill(isOn ? Color.brandDark : .clear))
                .overlay(Capsule().stroke(Color.brandDark, lineWidth: isOn ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}

private struct PrimaryCTAButton: View {
    let title: String
    let enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.brandDark)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.brandLime.opacity(enabled ? 1 : 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: enabled ? .black.opacity(0.08) : .clear, radius: 8, y: 2)
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }
}

private struct FlexibleRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        FlowLayout(spacing: spacing, content: content)
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            _stack(in: geo.size)
        }
    }

    private func _stack(in size: CGSize) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0
        return ZStack(alignment: .topLeading) {
            content()
                .fixedSize()
                .alignmentGuide(.leading) { d in
                    if x + d.width > size.width {
                        x = 0
                        y -= d.height + spacing
                    }
                    let result = x
                    x += d.width + spacing
                    return result
                }
                .alignmentGuide(.top) { _ in y }
        }
    }
}

// MARK: - Temporary picker stubs (replace with real implementations if available elsewhere)
private struct CameraPicker: View {
    let onImage: (UIImage?) -> Void
    init(_ onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }
    var body: some View {
        Color.clear.onAppear { onImage(nil) }
    }
}

private struct LibraryPicker: View {
    let limit: Int
    let onImages: ([UIImage]) -> Void
    init(limit: Int, _ onImages: @escaping ([UIImage]) -> Void) {
        self.limit = limit
        self.onImages = onImages
    }
    var body: some View {
        Color.clear.onAppear { onImages([]) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// Keep old references working
typealias AddTrashFlow = AddTrashView

