import SwiftUI
import UIKit

struct CameraCaptureView: UIViewControllerRepresentable {
    var onPhoto: (UIImage?) -> Void

    func makeCoordinator() -> Coord { Coord(onPhoto: onPhoto) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.delegate = context.coordinator
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.allowsEditing = false
        c.modalPresentationStyle = .fullScreen
        c.cameraOverlayView = nil
        c.showsCameraControls = true
        
        // Force full screen presentation
        c.edgesForExtendedLayout = []
        c.extendedLayoutIncludesOpaqueBars = false
        
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coord: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPhoto: (UIImage?) -> Void
        init(onPhoto: @escaping (UIImage?) -> Void) { self.onPhoto = onPhoto }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) {
                // Hop to main thread before calling SwiftUI callback
                Task { @MainActor in
                    self.onPhoto(nil)
                }
            }
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            // Safely extract image (no force unwrap)
            guard let img = info[.originalImage] as? UIImage else {
                #if DEBUG
                print("[Camera] ⚠️ No image in picker result")
                #endif
                picker.dismiss(animated: true) {
                    Task { @MainActor in
                        self.onPhoto(nil)
                    }
                }
                return
            }
            
            // Validate image can be converted to JPEG
            guard let jpegData = img.jpegData(compressionQuality: 0.8),
                  jpegData.count > 0 else {
                #if DEBUG
                print("[Camera] ⚠️ Image produced zero-byte JPEG")
                #endif
                picker.dismiss(animated: true) {
                    Task { @MainActor in
                        self.onPhoto(nil)
                    }
                }
                return
            }
            
            #if DEBUG
            let sizeKB = Double(jpegData.count) / 1024.0
            print("[Camera] ✅ Captured image: \(String(format: "%.1f", sizeKB)) KB")
            #endif
            
            // Dismiss and deliver on main thread
            picker.dismiss(animated: true) {
                Task { @MainActor in
                    self.onPhoto(img)
                }
            }
        }
    }
}
