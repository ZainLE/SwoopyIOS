import SwiftUI
import MapKit
import CoreLocation

struct AddTrashView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var showValidation = false
    @State private var validationText = ""
    @State private var showSuccess = false

    @State private var photo: UIImage?
    @State private var title = ""
    @State private var descriptionText = ""    // <= limited to 100 chars below
    @State private var condition = "good"      // "bad" | "good" | "excellent"
    @State private var category = "Other"
    @State private var city = ""
    @State private var coord: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(
        .init(center: .init(latitude: 41.387, longitude: 2.170),
              span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
    )
    @State private var saving = false

    @FocusState private var focusedField: Field?
    private enum Field { case title, city, description }

    var body: some View {
        NavigationStack {
            Form {
                PhotoSection(photo: $photo)

                Section("Details") {
                    TextField("Title", text: $title)
                        .focused($focusedField, equals: .title)

                    TextField("City", text: $city)
                        .focused($focusedField, equals: .city)

                    Picker("Category", selection: $category) {
                        ForEach(["Plastic","Glass","Paper","E-Waste","Bulky","Other"], id: \.self) { Text($0) }
                    }
                }

                Section("Condition") {
                    Picker("Condition", selection: $condition) {
                        Label("Bad", systemImage: "hand.thumbsdown.fill").tag("bad")
                        Label("Good", systemImage: "hand.thumbsup.fill").tag("good")
                        Label("Excellent", systemImage: "star.circle.fill").tag("excellent")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Description") {
                    ZStack(alignment: .topLeading) {
                        if descriptionText.isEmpty {
                            Text("Up to 100 characters…")
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: $descriptionText)
                            .frame(minHeight: 80, maxHeight: 120)
                            .focused($focusedField, equals: .description)
                            .onChange(of: descriptionText) { _, new in
                                if new.count > 100 { descriptionText = String(new.prefix(100)) }
                            }
                    }
                }

                LocationSection(camera: $camera, coord: $coord)
                    .environmentObject(loc)

                // Submit inline, at the bottom of the form
                Section {
                    Button(action: validateAndSave) {
                        Label("Upload", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity) // center the label
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(saving)
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Done") { focusedField = nil }
                }
            }
            .alert("Can't Upload", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationText)
            }
        }
    }

    private func validateAndSave() {
        if photo == nil { validationText = "Please add a photo."; showValidation = true; return }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { validationText = "Please enter a title."; showValidation = true; return }
        if city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { validationText = "Please enter the city/neighborhood."; showValidation = true; return }
        if coord == nil { validationText = "Please select a location on the map or use current location."; showValidation = true; return }
        Task { await save() }
    }

    private func save() async {
        guard let img = photo, let c = coord else { return }
        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDesc: String? = desc.isEmpty ? nil : String(desc.prefix(100))
        saving = true
        defer { saving = false }
        do {
            try await svc.createItem(
                images: [img],
                title: title,
                description: finalDesc,
                category: category,
                condition: condition,
                mode: "street",
                coordinate: c
            )
            // reset form
            photo = nil; title = ""; city = ""; coord = nil
            descriptionText = ""; condition = "good"; category = "Other"
            await svc.fetchFeed(near: c)
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

    private struct LocationSection: View {
        @EnvironmentObject var loc: LocationManager
        @Binding var camera: MapCameraPosition
        @Binding var coord: CLLocationCoordinate2D?

        var body: some View {
            Section("Location") {
                Text(coordLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                MapPicker(camera: $camera, selected: $coord)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    .onAppear {
                        if loc.authorization == CLAuthorizationStatus.notDetermined { loc.request() }
                        if let c = loc.userLocation?.coordinate {
                            camera = .region(.init(center: c, span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))
                        }
                    }

                Button {
                    loc.requestOnce { c in
                        guard let c else { return }
                        coord = c
                        withAnimation(.easeInOut(duration: 0.35)) {
                            camera = .region(.init(center: c, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
                        }
                    }
                } label: {
                    Label("Use Current Location", systemImage: "location")
                }
            }
        }

        private var coordLabel: String {
            guard let c = coord else { return "Tap the map to drop a pin" }
            return String(format: "Lat %.5f, Lon %.5f", c.latitude, c.longitude)
        }
    }

    private struct MapPicker: View {
        @Binding var camera: MapCameraPosition
        @Binding var selected: CLLocationCoordinate2D?

        var body: some View {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if let c = selected {
                        Annotation("Selected", coordinate: c) {
                            Image(systemName: "mappin.circle.fill").font(.title2)
                        }
                    }
                    UserAnnotation()
                }
                .transaction { $0.disablesAnimations = true }
                .onTapGesture { pt in
                    if let c = proxy.convert(pt, from: .local) { selected = c }
                }
            }
        }
    }
}
