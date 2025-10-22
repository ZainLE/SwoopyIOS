//
//  PhotoCapture.swift
//  TrashPicker
//
//  DEPRECATED: System camera (UIImagePickerController) replaced by CameraOverlay.
//  This file is kept for rollback purposes only. No active call sites should remain.
//  Wrapped in #if LEGACY_CAMERA to exclude from build.
//

#if LEGACY_CAMERA

import SwiftUI
import PhotosUI
import AVFoundation

struct PhotoCapture: View {
    @Binding var image: UIImage?

    // Camera now presented via CameraService overlay (no sheet toggle needed)
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
        await MainActor.run {
            guard let presenter = UIApplication.shared.topViewController else {
                cameraAlertMessage = "Couldn't present camera."
                showCameraAlert = true
                return
            }
            CameraService.shared.ensureCameraPermission(from: presenter) { ok in
                guard ok else {
                    cameraAlertMessage = "Please allow camera access in Settings."
                    showCameraAlert = true
                    return
                }
                CameraService.shared.presentCamera(from: presenter, onImage: { img in
                    image = img
                }, onCancel: {
                    // no-op
                })
            }
        }
    }
}

#endif // LEGACY_CAMERA
