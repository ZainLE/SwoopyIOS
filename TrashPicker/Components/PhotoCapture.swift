import SwiftUI
import PhotosUI
import AVFoundation

struct PhotoCapture: View {
    @Binding var image: UIImage?

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCameraAlert = false
    @State private var cameraAlertMessage = ""

    var body: some View {
        HStack(spacing: 12) {

            // Camera
            Button {
                Task { await openCameraSafely() }
            } label: {
                Label("Camera", systemImage: "camera")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)          // keep icon/text visible
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)         // filled button
            .tint(.blue)                             // choose your accent
            .sheet(isPresented: $showCamera) {
                UIKitCamera(image: $image)
            }
            .alert("Camera Unavailable", isPresented: $showCameraAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cameraAlertMessage)
            }

            // Library
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Library", systemImage: "photo.on.rectangle")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)                  // outlined button
            .tint(.blue)                             // outline + title/icon color
            .onChange(of: pickerItem) { _, newValue in   // iOS 17+ preferred overload
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        image = img
                    }
                }
            }
        }
    }

    // MARK: - Permissions / Camera

    private func openCameraSafely() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraAlertMessage = "Camera not available on this device."
            showCameraAlert = true
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                showCamera = true
            } else {
                cameraAlertMessage = "Please allow camera access in Settings."
                showCameraAlert = true
            }
        default:
            cameraAlertMessage = "Please allow camera access in Settings."
            showCameraAlert = true
        }
    }
}

// MARK: - UIKit Camera Bridge

struct UIKitCamera: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: UIKitCamera
        init(_ p: UIKitCamera) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            parent.image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
