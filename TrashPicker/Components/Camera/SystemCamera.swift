import SwiftUI

struct SystemCamera: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.delegate = context.coordinator
        vc.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        vc.allowsEditing = false
        return vc
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onCapture: onCapture) }

    final class Coord: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Safely extract image (no force unwrap)
            guard let img = info[.originalImage] as? UIImage else {
                #if DEBUG
                print("[SystemCamera] ⚠️ No image in picker result")
                #endif
                picker.dismiss(animated: true) {
                    Task { @MainActor in
                        self.onCapture(nil)
                    }
                }
                return
            }
            
            // Validate image can be converted to JPEG
            guard let jpegData = img.jpegData(compressionQuality: 0.8),
                  jpegData.count > 0 else {
                #if DEBUG
                print("[SystemCamera] ⚠️ Image produced zero-byte JPEG")
                #endif
                picker.dismiss(animated: true) {
                    Task { @MainActor in
                        self.onCapture(nil)
                    }
                }
                return
            }
            
            #if DEBUG
            let sizeKB = Double(jpegData.count) / 1024.0
            print("[SystemCamera] ✅ Captured image: \(String(format: "%.1f", sizeKB)) KB")
            #endif
            
            // Dismiss and deliver on main thread
            picker.dismiss(animated: true) {
                Task { @MainActor in
                    self.onCapture(img)
                }
            }
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) {
                // Hop to main thread before calling SwiftUI callback
                Task { @MainActor in
                    self.onCapture(nil)
                }
            }
        }
    }
}
