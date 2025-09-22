import SwiftUI
import MapKit
import PhotosUI
import CoreLocation

// MARK: - UploadFindView

struct UploadFindView: View {
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    
    let initialPhoto: UIImage?
    @StateObject private var vm = UploadFindViewModel()
    
    // Static flag to ensure appearance is only configured once
    private static var hasConfiguredAppearance = false
    
    // Configure segmented control appearance once
    init(initialPhoto: UIImage? = nil) {
        self.initialPhoto = initialPhoto
        
        // Configure appearance only once globally
        if !Self.hasConfiguredAppearance {
            UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Color.brandDark)
            if #available(iOS 13.0, *) {
                UISegmentedControl.appearance().backgroundColor = UIColor.secondarySystemBackground
            } else {
                UISegmentedControl.appearance().backgroundColor = UIColor.white
            }
            UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 16, weight: .medium)], for: .selected)
            UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.label, .font: UIFont.systemFont(ofSize: 16, weight: .medium)], for: .normal)
            Self.hasConfiguredAppearance = true
        }
    }
    
    @State private var showActionForTile: Int? = nil     // which tile (0..2)
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showValidation = false
    @State private var validationText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?

    // Layout constants
    private let sidePadding: CGFloat = 20
    private let maxWidth: CGFloat = 600

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 16)

                // Provide image *
                sectionLabel("Provide image", required: true)
                helper("Upload or take up to 3 pictures of your item (front, detail, size). Clear photos help others decide quickly.")

                photoRow

                if showValidation && vm.imageRecords.isEmpty {
                    validationHint("Please add at least one photo.")
                }

                // Condition *
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Condition", required: true)
                    ConditionSegmentedPicker(selection: $vm.condition)
                }
                .padding(.top, 16)

                if showValidation && vm.condition == nil {
                    validationHint("Please select a condition.")
                }

                // Provide Description (toggle row -> expands)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $vm.wantsDescription.animation()) {
                        Text("Provide Description")
                            .font(.subheadline.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .tint(Color.brandDark)
                    .padding(.top, 16)

                    if vm.wantsDescription {
                        helper("Write up to 100 characters (optional).")
                        VStack(spacing: 8) {
                            TextField("Add details about the product", text: $vm.descriptionText, axis: .vertical)
                                .textInputAutocapitalization(.sentences)
                                .lineLimit(1...4)
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 99))
                                .overlay(RoundedRectangle(cornerRadius: 99).stroke(Color.brandDark.opacity(0.20), lineWidth: 1))
                            
                            HStack {
                                Spacer()
                                Button("Done") {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Color.brandDark)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.brandDark.opacity(0.1))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Pickup Location *
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Pickup Location", required: true)
                    PickupModeSegmentedPicker(selection: $vm.mode)
                    mapCard
                }
                .padding(.top, 16)

                if showValidation && !vm.hasChosenModeOrLocation {
                    validationHint("Please confirm your pickup mode.")
                }

                // CTA
                PrimaryCTAButton(title: "Share Your Find", enabled: vm.canSubmit) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !vm.canSubmit {
                        showValidation = true
                        validationText = "Please complete required fields."
                        return
                    }
                    
                    Task {
                        do {
                            // 1) Read access token from Supabase session (session access can throw)
                            let session = try await svc.client.auth.session
                            let bearer = session.accessToken
                            
                            guard !bearer.isEmpty else {
                                // TODO: Show error toast
                                print("No access token")
                                return
                            }
                            
                            // 2) Configure uploader with real endpoints
                            let uploader = SupabaseUploader(
                                supabaseService: svc,
                                backendAPIURL: "https://api.yourserver.com", // TODO: Replace with AppConfig.apiBaseURL
                                bearerToken: bearer
                            )
                            
                            // 3) Submit (does not throw)
                            await vm.submit(using: uploader)
                            // Success - dismiss the upload form
                            dismiss()
                        } catch {
                            // TODO: Show error toast
                            print("Auth/session error:", error.localizedDescription)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, sidePadding)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .scrollDismissesKeyboard(.immediately)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Upload your find")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.primary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(Color.brandDark)
                }
            }
        }
        .onAppear {
            if loc.authorization == CLAuthorizationStatus.notDetermined { loc.request() }
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
        // Note: Notification-based prefill removed - now using direct initialPhoto parameter
        // Image sources (use working camera implementations)
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                if let img = image { 
                    vm.putPhoto(img, at: showActionForTile) 
                }
            }
            .ignoresSafeArea(.all)
            .background(Color.black)
        }
        .sheet(isPresented: $showPicker) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text("Choose Photo")
                    .font(.headline)
                    .padding()
            }
            .onChange(of: selectedPhotoItem) { newItem in
                Task {
                    if let newItem = newItem,
                       let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            vm.putPhoto(image, at: showActionForTile)
                            selectedPhotoItem = nil
                            showPicker = false
                        }
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var photoRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Show photos + one extra empty frame (max 3 total)
            ForEach(0..<min(vm.imageRecords.count + 1, 3), id: \.self) { idx in
                let img = vm.imageRecords[safe: idx]?.localImage
                PhotoTile(image: img, width: 110, height: 164) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showActionForTile = idx
                    showPhotoActions(for: idx, hasImage: (img != nil))
                }
            }
            Spacer()
        }
    }

    private func showPhotoActions(for index: Int, hasImage: Bool) {
        let takePhotoTitle = hasImage ? "Retake Photo" : "Take Photo"
        
        let alert = UIAlertController(title: "Photo Options", message: nil, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: takePhotoTitle, style: .default) { _ in
            DispatchQueue.main.async {
                self.showActionForTile = index
                self.showCamera = true
            }
        })
        
        alert.addAction(UIAlertAction(title: "Choose from Library", style: .default) { _ in
            DispatchQueue.main.async {
                self.showActionForTile = index
                self.showPicker = true
            }
        })
        
        if hasImage {
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
                DispatchQueue.main.async {
                    self.vm.removePhoto(at: index)
                }
            })
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        // Set app color
        alert.view.tintColor = UIColor(Color.brandDark)
        
        // Present the alert with better error handling
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }),
                  let rootViewController = window.rootViewController else {
                print("Could not find root view controller")
                return
            }
            
            // Find the topmost presented view controller
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            
            topController.present(alert, animated: true)
        }
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                
                // Address text outside the map
                Text(vm.addressText)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
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

