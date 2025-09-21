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
        c.modalPresentationStyle = .overFullScreen
        c.cameraOverlayView = nil
        c.showsCameraControls = true
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coord: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPhoto: (UIImage?) -> Void
        init(onPhoto: @escaping (UIImage?) -> Void) { self.onPhoto = onPhoto }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.onPhoto(nil) }
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage] as? UIImage)
            picker.dismiss(animated: true) { self.onPhoto(img) }
        }
    }
}
