import SwiftUI
import MapKit
import CoreLocation
import UIKit
import PhotosUI

// MARK: - Model saved locally
struct TrashDraft: Codable {
    let id: UUID
    let description: String?
    let condition: String                   // "needs_fix" | "usable" | "good" | "like_new"
    let mode: String                        // "street" | "home"
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    let photos: [String]                    // file names relative to the draft folder
}

// MARK: - Add View

struct AddTrashView: View {
    @EnvironmentObject var loc: LocationManager
    @Environment(\.dismiss) private var dismiss

    // UI
    @State private var showValidation = false
    @State private var validationText = ""
    @State private var showSuccess = false
    @State private var saving = false

    // Camera / library
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showSourceSheet = false
    @State private var didAutoOpenCamera = false   // auto-open once on first visit

    // Fields
    @State private var photos: [UIImage] = []      // up to 3
    @State private var wantsDescription = false
    @State private var descriptionText = ""        // <= 100 chars
    @State private var condition = "good"          // "needs_fix" | "usable" | "good" | "like_new"
    @State private var mode = "street"             // "street" | "home"

    // Map
    @State private var coord: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(
        .init(center: .init(latitude: 41.387, longitude: 2.170),
              span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
    )

    var body: some View {
        NavigationStack {
            Form {
                // PHOTOS
                Section("Photos (max 3)") {
                    AddPhotoStrip(
                        photos: $photos,
                        onRequestSource: {
                            if photos.count < 3 { showSourceSheet = true }
                        }
                    )
                    .listRowInsets(EdgeInsets())
                }

                // CONDITION + MODE
                Section {
                    LabeledContent("Condition") {
                        Picker("", selection: $condition) {
                            Text("Need Fix").tag("needs_fix")
                            Text("Usable").tag("usable")
                            Text("Good").tag("good")
                            Text("Like New").tag("like_new")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                    }

                    LabeledContent("Location Mode") {
                        Picker("", selection: $mode) {
                            Text("From Street").tag("street")
                            Text("From Home").tag("home")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                    }
                }

                // DESCRIPTION (click-to-expand dot)
                Section {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeInOut) { wantsDescription.toggle() }
                        } label: {
                            Circle()
                                .fill(wantsDescription ? .green : .secondary.opacity(0.35))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.quaternary, lineWidth: 1))
                                .accessibilityLabel("Toggle description")
                        }
                        Text("Provide description")
                            .font(.callout)
                        Spacer()
                    }

                    if wantsDescription {
                        ZStack(alignment: .topLeading) {
                            if descriptionText.isEmpty {
                                Text("Up to 100 characters…")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                            }
                            TextEditor(text: $descriptionText)
                                .frame(minHeight: 80, maxHeight: 120)
                                .onChange(of: descriptionText) { new in
                                    if new.count > 100 { descriptionText = String(new.prefix(100)) }
                                }
                        }
                    }
                }

                // MAP
                AddLocationSection(camera: $camera, coord: $coord, mode: $mode)
                    .environmentObject(loc)

                // SUBMIT
                Section {
                    Button(action: validateAndSave) {
                        HStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.up.fill")
                            Text("Upload")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(saving)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) {
                if showSuccess {
                    Label("Saved locally", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(), value: showSuccess)
            .navigationTitle("Add Spot")

            // Camera: true full screen
            .fullScreenCover(isPresented: $showCamera) {
                AddCameraCapture { image in
                    if let image, photos.count < 3 { photos.append(image) }
                }
                .ignoresSafeArea()
            }

            // Library (multi-select up to remaining)
            .sheet(isPresented: $showLibrary) {
                AddPhotoLibraryPicker(selectionLimit: max(0, 3 - photos.count)) { imgs in
                    let space = max(0, 3 - photos.count)
                    photos.append(contentsOf: imgs.prefix(space))
                }
            }

            // Source chooser
            .confirmationDialog("Add a photo", isPresented: $showSourceSheet, titleVisibility: .visible) {
                Button("Take Photo") { showCamera = true }
                Button("Choose from Library") { showLibrary = true }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear {
            if loc.authorization == .notDetermined { loc.request() }
            if let c = loc.userLocation?.coordinate {
                camera = .region(.init(center: c, span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))
            }
            // Auto-open camera once on first visit to Add tab
            if !didAutoOpenCamera && photos.isEmpty {
                didAutoOpenCamera = true
                showCamera = true
            }
        }
        .alert("Can't Save", isPresented: $showValidation) {
            Button("OK", role: .cancel) {}
        } message: { Text(validationText) }
    }

    // MARK: Validation + Local save

    private func validateAndSave() {
        guard !photos.isEmpty else {
            validationText = "Please add at least one photo."
            showValidation = true; return
        }
        guard let c = coord else {
            validationText = "Please select a location on the map or use current location."
            showValidation = true; return
        }
        Task { await saveToLocal(at: c) }
    }

    private func saveToLocal(at coordinate: CLLocationCoordinate2D) async {
        saving = true
        defer { saving = false }

        do {
            let id = UUID()
            // Draft dir
            let draftsDir = try draftsDirectory()
            let draftDir = draftsDir.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)

            // Save photos (cap at 3)
            var photoNames: [String] = []
            for (idx, img) in photos.prefix(3).enumerated() {
                let name = "photo_\(idx+1).jpg"
                let url = draftDir.appendingPathComponent(name)
                let data = img.jpegData(compressionQuality: 0.85) ?? Data()
                try data.write(to: url, options: .atomic)
                photoNames.append(name)
            }

            // Build draft
            let desc = wantsDescription ? descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let finalDesc = desc.isEmpty ? nil : String(desc.prefix(100))
            let draft = TrashDraft(
                id: id,
                description: finalDesc,
                condition: condition,
                mode: mode,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                createdAt: Date(),
                photos: photoNames
            )

            // Save JSON
            let jsonURL = draftDir.appendingPathComponent("draft.json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(draft).write(to: jsonURL, options: .atomic)

            // Reset form
            photos.removeAll()
            wantsDescription = false
            descriptionText = ""
            condition = "good"

            showSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showSuccess = false
                dismiss()
            }
        } catch {
            validationText = error.localizedDescription
            showValidation = true
        }
    }

    private func draftsDirectory() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("Drafts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

// MARK: - Photo Strip (bigger tiles + hide "+" after 3 + chooser)

// MARK: - Photo Strip (robust: stable pairs + LazyHStack)

private struct AddPhotoStrip: View {
    @Binding var photos: [UIImage]
    var onRequestSource: () -> Void

    private let tile: CGFloat = 140 // bigger boxes

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                // "+" tile (hidden when full)
                if photos.count < 3 {
                    Button(action: onRequestSource) {
                        AddPhotoAddTile(hasPhotos: !photos.isEmpty, size: tile)
                    }
                    .buttonStyle(.plain)
                }

                // ✅ Use a stable value array so the compiler doesn't see us
                // mutating the same array we're iterating.
                ForEach(stablePairs, id: \.index) { pair in
                    PhotoTile(image: pair.image, size: tile) {
                        remove(at: pair.index)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // Build once per render: [(index, image)]
    private var stablePairs: [(index: Int, image: UIImage)] {
        var result: [(Int, UIImage)] = []
        result.reserveCapacity(photos.count)
        for i in photos.indices { result.append((i, photos[i])) }
        return result
    }

    private func remove(at i: Int) {
        guard photos.indices.contains(i) else { return }
        withAnimation(.easeInOut) { photos.remove(at: i) }
    }
}

private struct PhotoTile: View {
    let image: UIImage
    let size: CGFloat
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .padding(6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct AddPhotoAddTile: View {
    var hasPhotos: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: size, height: size)

            Image(systemName: hasPhotos ? "plus" : "camera.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .padding(18)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }
}

// MARK: - Camera (full screen, no crop UI)

private struct AddCameraCapture: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: AddCameraCapture
        init(_ parent: AddCameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage]) as? UIImage   // no square editor
            parent.onCapture(img)
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
            picker.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.delegate = context.coordinator
        p.sourceType = .camera
        p.allowsEditing = false
        p.modalPresentationStyle = .fullScreen
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

// MARK: - Library (multi-select up to remaining)

private struct AddPhotoLibraryPicker: UIViewControllerRepresentable {
    var selectionLimit: Int
    var onImages: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .images
        cfg.selectionLimit = selectionLimit
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: AddPhotoLibraryPicker
        init(_ parent: AddPhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { picker.dismiss(animated: true); return }
            let g = DispatchGroup()
            var imgs: [UIImage] = []
            for r in results where r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                g.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage { imgs.append(img) }
                    g.leave()
                }
            }
            g.notify(queue: .main) {
                self.parent.onImages(imgs)
                picker.dismiss(animated: true)
            }
        }
    }
}

// MARK: - Location section (500 m privacy circle in Home mode)

private struct AddLocationSection: View {
    @EnvironmentObject var loc: LocationManager
    @Binding var camera: MapCameraPosition
    @Binding var coord: CLLocationCoordinate2D?
    @Binding var mode: String     // "street" | "home"

    private var isHome: Bool { mode == "home" }

    var body: some View {
        Section("Location") {
            if !coordLabel.isEmpty {
                Text(coordLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            AddMapPicker(camera: $camera, selected: $coord, isHome: isHome, userCoord: loc.userLocation?.coordinate)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

            Button {
                loc.requestOnce { c in
                    guard let c else { return }
                    coord = c
                    withAnimation(.easeInOut(duration: 0.35)) {
                        camera = .region(.init(center: c, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
                    }
                }
            } label: {
                Label(isHome ? "Use Home Area" : "Use Current Location", systemImage: "location")
            }

            if isHome {
                Text("We use your location only to show nearby users the approximate distance. Your address stays private.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var coordLabel: String {
        if mode == "home" { return "" }                                // hide label in Home mode
        guard let c = coord else { return "Tap the map to drop a pin" }
        return String(format: "Lat %.5f, Lon %.5f", c.latitude, c.longitude)
    }
}

private struct AddMapPicker: View {
    @Binding var camera: MapCameraPosition
    @Binding var selected: CLLocationCoordinate2D?
    var isHome: Bool
    var userCoord: CLLocationCoordinate2D?

    var displayCenter: CLLocationCoordinate2D? {
        isHome ? (userCoord ?? selected) : selected
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: .all) {
                if isHome, let c = displayCenter {
                    MapCircle(center: c, radius: 500)
                        .foregroundStyle(Color.blue.opacity(0.16))
                        .stroke(.blue.opacity(0.45), lineWidth: 2)
                    UserAnnotation()
                } else {
                    if let c = selected {
                        Annotation("Selected", coordinate: c) {
                            Image(systemName: "mappin.circle.fill").font(.title2)
                        }
                    }
                    UserAnnotation()
                }
            }
            .transaction { $0.disablesAnimations = true }
            .onTapGesture { pt in
                guard !isHome else { return }           // exact pin only in Street mode
                if let c = proxy.convert(pt, from: .local) { selected = c }
            }
        }
    }
}
