import SwiftUI
import Foundation
import MapKit
import PhotosUI
import CoreLocation
import UIKit

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
    
    @State private var activePhotoIndex: Int? = nil     // which tile (0..2)
    @State private var showCamera = false
    @State private var isPhotoPickerPresented = false
    @State private var showValidation = false
    @State private var validationText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    // Submit state for UX
    private enum SubmitState { case idle, uploading, success, error }
    @State private var submitState: SubmitState = .idle
    @State private var isSubmitting = false
    @State private var duplicateCandidate: Post?
    @State private var showToast = false
    @State private var toastText = ""
    @FocusState private var descriptionFocused: Bool

    // Layout constants
    private let sidePadding: CGFloat = 20
    private let maxWidth: CGFloat = 600
    
    // Computed properties
    private var canSubmit: Bool {
        !draftStore.photos.isEmpty && vm.condition != nil && vm.mode != nil && vm.currentCoordinate != nil
    }

    private var borderColorForDescription: Color {
        AppTheme.ColorToken.brandDark.opacity(0.20)
    }
    private var counterColor: Color {
        AppTheme.ColorToken.muted
    }

    var body: some View {
        content
            .background(Color(.systemBackground))
            .scrollDismissesKeyboard(.immediately)
            .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    descriptionFocused = false
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .onAppear { handleOnAppear() }
        .onChange(of: loc.userLocation) { newValue in
            vm.bootstrapLocation(newValue?.coordinate)
        }
        .onChange(of: vm.wantsDescription) { wants in
            if !wants {
                descriptionFocused = false
            }
        }
            .fullScreenCover(isPresented: $showCamera) {
                CameraScreen(
                    onCaptured: { image in
                        applyPickedImage(image)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCamera = false
                        }
                    },
                    onCancel: {
                        activePhotoIndex = nil
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCamera = false
                        }
                    }
                )
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItem,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: selectedPhotoItem) { newValue in
                handlePhotoPickerChange(newValue)
            }
            .onChange(of: isPhotoPickerPresented) { isPresented in
                if !isPresented { activePhotoIndex = nil }
            }
            .sheet(item: $duplicateCandidate) { candidate in
                DuplicatePostSheet(
                    post: candidate,
                    onSameItem: {
                        duplicateCandidate = nil
                        draftStore.clearDraft()
                        router.selectedTab = .feed
                        dismiss()
                        // Let the upload cover finish dismissing before the
                        // existing post's detail cover is presented.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            NotificationCenter.default.post(
                                name: .openPostDetail,
                                object: PushedPostDetail(postId: candidate.id, context: .nearby)
                            )
                        }
                    },
                    onDifferentItem: {
                        duplicateCandidate = nil
                        startSubmit(skippingDuplicateCheck: true)
                    }
                )
            }

    }

    private var content: some View {
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
    }

    @MainActor
    private func handlePhotoPickerChange(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                // Decode + downscale off the main thread; full-res library
                // photos are heavy to redraw.
                let image = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data).map(UploadDraftStore.prepareForDraft)
                }.value
                if let image {
                    await applyPickedImage(image)
                }
            }
            await MainActor.run {
                selectedPhotoItem = nil
                isPhotoPickerPresented = false
            }
        }
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
                    .foregroundStyle(AppTheme.ColorToken.muted)
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        // Placeholder
                        if vm.descriptionText.isEmpty {
                            Text("Add details about the product")
                                .foregroundStyle(AppTheme.ColorToken.mutedGray)
                                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                                .allowsHitTesting(false)
                        }

                        // Multiline editor
                        TextEditor(text: $vm.descriptionText)
                            .textInputAutocapitalization(.sentences)
                            .frame(height: 140)
                            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .scrollIndicators(.visible)
                            .focused($descriptionFocused)
                            .submitLabel(.done)
                            .onSubmit { descriptionFocused = false }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(borderColorForDescription, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .onChange(of: vm.descriptionText) { newValue in
                        if newValue.last == "\n" {
                            vm.descriptionText = String(newValue.dropLast())
                            descriptionFocused = false
                            return
                        }
                        let clamped = String(newValue.prefix(100))
                        if clamped != newValue {
                            vm.descriptionText = clamped
                        }
                    }
                    HStack {
                        Spacer()
                        Text("\(vm.descriptionText.count)/100")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(counterColor)
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
            if vm.mode == .home {
                Text("Home listing: We use your location only to show nearby users the approximate distance. Your address stays private.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.ColorToken.muted)
                    .multilineTextAlignment(.leading)
            }
            
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
            startSubmit()
        } label: {
            HStack(spacing: 8) {
                if submitState == .uploading { ProgressView().tint(AppTheme.ColorToken.primary) }
                Text(labelTextForSubmitState())
            }
            .font(AppFont.label)
            .foregroundColor(submitState == .success ? .white : AppColor.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColorForSubmitState())
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!svc.hasAuthToken || isSubmitting)
        .opacity(svc.hasAuthToken ? 1.0 : 0.5)
        .padding(.top, 8)
    }

    private func startSubmit(skippingDuplicateCheck: Bool = false) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            guard svc.hasAuthToken else {
                showValidation = true
                validationText = "You’re not signed in. Please sign in and try again."
                submitState = .error
                Haptics.play(.error)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                submitState = .idle
                return
            }
            submitState = .uploading

            // Duplicate gate: ask the server whether the same item was already
            // posted here. Any failure means "no duplicates" — never block
            // posting on a failed check.
            if skippingDuplicateCheck == false,
               let coordinate = vm.currentCoordinate,
               let candidate = await findDuplicateCandidate(coordinate: coordinate) {
                submitState = .idle
                duplicateCandidate = candidate
                return
            }

            do {
                    let postId = try await uploadWithRetry()
                    draftStore.clearDraft()
                    submitState = .success
                    Haptics.play(.success)
                    #if DEBUG
                    DLog("[SUBMIT OK] post_id=\(postId)")
                    #endif
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    submitState = .idle
                    router.selectedTab = .feed
                    dismiss()
                } catch UploadError.authenticationFailed {
                    showValidation = true
                    validationText = "Authentication failed. Please sign in again."
                    submitState = .error
                    Haptics.play(.error)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    submitState = .idle
                } catch UploadError.notAuthenticated {
                    showValidation = true
                    validationText = "You're not signed in. Please sign in and try again."
                    submitState = .error
                    Haptics.play(.error)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    submitState = .idle
                } catch UploadError.imageProcessingFailed {
                    #if DEBUG
                    DLog("[CATCH] imageProcessingFailed")
                    #endif
                    showValidation = true
                    validationText = "Image upload failed. Please try different photos."
                    submitState = .error
                    Haptics.play(.error)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    submitState = .idle
                } catch let apiError as ApiServiceError {
                    #if DEBUG
                    DLog("[CATCH] ApiServiceError: \(apiError.localizedDescription)")
                    #endif
                    showValidation = true
                    submitState = .error
                    switch apiError {
                    case .serverError:
                        validationText = "Couldn't create post. Please check location and category and try again."
                    default:
                        validationText = "Couldn't upload your item. Please try again."
                    }
                    Haptics.play(.error)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    submitState = .idle
                } catch {
                    #if DEBUG
                    DLog("[CATCH] generic error: \(error.localizedDescription)")
                    DLog("[CATCH] error type: \(type(of: error))")
                    #endif
                    showValidation = true
                    validationText = "Couldn't upload your item. Please try again."
                    submitState = .error
                    Haptics.play(.error)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    submitState = .idle
                }
            }
        }

    /// Ask the server for nearby duplicates using the pre-encoded payload
    /// from the draft store. Returns the top candidate, or nil on empty
    /// result or any failure (fail-open).
    @MainActor
    private func findDuplicateCandidate(coordinate: CLLocationCoordinate2D) async -> Post? {
        guard let base64 = await draftStore.duplicateCheckBase64() else { return nil }

        let api = ApiService(supabaseService: svc)
        do {
            let duplicates = try await api.checkDuplicatePosts(
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                imageBase64: base64
            )
            return duplicates.first
        } catch {
            #if DEBUG
            DLog("[DUP CHECK] failed (fail-open): \(error)")
            #endif
            return nil
        }
    }

    // Button state helpers
    private func labelTextForSubmitState() -> String {
        switch submitState {
        case .idle: return "Share Your Find"
        case .uploading: return "Sharing…"
        case .success: return "Your find was shared!"
        case .error: return "Try again"
        }
    }

    private func backgroundColorForSubmitState() -> Color {
        switch submitState {
        case .success:
            return AppTheme.ColorToken.primary
        case .error:
            return .orange
        case .idle, .uploading:
            return AppColor.cta
        }
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

    // MARK: - Submit Logic
    
    @MainActor
    private func submitWithDraftStore() async throws -> String {
        guard let cond = vm.condition, let m = vm.mode, canSubmit else {
            throw UploadError.invalidData
        }

        let postId = UUID()
        let session = try await svc.client.auth.session
        let userId = session.user.id
        let token = session.accessToken
        guard !token.isEmpty else { throw UploadError.notAuthenticated }

        #if DEBUG
        DLog("[SUBMIT START] postId: \(postId.uuidString)")
        DLog("[SUBMIT START] mode: \(m.backendValue)")
        DLog("[SUBMIT START] images count: \(draftStore.photos.count)")
        DLog("[SUBMIT START] hasAuthToken: \(svc.hasAuthToken)")
        DLog("[SUBMIT START] token length: \(token.count)")
        DLog("[SUBMIT START] userId: \(userId)")
        #endif

        let imageURLs = try await uploadImagesToStorage(userId: userId, postId: postId)
        let uniqueURLs = Array(NSOrderedSet(array: imageURLs)).compactMap { $0 as? URL }
        guard !uniqueURLs.isEmpty else { throw UploadError.imageProcessingFailed }

        let images = uniqueURLs.enumerated().map { index, url in
            PostImagePayload(url: url.absoluteString, order_index: index)
        }

        let modeValue = m.backendValue
        let conditionValue = cond.backendValue

        var exactWKT: String? = nil
        var approxWKT: String? = nil

        if let coord = vm.currentCoordinate {
            if modeValue == "street" {
                exactWKT = wktPoint(lng: coord.longitude, lat: coord.latitude)
            } else {
                let blurred = approx(coord, meters: 500)
                approxWKT = wktPoint(lng: blurred.longitude, lat: blurred.latitude)
            }
        }

        let payload = PostCreatePayload(
            title: "Shared item",
            description: vm.descriptionText.nilIfBlank(),
            category: "other",
            condition: conditionValue,
            mode: modeValue,
            images: images,
            exact_location: exactWKT,
            approx_location: approxWKT
        )

        let api = ApiService(supabaseService: svc)
        #if DEBUG
        DLog("[UPLOAD COMPLETE] urls: \(uniqueURLs.map { $0.absoluteString })")
        DLog("[POST payload] mode: \(modeValue)")
        DLog("[POST payload] condition: \(conditionValue)")
        DLog("[POST payload] images count: \(images.count)")
        DLog("[POST payload] exact_location: \(exactWKT ?? "nil")")
        DLog("[POST payload] approx_location: \(approxWKT ?? "nil")")
        #endif

        let createdPostId = try await fetchWithRetry(svc: svc) {
            try await api.createPost(token: token, payload: payload)
        }

        // Trigger feed refresh after successful upload
        FeedViewModel.requestFeedRefresh()

        return createdPostId
    }
    
    private func uploadImagesToStorage(userId: UUID, postId: UUID) async throws -> [URL] {
        let bucket = "item-photos"
        let options = ImageStorage.buildJPEGFileOptions()
        let photos = draftStore.photos

        // JPEGs were pre-encoded in the background when the photos were
        // added; fall back to encoding here (off the main actor) if needed.
        var payloads: [(index: Int, data: Data)] = []
        payloads.reserveCapacity(photos.count)
        for (index, image) in photos.enumerated() {
            let data = await draftStore.uploadJPEGData(at: index)
                ?? UploadDraftStore.encodeForUpload(image)
            guard let data, !data.isEmpty else {
                #if DEBUG
                DLog("[UPLOAD ERR] JPEG encoding failed for index: \(index)")
                #endif
                throw UploadError.imageProcessingFailed
            }
            payloads.append((index, data))
        }

        // Upload concurrently; order is restored from the index.
        let client = svc.client
        return try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for payload in payloads {
                group.addTask {
                    let path = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: payload.index)
                    do {
                        try await client.storage
                            .from(bucket)
                            .upload(path: path,
                                    file: payload.data,
                                    options: options)
                        #if DEBUG
                        DLog("[UPLOAD OK] \(path)")
                        #endif
                    } catch {
                        #if DEBUG
                        DLog("[UPLOAD ERR] \(path) \(error.localizedDescription)")
                        #endif
                        throw error
                    }

                    let publicURL = try client.storage
                        .from(bucket)
                        .getPublicURL(path: path)
                    return (payload.index, publicURL)
                }
            }

            var results: [(Int, URL)] = []
            results.reserveCapacity(payloads.count)
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
    private func uploadWithRetry() async throws -> String {
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
                    showPhotoActions(for: idx, hasImage: img != nil)
                }
            }
            Spacer()
        }
    }

    private func openLibrary(for index: Int) {
        if !draftStore.photos.indices.contains(index) && !draftStore.canAddPhoto {
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        activePhotoIndex = index
        selectedPhotoItem = nil
        isPhotoPickerPresented = true
    }

    private func openCamera(for index: Int) {
        if !draftStore.photos.indices.contains(index) && !draftStore.canAddPhoto {
            return
        }
        Task { @MainActor in
            let ok = await CameraSessionManager.shared.ensurePermission()
            if ok {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                CameraSessionManager.shared.configureIfNeeded()
                activePhotoIndex = index
                showCamera = true
            }
        }
    }

    private func showPhotoActions(for index: Int, hasImage: Bool) {
        let takePhotoTitle = hasImage ? "Retake Photo" : "Take Photo"

        let alert = UIAlertController(title: "Photo Options", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: takePhotoTitle, style: .default) { _ in
            openCamera(for: index)
        })

        alert.addAction(UIAlertAction(title: "Choose from Library", style: .default) { _ in
            openLibrary(for: index)
        })

        if hasImage {
            alert.addAction(UIAlertAction(title: "Remove Photo", style: .destructive) { _ in
                activePhotoIndex = nil
                draftStore.removePhoto(at: index)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.view.tintColor = UIColor(AppTheme.ColorToken.primary)

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

    @MainActor
    private func applyPickedImage(_ image: UIImage) {
        if let index = activePhotoIndex, draftStore.photos.indices.contains(index) {
            draftStore.replacePhoto(at: index, with: image)
        } else if draftStore.canAddPhoto {
            draftStore.insertPrimary(image)
        }
        activePhotoIndex = nil
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
        // `required` remains for semantic clarity, but we no longer show the red asterisk.
        Text(text)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
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

@MainActor
final class UploadFindViewModel: ObservableObject {
    @Published var condition: Condition? = .needsFixing  // default to 'Needs Fixing'
    @Published var mode: PickupMode? = .street           // default selected (street)
    @Published var wantsDescription = false
    @Published var descriptionText = ""

    // Map state
    @Published var camera: MapCameraPosition = {
        let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        if let cached = LocationService.shared.lastKnownFromSystem() {
            return .region(MKCoordinateRegion(
                center: cached.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
        return .region(MKCoordinateRegion(
            center: fallback,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
    }()
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


// Note: Using PostCreatePayload from ApiService.swift as single source of truth

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

// Helper to format a WKT POINT string with longitude first, then latitude
func wktPoint(lng: Double, lat: Double) -> String {
    let lonStr = String(format: "%.6f", lng)
    let latStr = String(format: "%.6f", lat)
    return "POINT(\(lonStr) \(latStr))"
}

// MARK: - Supabase uploader with proper backend integration

struct SupabaseUploader: FindUploader {
    let supabaseService: SupabaseService
    let backendAPIURL: String
    let bearerToken: String

    func uploadPostDraft(_ draft: PostDraft) async throws {
        // Step 1: Upload each image to Supabase Storage
        var uploadedImages: [PostImagePayload] = []

        // Generate a single postId used for BOTH storage keys and API payload
        let postId = UUID()

        for (index, imageRecord) in draft.images.enumerated() {
            guard let image = imageRecord.localImage else { continue }

            // Upload to Supabase Storage with consistent path:
            // post-content/posts/<userId>/<postId>/<index>.jpg
            let publicURL = try await uploadImageToSupabaseStorage(image, postId: postId, index: index)

            uploadedImages.append(
                PostImagePayload(url: publicURL, order_index: index)
            )
        }

        // Step 2: Prepare location data (WKT strings)
        let (exactPoint, approxPoint) = prepareLocationData(draft)

        // Step 3: Create PostCreate payload using the same postId
        let postCreate = PostCreatePayload(
            title: "Free item",
            description: draft.description?.nilIfBlank(),
            category: "other",
            condition: draft.condition.backendValue,
            mode: draft.mode.backendValue,
            images: uploadedImages,
            exact_location: exactPoint,
            approx_location: approxPoint
        )

        // Step 4: POST to your Flask backend
        try await postToBackend(postCreate)
    }
    
    private func uploadImageToSupabaseStorage(_ image: UIImage, postId: UUID, index: Int) async throws -> String {
        // 1) Resize and compress image
        let resizedImage = resizeImage(image, maxWidth: 1600)
        guard let data = resizedImage.jpegData(compressionQuality: 0.8), data.count > 0 else {
            throw UploadError.imageEncodingFailed
        }
        
        // 2) Get user ID from Supabase session
        let session = try await supabaseService.client.auth.session
        let userId = session.user.id
        if session.accessToken.isEmpty { throw UploadError.notAuthenticated }

        let bucket = "item-photos"
        let options = ImageStorage.buildJPEGFileOptions()
        let filename = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: index)

        _ = try await supabaseService.client.storage
            .from(bucket)
            .upload(path: filename, file: data, options: options)
        #if DEBUG
        DLog("[UPLOAD KEY] \(filename)")
        DLog("[UPLOAD OK] \(filename)")
        #endif
        
        // 5) Public bucket: get public URL and skip verification
        let publicURL = try supabaseService.client.storage
            .from(bucket)
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
    
    private func prepareLocationData(_ draft: PostDraft) -> (exact: String?, approx: String?) {
        guard let c = draft.coordinate else { return (nil, nil) }
        switch draft.mode {
        case .street:
            return (exact: wktPoint(lng: c.longitude, lat: c.latitude), approx: nil)
        case .home:
            let a = approx(c, meters: 500)
            return (exact: nil, approx: wktPoint(lng: a.longitude, lat: a.latitude))
        }
    }
    
    private func postToBackend(_ request: PostCreatePayload) async throws {
        guard let url = URL(string: "\(backendAPIURL)/post") else {
            throw URLError(.badURL)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
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
            .onChange(of: camera, initial: false) { oldCamera, newCamera in
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

extension String {
    func nilIfBlank() -> String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// Keep old references working
typealias AddTrashFlow = AddTrashView
