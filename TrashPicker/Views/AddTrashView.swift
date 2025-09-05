import SwiftUI
import MapKit
import UIKit

struct AddTrashView: View {
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var loc: LocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var showValidation = false
    @State private var validationText = ""
    @State private var showSuccess = false

    @State private var photo: UIImage?
    @State private var title = ""
    @State private var category = "Other"
    @State private var city = ""
    @State private var coord: CLLocationCoordinate2D?   // selected pin

    // Camera is used only inside the picker sheet, not in the form
    @State private var pickerCamera: MapCameraPosition = .region(
        .init(center: .init(latitude: 41.387, longitude: 2.170),
              span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
    )

    @State private var saving = false
    @State private var error: String?
    @State private var showMapPicker = false

    var body: some View {
        NavigationStack {
            Form {
                PhotoSection(photo: $photo)

                DetailsSection(title: $title, category: $category, city: $city)

                // ✅ Snapshot (no live map in the form) → zero typing jank
                LocationSection(
                    coord: $coord,
                    openPicker: { openPicker() },
                    useCurrent: { useCurrentLocation() }
                )

                // Upload row beneath Location
                Section {
                    Button(action: validateAndSave) {
                        Label("Upload", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(saving)

                    if let e = error {
                        Text(e).foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) {
                if showSuccess {
                    Label("Uploaded successfully", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(), value: showSuccess)
            .navigationTitle("Add Spot")
            .sheet(isPresented: $showMapPicker) {
                MapPickerSheet(camera: $pickerCamera, coord: $coord) { showMapPicker = false }
                    .environmentObject(loc)
            }
        }
        .onAppear {
            if let c = loc.userLocation?.coordinate {
                pickerCamera = .region(.init(center: c, span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))
            } else {
                loc.request()
            }
        }
        .alert("Can't Upload", isPresented: $showValidation) {
            Button("OK", role: .cancel) {}
        } message: { Text(validationText) }
    }

    // MARK: - Actions

    private func openPicker() {
        if let c = coord {
            pickerCamera = .region(.init(center: c, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        } else if let c = loc.userLocation?.coordinate {
            pickerCamera = .region(.init(center: c, span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))
        }
        showMapPicker = true
    }

    private func useCurrentLocation() {
        loc.requestOnce { c in
            guard let c else { return }
            DispatchQueue.main.async {             // ensure snapshot refreshes immediately
                coord = c
            }
        }
    }

    private func validateAndSave() {
        if photo == nil { validationText = "Please add a photo."; showValidation = true; return }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { validationText = "Please enter a title."; showValidation = true; return }
        if city.trimmingCharacters(in: .whitespaces).isEmpty { validationText = "Please enter the city/neighborhood."; showValidation = true; return }
        if coord == nil { validationText = "Please select a location on the map or use current location."; showValidation = true; return }
        Task { await save() }
    }

    private func save() async {
        guard let img = photo, let c = coord else { return }
        saving = true
        defer { saving = false }
        do {
            try await ck.createTrash(
                image: img,
                title: title.isEmpty ? "Trash" : title,
                category: category,
                coordinate: c,
                city: city
            )
            photo = nil; title = ""; city = ""; coord = nil
            await ck.fetchFeed()
            showSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showSuccess = false
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Subviews

    private struct PhotoSection: View {
        @Binding var photo: UIImage?
        var body: some View {
            Section("Photo") {
                if let img = photo {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                PhotoCapture(image: $photo)
            }
        }
    }

    private struct DetailsSection: View {
        @Binding var title: String
        @Binding var category: String
        @Binding var city: String
        private let categories = ["Plastic","Glass","Paper","E-Waste","Bulky","Other"]

        var body: some View {
            Section("Details") {
                TextField("Title", text: $title)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0) }
                }
                TextField("City", text: $city)
            }
        }
    }

    // MARK: - Location (snapshot row + actions)

    private struct LocationSection: View {
        @Binding var coord: CLLocationCoordinate2D?
        var openPicker: () -> Void
        var useCurrent: () -> Void

        var body: some View {
            Section("Location") {
                Text(coordinateLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(action: openPicker) {
                    SnapshotMapView(coordinate: coord)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: useCurrent) {
                    Label("Use Current Location", systemImage: "location")
                }
            }
        }

        private var coordinateLabel: String {
            guard let c = coord else { return "Tap the map preview to pick a location" }
            return String(format: "Lat %.5f, Lon %.5f", c.latitude, c.longitude)
        }
    }
}

// MARK: - Snapshot used inside the form (draws a pin on the image)

private struct SnapshotMapView: View {
    var coordinate: CLLocationCoordinate2D?
    @State private var image: UIImage?

    private var coordKey: String {
        if let c = coordinate { return String(format: "%.6f,%.6f", c.latitude, c.longitude) }
        return "nil"
    }

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.secondary.opacity(0.12)).overlay(ProgressView()) }
        }
        .onAppear { makeSnapshot() }
        .onChange(of: coordKey) { _ in makeSnapshot() }
        .id(coordKey)
        .clipped()
    }

    private func makeSnapshot() {
        let size = CGSize(width: UIScreen.main.bounds.width - 48, height: 280)
        let center = coordinate ?? CLLocationCoordinate2D(latitude: 41.387, longitude: 2.170)
        var region = MKCoordinateRegion(center: center, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
        region.span.latitudeDelta  = max(0.002, min(region.span.latitudeDelta, 0.2))
        region.span.longitudeDelta = max(0.002, min(region.span.longitudeDelta, 0.2))

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size   = size
        options.scale  = UIScreen.main.scale
        options.showsPointsOfInterest = true
        options.pointOfInterestFilter = .includingAll

        MKMapSnapshotter(options: options)
            .start(with: DispatchQueue.global(qos: .userInitiated)) { snapshot, _ in
                guard let snapshot else { return }
                let base = snapshot.image
                let final: UIImage
                if let c = coordinate {
                    let pt = snapshot.point(for: c)
                    final = Self.drawPin(on: base, at: pt)
                } else {
                    final = base
                }
                DispatchQueue.main.async { self.image = final }
            }
    }

    private static func drawPin(on image: UIImage, at point: CGPoint) -> UIImage {
        let pin = UIImage(systemName: "mappin.circle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)

        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        defer { UIGraphicsEndImageContext() }
        image.draw(at: .zero)
        if let pin {
            let origin = CGPoint(x: point.x - pin.size.width/2, y: point.y - pin.size.height)
            pin.draw(in: CGRect(origin: origin, size: pin.size))
        }
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
}

// MARK: - Fullscreen Map Picker (the only live Map)

private struct MapPickerSheet: View {
    @EnvironmentObject var loc: LocationManager
    @Binding var camera: MapCameraPosition
    @Binding var coord: CLLocationCoordinate2D?
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if let c = coord {
                        Annotation("Selected", coordinate: c) {
                            Image(systemName: "mappin.circle.fill").font(.title2)
                        }
                    }
                    UserAnnotation()
                }
                .transaction { $0.disablesAnimations = true }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { coord = c }
                }
                .onAppear {
                    if loc.authorization == .notDetermined { loc.request() }
                    if coord == nil, let c = loc.userLocation?.coordinate {
                        camera = .region(.init(center: c,
                                               span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))
                    }
                }
            }
            .navigationTitle("Pick Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
    }
}
