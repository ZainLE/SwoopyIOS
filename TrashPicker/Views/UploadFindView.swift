import SwiftUI
import MapKit
import PhotosUI
import CoreLocation

// MARK: - UploadFindView

struct UploadFindView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var draftStore: UploadDraftStore
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var vm = UploadFindViewModel()
    
    // Static flag to ensure appearance is only configured once
    private static var hasConfiguredAppearance = false
    
    // Configure segmented control appearance once
    init() {
        // Configure appearance only once globally
        if !Self.hasConfiguredAppearance {
            UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(AppTheme.ColorToken.primary)
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
    // Submit state for UX
    private enum SubmitState { case idle, uploading, success, error }
    @State private var submitState: SubmitState = .idle
    @State private var showToast = false
    @State private var toastText = ""

    // Layout constants
    private let sidePadding: CGFloat = 20
    private let maxWidth: CGFloat = 600
    
    // Computed properties
    private var canSubmit: Bool {
        !draftStore.photos.isEmpty && vm.condition != nil && vm.mode != nil && vm.currentCoordinate != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 16)
                photoSection
                conditionSection
                descriptionSection
                pickupSection
                ctaButton
            }
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, sidePadding)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .scrollDismissesKeyboard(.immediately)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { handleOnAppear() }
        .onChange(of: loc.userLocation) { _, newValue in
            vm.bootstrapLocation(newValue?.coordinate)
        }
        .fullScreenCover(isPresented: $showCamera) { cameraView }
        .sheet(isPresented: $showPicker) { photoPickerView }
        .overlay(alignment: .bottom) { successToastOverlay }
    }

    // MARK: - Subviews

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Provide image", required: true)
            helper("Upload or take up to 3 pictures of your item (front, detail, size). Clear photos help others decide quickly.")
            photoRow
            if showValidation && draftStore.photos.isEmpty {
                validationHint("Please add at least one photo.")
            }
        }
    }

    private var conditionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Condition", required: true)
            ConditionSegmentedPicker(selection: $vm.condition)
            
            if showValidation && vm.condition == nil {
                validationHint("Please select a condition.")
            }
        }
        .padding(.top, 16)
    }


    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $vm.wantsDescription.animation()) {
                Text("Provide Description")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
            .tint(AppTheme.ColorToken.brandDark)  // Updated to theme
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
                        .overlay(RoundedRectangle(cornerRadius: 99).stroke(AppTheme.ColorToken.brandDark.opacity(0.20), lineWidth: 1))
                    
                    HStack {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.ColorToken.brandDark)  // Updated to theme
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(AppTheme.ColorToken.brandDark.opacity(0.1))  // Updated to theme
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private var pickupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Pickup Location", required: true)
            PickupModeSegmentedPicker(selection: $vm.mode)
            mapCard
            
            if showValidation && !vm.hasChosenModeOrLocation {
                validationHint("Please confirm your pickup mode.")
            }
        }
        .padding(.top, 16)
    }


    private var ctaButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if !canSubmit {
                showValidation = true
                validationText = "Please complete required fields."
                return
            }
            Task {
                // Require auth before starting upload
                guard svc.hasAuthToken else {
                    showValidation = true
                    validationText = "You’re not signed in. Please sign in and try again."
                    submitState = .error
                    toastText = "You’re not signed in. Please sign in and try again."
                    showToast = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    showToast = false
                    submitState = .idle
                    return
                }
                submitState = .uploading
                do {
                    try await uploadWithRetry()
                    draftStore.clearDraft()
                    // Success: flash green + toast, then route to Feed
                    submitState = .success
                    toastText = "Your find was shared!"
                    showToast = true
                    showSuccessToast()
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    showToast = false
                    router.selectedTab = .feed
                    dismiss()
                } catch UploadError.authenticationFailed {
                    showValidation = true
                    validationText = "Authentication failed. Please sign in again."
                    submitState = .error
                    toastText = "Authentication failed."
                    showToast = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    showToast = false
                    submitState = .idle
                } catch UploadError.notAuthenticated {
                    showValidation = true
                    validationText = "You’re not signed in. Please sign in and try again."
                    submitState = .error
                    toastText = "You’re not signed in. Please sign in and try again."
                    showToast = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    showToast = false
                    submitState = .idle
                } catch UploadError.imageProcessingFailed {
                    #if DEBUG
                    print("[CATCH] imageProcessingFailed")
                    #endif
                    showValidation = true
                    validationText = "Image upload failed. Please try different photos."
                    submitState = .error
                    toastText = "Image upload failed."
                    showToast = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    showToast = false
                    submitState = .idle
                } catch {
                    #if DEBUG
                    print("[CATCH] generic error:", error.localizedDescription)
                    print("[CATCH] error type:", type(of: error))
                    #endif
                    showValidation = true
                    validationText = "Upload failed. Please try again."
                    submitState = .error
                    toastText = "Upload failed. Please try again."
                    showToast = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    showToast = false
                    submitState = .idle
                }
            }
        } label: {
            HStack(spacing: 8) {
                if submitState == .uploading {
                    ProgressView().tint(AppTheme.ColorToken.primary)
                }
                Text("Share Your Find")
            }
            .font(AppFont.label)
            .foregroundColor(AppColor.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(submitState == .success ? AppColor.darkGreen : AppColor.cta)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!svc.hasAuthToken || submitState == .uploading)
        .opacity(svc.hasAuthToken ? 1.0 : 0.5)
        .padding(.top, 8)
    }

    // MARK: - Helper Views and Logic

    private func handleOnAppear() {
        if loc.authorization == CLAuthorizationStatus.notDetermined {
            loc.request()
        }
        Task {
            vm.bootstrapLocation(loc.userLocation?.coordinate)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Upload your find")
                .font(.headline.weight(.semibold))
                .foregroundColor(AppTheme.ColorToken.primary)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                draftStore.clearDraft()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(AppTheme.ColorToken.brandDark)
            }
        }
    }




    private var cameraView: some View {
        CameraCaptureView { image in
            if let img = image {
                if let index = showActionForTile, draftStore.photos.indices.contains(index) {
                    draftStore.replacePhoto(at: index, with: img)
                } else if draftStore.canAddPhoto {
                    draftStore.insertPrimary(img)
                }
            }
        }
        .ignoresSafeArea(.all)
        .background(Color.black)
    }

    private var photoPickerView: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Text("Choose Photo")
                .font(.headline)
                .padding()
        }
        .onChange(of: selectedPhotoItem) {
            Task {
                if let newItem = selectedPhotoItem,
                   let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        if let index = showActionForTile, draftStore.photos.indices.contains(index) {
                            draftStore.replacePhoto(at: index, with: image)
                        } else if draftStore.canAddPhoto {
                            draftStore.insertPrimary(image)
                        }
                        selectedPhotoItem = nil
                        showPicker = false
                    }
                }
            }
        }
    }
    
    // MARK: - Submit Logic
    
    @MainActor
    private func submitWithDraftStore() async throws {
        guard let cond = vm.condition, let m = vm.mode, canSubmit else { 
            throw UploadError.invalidData
        }
        
        // Generate a single draftId used for storage keys
        let draftId = UUID().uuidString
        
        #if DEBUG
        print("[SUBMIT START] draftId:", draftId)
        print("[SUBMIT START] mode:", m.backendValue)
        print("[SUBMIT START] images count:", draftStore.photos.count)
        print("[SUBMIT START] hasAuthToken:", svc.hasAuthToken)
        print("[SUBMIT START] token length:", svc.session?.accessToken.count ?? 0)
        #endif
        
        // First upload images to storage and get URLs
        let imageURLs = try await uploadImagesToStorage(draftId: draftId)
        
        // Convert to PostImage format
        let postImages = imageURLs.enumerated().map { index, url in
            PostImage(url: url, orderIndex: index)
        }
        
        // Build location arrays [lng, lat]
        let exactLocationArray: [Double]?
        let approxLocationArray: [Double]?
        
        if let coord = vm.currentCoordinate {
            if m == .street {
                exactLocationArray = [coord.longitude, coord.latitude]
                approxLocationArray = nil
            } else {
                let a = approx(coord, meters: 500)
                exactLocationArray = nil
                approxLocationArray = [a.longitude, a.latitude]
            }
        } else {
            exactLocationArray = nil
            approxLocationArray = nil
        }
        
        // Create PostCreate object
        let postCreate = PostCreate(
            title: "Trash item", // You might want to make this configurable
            description: vm.descriptionText.isEmpty ? nil : vm.descriptionText,
            category: "general", // Default category
            condition: ItemCondition(rawValue: cond.backendValue) ?? .good,
            mode: ItemMode(rawValue: m.backendValue) ?? .street,
            images: postImages,
            exactLocation: exactLocationArray,
            approxLocation: approxLocationArray
        )
        
        // Use ApiService to create the post
        let api = ApiService(supabaseService: svc)
        #if DEBUG
        print("[UPLOAD COMPLETE] images:", postImages.map { $0.url })
        print("[POST payload] title:", postCreate.title)
        print("[POST payload] mode:", postCreate.mode.rawValue)
        print("[POST payload] condition:", postCreate.condition.rawValue)
        print("[POST payload] images count:", postCreate.images.count)
        print("[POST payload] exactLocation:", postCreate.exactLocation ?? "nil")
        print("[POST payload] approxLocation:", postCreate.approxLocation ?? "nil")
        #endif
        do {
            let postId = try await fetchWithRetry(svc: svc) {
                try await api.createPost(postCreate)
            }
            #if DEBUG
            print("[API OK] /post returned postId:", postId)
            #endif
        } catch {
            #if DEBUG
            print("[API ERR] /post:", error.localizedDescription)
            print("[API ERR] error type:", type(of: error))
            if let apiError = error as? ApiServiceError {
                print("[API ERR] ApiServiceError:", apiError.errorDescription ?? "unknown")
            }
            #endif
            throw error
        }
    }
    
    private func uploadImagesToStorage(draftId: String) async throws -> [URL] {
        // 0) Require an authenticated session (for user id + RLS)
        let session = try await svc.client.auth.session
        let userId = session.user.id
        let token = session.accessToken
        if token.isEmpty { throw UploadError.notAuthenticated }

        // 2) Upload each photo and collect URLs
        var urls: [URL] = []
        urls.reserveCapacity(draftStore.photos.count)

        for (index, image) in draftStore.photos.enumerated() {
            // Convert UIImage -> JPEG data
            guard let data = image.jpegData(compressionQuality: 0.8), data.count > 0 else {
                #if DEBUG
                print("[UPLOAD ERR] JPEG encoding failed for index:", index)
                #endif
                throw UploadError.imageProcessingFailed
            }

            // Path: posts/<userId>/<draftId>/<index>.jpg
            let path = "posts/\(userId)/\(draftId)/\(index).jpg"

            // 3) Upload to your Supabase Storage bucket (post-content)
            //    upsert:true so re-tries don't fail if same path is used
            do {
                try await svc.client.storage
                    .from("post-content")
                    .upload(path: path,
                            file: data,
                            options: .init(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
                #if DEBUG
                print("[UPLOAD OK]", path)
                #endif
            } catch {
                #if DEBUG
                print("[UPLOAD ERR]", path, error.localizedDescription)
                #endif
                throw error
            }

            // 4) Public bucket: derive URL via SDK and skip verification
            let publicURL = try svc.client.storage
                .from("post-content")
                .getPublicURL(path: path)
            #if DEBUG
            print("[UPLOAD URL]", publicURL.absoluteString)
            #endif
            urls.append(publicURL)
        }

        return urls
    }
    
    private func uploadWithRetry() async throws {
        try await submitWithDraftStore()
    }
    
    private func showSuccessToast() {
        // Trigger success haptic
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var successToastOverlay: some View {
        Group {
            if showToast {
                Text(toastText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showToast)
    }

    // MARK: Sections

    private var photoRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Show photos + one extra empty frame (max 3 total)
            ForEach(0..<min(draftStore.photos.count + 1, 3), id: \.self) { idx in
                let img = draftStore.photo(at: idx)
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
                    self.draftStore.removePhoto(at: index)
                }
            })
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        // Set app color
        alert.view.tintColor = UIColor(AppTheme.ColorToken.primary)
        
        // Present the alert with better error handling
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }),
                  let rootViewController = window.rootViewController else {
                return
            }
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
                    .foregroundStyle(AppTheme.ColorToken.mutedGray)
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
        Text(text).font(.caption).foregroundStyle(AppTheme.ColorToken.mutedGray)
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
    @Published var condition: Condition? = .needsFixing  // default to 'Needs Fixing'
    @Published var mode: PickupMode? = .street           // default selected (street)
    @Published var wantsDescription = false
    @Published var descriptionText = "" { didSet { if descriptionText.count > 100 { descriptionText = String(descriptionText.prefix(100)) } } }

    // Map state
    @Published var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                                                                          span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var addressText: String = "Locating address…"
    
    private var geocodeTask: Task<Void, Never>?

    var hasChosenModeOrLocation: Bool { mode != nil }

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

}

