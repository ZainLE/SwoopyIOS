import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import MobileCoreServices

// Downsample images on the main menu 
private func downsample(data: Data, maxPixel: Int) -> UIImage? {
    let srcOpts: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: false
    ]
    guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts as CFDictionary) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

private func downsample(image: UIImage, maxPixel: Int) -> UIImage {
    let w = Int(image.size.width * image.scale)
    let h = Int(image.size.height * image.scale)
    let maxDim = max(w, h)
    guard maxDim > maxPixel else { return image }
    let scale = CGFloat(maxPixel) / CGFloat(maxDim)
    let target = CGSize(width: CGFloat(w) * scale / image.scale,
                        height: CGFloat(h) * scale / image.scale)
    let fmt = UIGraphicsImageRendererFormat.default()
    fmt.scale = image.scale
    return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
    }
}

struct PhotoCapture: View {
    @Binding var image: UIImage?

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCameraAlert = false
    @State private var cameraAlertMessage = ""

    // Max UI size we ever render (long edge, pixels).
    private let uiMaxPixel = 2048

    var body: some View {
        HStack(spacing: 12) {
            // Camera
            Button {
                Task { await openCameraSafely() }
            } label: {
                Label("Camera", systemImage: "camera")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .sheet(isPresented: $showCamera) {
                UIKitCamera(image: Binding(
                    get: { image },
                    set: { new in
                        guard let raw = new else { image = nil; return }
                        Task(priority: .userInitiated) {
                            let small = downsample(image: raw, maxPixel: uiMaxPixel)
                            await MainActor.run { image = small }
                        }
                    })
                )
            }
            .alert("Camera Unavailable", isPresented: $showCameraAlert) {
                Button("OK", role: .cancel) {}
            } message: { Text(cameraAlertMessage) }

            // Library
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Library", systemImage: "photo.on.rectangle")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .onChange(of: pickerItem) { _, newValue in
                guard let newValue else { return }
                Task(priority: .userInitiated) {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let img = downsample(data: data, maxPixel: uiMaxPixel) {
                        await MainActor.run { image = img }
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
        case .authorized: showCamera = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            granted ? (showCamera = true) : showDenied()
        default: showDenied()
        }
    }
    private func showDenied() {
        cameraAlertMessage = "Please allow camera access in Settings."
        showCameraAlert = true
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