// MARK: - Image Models for Supabase
struct ImageRecord {
    let id: UUID = UUID()
    let postId: UUID?
    let url: String
    let orderIndex: Int
    let localImage: UIImage? // For display before upload
}

struct PostDraft {
    let id: UUID = UUID()
    let images: [ImageRecord]
    let condition: Condition
    let mode: PickupMode
    let description: String?
    let coordinate: CLLocationCoordinate2D?
}

final class UploadFindViewModel: ObservableObject {
    @Published var imageRecords: [ImageRecord] = []      // max 3, Supabase-ready
    @Published var condition: Condition? = .needsFixing  // default to 'Needs Fixing'
    @Published var mode: PickupMode? = .street           // default selected (street)
    @Published var wantsDescription = false
    @Published var descriptionText = "" { didSet { if descriptionText.count > 100 { descriptionText = String(descriptionText.prefix(100)) } } }
    
    // Computed property for backward compatibility
    var photos: [UIImage] {
        return imageRecords.compactMap { $0.localImage }
    }

    // Map state
    @Published var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                                                                          span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var addressText: String = "Locating address…"
    
    private var geocodeTask: Task<Void, Never>?

    var canSubmit: Bool { 
        !imageRecords.isEmpty && condition != nil && mode != nil && currentCoordinate != nil
    }
    var hasChosenModeOrLocation: Bool { mode != nil }

    func putPhoto(_ img: UIImage, at index: Int?) {
        let imageRecord = ImageRecord(
            postId: nil, // Will be set when creating post
            url: "", // Will be set after upload to Supabase storage
            orderIndex: index ?? imageRecords.count,
            localImage: img
        )
        
        if let i = index, imageRecords.indices.contains(i) {
            // Replace existing image
            var updatedRecord = imageRecord
            updatedRecord = ImageRecord(
                postId: imageRecords[i].postId,
                url: imageRecords[i].url,
                orderIndex: i,
                localImage: img
            )
            imageRecords[i] = updatedRecord
        } else if imageRecords.count < 3 {
            // Add new image
            imageRecords.append(imageRecord)
        }
        
        // Reorder indices
        for (idx, _) in imageRecords.enumerated() {
            imageRecords[idx] = ImageRecord(
                postId: imageRecords[idx].postId,
                url: imageRecords[idx].url,
                orderIndex: idx,
                localImage: imageRecords[idx].localImage
            )
        }
    }
    