enum UploadError: Error {
    case invalidData
    case imageEncodingFailed
    case networkError
    case authenticationFailed
    case notAuthenticated
    case imageProcessingFailed
}

enum Condition: CaseIterable, Hashable, Identifiable {
    case needsFixing, good, excellent, likeNew
    var id: Self { self }
    var title: String {
        switch self {
        case .needsFixing: return "Needs Fixing"
        case .good:        return "Good"
        case .excellent:   return "Excellent"
        case .likeNew:     return "Like New"
        }
    }
    
    // Backend mapping - matches Flask API spec
    var backendValue: String {
        switch self {
        case .needsFixing: return "bad"        // "Needs Fixing" = bad
        case .good:        return "good"       // "Good" = good  
        case .excellent:   return "excellent" // "Excellent" = excellent
        case .likeNew:     return "excellent" // "Like New" = excellent (same as excellent)
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


// Note: Using PostCreate from ApiService.swift as single source of truth

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

// MARK: - Supabase uploader with proper backend integration

struct SupabaseUploader: FindUploader {
    let supabaseService: SupabaseService
    let backendAPIURL: String
    let bearerToken: String

    func uploadPostDraft(_ draft: PostDraft) async throws {
        // Step 1: Upload each image to Supabase Storage
        var uploadedImages: [PostImage] = []

        // Generate a single postId used for BOTH storage keys and API payload
        let postId = UUID().uuidString

        for (index, imageRecord) in draft.images.enumerated() {
            guard let image = imageRecord.localImage else { continue }

            // Upload to Supabase Storage with consistent path:
            // post-content/posts/<userId>/<postId>/<index>.jpg
            let publicURL = try await uploadImageToSupabaseStorage(image, postId: postId, index: index)

            uploadedImages.append(
                PostImage(url: URL(string: publicURL)!, orderIndex: index)
            )
        }

        // Step 2: Prepare location data as arrays
        let (exactArray, approxArray) = prepareLocationData(draft)

        // Step 3: Create PostCreate payload using arrays and the same postId
        let postCreate = PostCreate(
            title: "Free item",
            description: draft.description,
            category: "other",
            condition: ItemCondition(rawValue: draft.condition.backendValue)!,
            mode: ItemMode(rawValue: draft.mode.backendValue)!,
            images: uploadedImages,
            exactLocation: exactArray,
            approxLocation: approxArray
        )

        // Step 4: POST to your Flask backend
        try await postToBackend(postCreate)
    }
    
    private func uploadImageToSupabaseStorage(_ image: UIImage, postId: String, index: Int) async throws -> String {
        // 1) Resize and compress image
        let resizedImage = resizeImage(image, maxWidth: 1600)
        guard let data = resizedImage.jpegData(compressionQuality: 0.8), data.count > 0 else {
            throw UploadError.imageEncodingFailed
        }
        
        // 2) Get user ID from Supabase session
        let session = try await supabaseService.client.auth.session
        let userId = session.user.id
        if session.accessToken.isEmpty { throw UploadError.notAuthenticated }
        
        // 3) Generate storage path: posts/<userId>/<postId>/<index>.jpg
        let filename = "posts/\(userId)/\(postId)/\(index).jpg"
        
        // 4) Upload to Supabase Storage bucket "post-content"
        _ = try await supabaseService.client.storage
            .from("post-content")
            .upload(path: filename, file: data, options: .init(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
        #if DEBUG
        print("[UPLOAD OK]", filename)
        #endif
        
        // 5) Public bucket: get public URL and skip verification
        let publicURL = try supabaseService.client.storage
            .from("post-content")
            .getPublicURL(path: filename)
        
        return publicURL.absoluteString
    }
    
    private func resizeImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let size = image.size
        if size.width <= maxWidth {
            return image
        }
        
        let aspectRatio = size.height / size.width
        let newWidth = maxWidth
        let newHeight = newWidth * aspectRatio
        let newSize = CGSize(width: newWidth, height: newHeight)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    private func prepareLocationData(_ draft: PostDraft) -> (exact: [Double]?, approx: [Double]?) {
        guard let c = draft.coordinate else { return (nil, nil) }
        switch draft.mode {
        case .street:
            // Array format: [lng, lat]
            return (exact: [c.longitude, c.latitude], approx: nil)
        case .home:
            let a = approx(c, meters: 500)
            return (exact: nil, approx: [a.longitude, a.latitude])
        }
    }
    
    private func postToBackend(_ request: PostCreate) async throws {
        guard let url = URL(string: "\(backendAPIURL)/post") else {
            throw URLError(.badURL)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        
        let jsonData = try JSONEncoder().encode(request)
        urlRequest.httpBody = jsonData
        
        // Ensure this backend call also benefits from auth refresh + retry
        let (_, response): (Data, URLResponse) = try await fetchWithRetry(svc: supabaseService) {
            try await URLSession.shared.data(for: urlRequest)
        }
        
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
                        .foregroundStyle(AppTheme.ColorToken.primary.opacity(0.20))
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
                        .foregroundStyle(AppTheme.ColorToken.primary)
                }
            }
            .frame(width: width, height: height)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.ColorToken.primary.opacity(0.40), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ChipGroup<Item: CaseIterable & Hashable>: View where Item.AllCases == [Item] {
    let items: Item.AllCases
    @Binding var selection: Item?
    let label: (Item) -> String

    var body: some View {
        FlexibleRow(spacing: 8) {
            // Disambiguate to the non-Binding ForEach initializer
            SwiftUI.ForEach(items as [Item], id: \.self) { (item: Item) in
                let isOn = selection == item
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(isOn ? .white : AppTheme.ColorToken.darkGreen)
                        .background(
                            Capsule().fill(isOn ? AppTheme.ColorToken.darkGreen : .clear)
                        )
                        .overlay(
                            Capsule().stroke(AppTheme.ColorToken.darkGreen, lineWidth: isOn ? 0 : 1)
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
                                        .fill(AppTheme.ColorToken.primary)
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
                                        .fill(AppTheme.ColorToken.primary)
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
                .foregroundStyle(isOn ? .white : AppTheme.ColorToken.primary)
                .background(Capsule().fill(isOn ? AppTheme.ColorToken.primary : .clear))
                .overlay(Capsule().stroke(AppTheme.ColorToken.primary, lineWidth: isOn ? 0 : 1))
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
                .foregroundStyle(AppTheme.ColorToken.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(AppTheme.ColorToken.accent.opacity(enabled ? 1 : 0.6))
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


