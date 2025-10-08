//
//  CameraService.swift
//  TrashPicker
//
//  Camera service with strong coordinator retention and permission handling
//

import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published var permissionStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var showPermissionDeniedAlert = false
    
    // Strong references to prevent deallocation during presentation
    private var picker: UIImagePickerController?
    private var coordinator: CameraCoordinator?
    
    private let draftStore: UploadDraftStore
    
    init(draftStore: UploadDraftStore) {
        self.draftStore = draftStore
        super.init()
    }
    
    /// Ensure camera permission before presenting camera
    func ensureCameraPermission(completion: @escaping (Bool) -> Void) {
        switch permissionStatus {
        case .authorized:
            completion(true)
            
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    completion(granted)
                }
            }
            
        case .denied, .restricted:
            showPermissionDeniedAlert = true
            completion(false)
            
        @unknown default:
            completion(false)
        }
    }
    
    /// Present camera with proper coordinator retention
    func presentCamera(from viewController: UIViewController) {
        let picker = UIImagePickerController()
        let coordinator = CameraCoordinator(draftStore: draftStore) { [weak self] in
            self?.dismissCamera()
        }
        
        var source: UIImagePickerController.SourceType
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            source = .camera
        } else if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            source = .photoLibrary
        } else if UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum) {
            source = .savedPhotosAlbum
        } else {
            #if DEBUG
            print("[CAMERA] no available capture sources, aborting presentation")
            #endif
            return
        }

        picker.sourceType = source
        picker.delegate = coordinator
        picker.allowsEditing = false

        var cameraDeviceDescription = "none"
        if source == .camera {
            if UIImagePickerController.isCameraDeviceAvailable(.rear) {
                picker.cameraDevice = .rear
                cameraDeviceDescription = "rear"
            } else if UIImagePickerController.isCameraDeviceAvailable(.front) {
                picker.cameraDevice = .front
                cameraDeviceDescription = "front"
            } else {
                cameraDeviceDescription = "unavailable"
                if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
                    source = .photoLibrary
                    picker.sourceType = .photoLibrary
                    cameraDeviceDescription = "none"
                } else if UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum) {
                    source = .savedPhotosAlbum
                    picker.sourceType = .savedPhotosAlbum
                    cameraDeviceDescription = "none"
                }
            }
        }

        #if DEBUG
        let sourceDescription: String
        switch source {
        case .camera: sourceDescription = "camera"
        case .photoLibrary: sourceDescription = "photoLibrary"
        case .savedPhotosAlbum: sourceDescription = "savedPhotosAlbum"
        @unknown default: sourceDescription = "unknown"
        }
        print("[CAMERA] presenting source=\(sourceDescription) device=\(cameraDeviceDescription)")
        #endif
        
        // Store strong references
        self.picker = picker
        self.coordinator = coordinator
        
        viewController.present(picker, animated: true)
    }
    
    /// Dismiss camera and clear references
    private func dismissCamera() {
        picker?.dismiss(animated: true) { [weak self] in
            // Clear strong references after dismissal
            self?.picker = nil
            self?.coordinator = nil
        }
    }
    
    /// Open settings for camera permission
    func openSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsUrl)
    }
}

// MARK: - Camera Coordinator

private class CameraCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let draftStore: UploadDraftStore
    private let onDismiss: () -> Void
    
    init(draftStore: UploadDraftStore, onDismiss: @escaping () -> Void) {
        self.draftStore = draftStore
        self.onDismiss = onDismiss
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        
        // Extract image
        guard let image = info[.originalImage] as? UIImage else {
            onDismiss()
            return
        }
        
        // Process and deliver to draft store on main actor
        Task { @MainActor in
            // Insert into draft store BEFORE dismissing
            draftStore.insertPrimary(image)
            
            // Then dismiss
            onDismiss()
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onDismiss()
    }
}
