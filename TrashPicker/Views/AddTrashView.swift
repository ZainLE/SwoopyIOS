import SwiftUI
import MapKit

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
    @State private var coord: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(
        .init(center: .init(latitude: 41.387, longitude: 2.170),
              span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
    )
    @State private var saving = false
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            Form {
                PhotoSection(photo: $photo)
                
                DetailsSection(title: $title, category: $category, city: $city)
                
                LocationSection(camera: $camera, coord: $coord)
                    .environmentObject(loc)
                    .scrollDismissesKeyboard(.immediately)
                
                // Submit section lives in THIS view so it can access state
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
            .overlay(alignment: .top) {
                if showSuccess {
                    Label("Uploaded successfully", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear { withAnimation(.easeOut(duration: 0.2)) {} }
                }
            }
            .animation(.spring(), value: showSuccess)
            
            .navigationTitle("Add Spot")
            .alert("Can't Upload", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationText)
            }
        }
    }
    
    // MARK: - Actions
    
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
            
            // success → reset + refresh + show toast, then dismiss after a short delay
            photo = nil; title = ""; city = ""; coord = nil
            await ck.fetchFeed()
            showSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showSuccess = false   // optional
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
                PhotoCapture(image: $photo) // shows Camera + Library buttons
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
    
 
    
//    I replaced the bottom part
    
    // MARK: - Location section
    
    private struct LocationSection: View {
        @EnvironmentObject var loc: LocationManager
        @Binding var camera: MapCameraPosition
        @Binding var coord: CLLocationCoordinate2D?
        
        var body: some View {
            Section("Location") {
                Text(coordinateLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                
                MapPicker(camera: $camera, selectedCoordinate: $coord)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    .onAppear {
                        if loc.authorization == .notDetermined { loc.request() }
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
        
        private var coordinateLabel: String {
            guard let c = coord else { return "Tap the map to drop a pin" }
            return String(format: "Lat %.5f, Lon %.5f", c.latitude, c.longitude)
        }
    }
    
    // MARK: - Map picker
    
    private struct MapPicker: View {
        @Binding var camera: MapCameraPosition
        @Binding var selectedCoordinate: CLLocationCoordinate2D?
        
        var body: some View {
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all) {
                    if let c = selectedCoordinate {
                        Annotation("Selected", coordinate: c) {
                            Image(systemName: "mappin.circle.fill").font(.title2)
                        }
                    }
                    UserAnnotation()
                }
                .gesture(
                    TapGesture().onEnded { _ in
                        // swiftui tap gives us a point via gesture state:
                        // use map reader’s convert from the center of the tap
                    }
                )
                .onTapGesture { point in
                    if let coord = proxy.convert(point, from: .local) {
                        selectedCoordinate = coord
                    }
                }
            }
        }
    }
}