    func removePhoto(at index: Int) {
        guard imageRecords.indices.contains(index) else { return }
        imageRecords.remove(at: index)
        
        // Reorder remaining images
        for (idx, _) in imageRecords.enumerated() {
            imageRecords[idx] = ImageRecord(
                postId: imageRecords[idx].postId,
                url: imageRecords[idx].url,
                orderIndex: idx,
                localImage: imageRecords[idx].localImage
            )
        }
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
        
        let postDraft = PostDraft(
            images: imageRecords,
            condition: cond,
            mode: m,
            description: descriptionText.isEmpty ? nil : descriptionText,
            coordinate: currentCoordinate
        )
        
        try? await uploader.uploadPostDraft(postDraft)
    }
    
    // Method to prepare for Supabase upload
    func prepareForUpload() -> PostDraft? {
        guard let cond = condition, let m = mode, canSubmit else { return nil }
        
        return PostDraft(
            images: imageRecords,
            condition: cond,
            mode: m,
            description: descriptionText.isEmpty ? nil : descriptionText,
            coordinate: currentCoordinate
        )
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
    
    // Backend mapping
    var backendValue: String {
        switch self {
        case .needsFixing: return "bad"
        case .usable:      return "good"
        case .good:        return "good"
        case .likeNew:     return "excellent"
        }
    }
}

enum PickupMode: CaseIterable, Hashable, Identifiable {
    case street, home
    
    var id: Self { self }
    
    var title: String {
        switch self {
        case .street: return "From Street"
        case .home: return "From Home"
        }
    }
    
    // Backend mapping
    var backendValue: String {
        switch self {
        case .street: return "street"
        case .home: return "home"
        }
    }
}

protocol FindUploader {
    func uploadPostDraft(_ draft: PostDraft) async throws
}

struct MockUploader: FindUploader {
    func uploadPostDraft(_ draft: PostDraft) async throws { 
        print("Mock upload: \(draft.images.count) images, condition: \(draft.condition.title)")
        // In real implementation, this would:
        // 1. Upload images to Supabase storage
        // 2. Create post record with image URLs
        // 3. Create image records with post_id and order_index
    }
}

// Backend API Models
struct BackendPostRequest: Codable {
    let title: String
    let description: String?
    let category: String
    let condition: String
    let mode: String
    let images: [BackendImageData]
    let exact_location: String?   // "POINT(lon lat)" for street
    let approx_location: String?  // "POINT(lon lat)" for home
}

struct BackendImageData: Codable {
    let url: String
    let order_index: Int
}

// Helper function for 500m coordinate rounding
func approx(_ c: CLLocationCoordinate2D, meters: Double = 500) -> CLLocationCoordinate2D {
    let latMetersPerDeg = 111_320.0
    let lonMetersPerDeg = 111_320.0 * cos(c.latitude * .pi / 180)
    let dLat = meters / latMetersPerDeg
    let dLon = meters / max(1, lonMetersPerDeg)
    let lat = (c.latitude / dLat).rounded() * dLat
    let lon = (c.longitude / dLon).rounded() * dLon
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

// Local errors for upload operations
enum UploadError: Error {
    case imageEncodingFailed
}

// Supabase uploader with proper backend integration
struct SupabaseUploader: FindUploader {
    let supabaseService: SupabaseService
    let backendAPIURL: String
    let bearerToken: String
    
    func uploadPostDraft(_ draft: PostDraft) async throws {
        // Step 1: Upload each image to Supabase Storage
        var uploadedImages: [BackendImageData] = []
        
        for (index, imageRecord) in draft.images.enumerated() {
            guard let image = imageRecord.localImage else { continue }
            
            // Upload to Supabase Storage (implement your storage upload logic)
            let publicURL = try await uploadImageToSupabaseStorage(image, index: index)
            
            uploadedImages.append(BackendImageData(
                url: publicURL,
                order_index: index
            ))
        }
        
        // Step 2: Prepare location data
        let (exactLocation, approxLocation) = prepareLocationData(draft)
        
        // Step 3: Create backend request
        let backendRequest = BackendPostRequest(
            title: "Free item",  // Safe default as per your note
            description: draft.description,
            category: "other",   // Safe default as per your note
            condition: draft.condition.backendValue,
            mode: draft.mode.backendValue,
            images: uploadedImages,
            exact_location: exactLocation,
            approx_location: approxLocation
        )
        
        // Step 4: POST to your Flask backend
        try await postToBackend(backendRequest)
    }
    
    private func uploadImageToSupabaseStorage(_ image: UIImage, index: Int) async throws -> String {
        // 1) JPEG encode
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw UploadError.imageEncodingFailed
        }
        
        // 2) Generate unique filename
        let filename = "posts/\(UUID().uuidString)_\(index).jpg"
        
        // 3) Upload to Supabase Storage
        // TODO: Replace with actual Supabase Storage implementation
        // Example:
        // let result = try await supabaseService.client.storage
        //     .from("images")
        //     .upload(path: filename, file: data)
        // 
        // let publicURL = try await supabaseService.client.storage
        //     .from("images")
        //     .getPublicURL(path: filename)
        
        // TEMP: Return placeholder until real implementation
        return "https://YOUR-SUPABASE-STORAGE/public/\(filename)"
    }
    
    private func prepareLocationData(_ draft: PostDraft) -> (exact: String?, approx: String?) {
        guard let c = draft.coordinate else { return (nil, nil) }
        
        switch draft.mode {
        case .street:
            let wkt = "POINT(\(c.longitude) \(c.latitude))"
            return (exact: wkt, approx: nil)
        case .home:
            let a = approx(c, meters: 500)
            let wkt = "POINT(\(a.longitude) \(a.latitude))"
            return (exact: nil, approx: wkt)
        }
    }
    
    private func postToBackend(_ request: BackendPostRequest) async throws {
        guard let url = URL(string: "\(backendAPIURL)/post/") else {
            throw URLError(.badURL)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        
        let jsonData = try JSONEncoder().encode(request)
        urlRequest.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }
    }
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
                            .foregroundStyle(.green)
                    }
                }
                // Removed UserAnnotation() - no user location circle
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
                if loc.authorization == CLAuthorizationStatus.notDetermined { loc.request() }
                let center = loc.userLocation?.coordinate ?? selectedCoord ?? fallback
                selectedCoord = center
                camera = .region(.init(center: center, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
                onCoordinateChange?(center)
            }
        }
    }
}

// MARK: - Reusable pieces

private struct PhotoTile: View {
    let image: UIImage?
    let width: CGFloat
    let height: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.brandDark)
                }
            }
            .frame(width: width, height: height)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandDark.opacity(0.40), lineWidth: 1))
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

private struct ConditionSegmentedPicker: View {
    @Binding var selection: Condition?
    @Namespace private var thumbAnimation
    
    // Single source of truth for segment metrics
    private let segmentHeight: CGFloat = 46
    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 11
    private var cornerRadius: CGFloat { segmentHeight / 2 }
    
    // Design tokens
    private let primaryColor = Color(hex: 0x00513F) // #00513F
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Condition.allCases, id: \.self) { condition in
                let isSelected = selection == condition
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = condition
                    }
                } label: {
                    Text(condition.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .frame(maxWidth: .infinity)
                        .frame(height: segmentHeight)
                        .background(
                            Group {
                                if isSelected {
                                    Capsule()
                                        .fill(primaryColor)
                                        .matchedGeometryEffect(id: "conditionThumb", in: thumbAnimation)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: segmentHeight)
        .background(
            Capsule()
                .fill(Color(.secondarySystemBackground))
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

private struct PickupModeSegmentedPicker: View {
    @Binding var selection: PickupMode?
    @Namespace private var thumbAnimation
    
    // Single source of truth for segment metrics - match condition picker
    private let segmentHeight: CGFloat = 46
    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 11
    private var cornerRadius: CGFloat { segmentHeight / 2 }
    
    // Design tokens
    private let primaryColor = Color(hex: 0x00513F) // #00513F
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(PickupMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .frame(maxWidth: .infinity)
                        .frame(height: segmentHeight)
                        .background(
                            Group {
                                if isSelected {
                                    Capsule()
                                        .fill(primaryColor)
                                        .matchedGeometryEffect(id: "pickupThumb", in: thumbAnimation)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: segmentHeight)
        .background(
            Capsule()
                .fill(Color(.secondarySystemBackground))
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

private struct ModeChips: View {
    @Binding var mode: PickupMode?
    var body: some View {
        HStack(spacing: 8) {
            chip("From Street", .street)
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

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}
