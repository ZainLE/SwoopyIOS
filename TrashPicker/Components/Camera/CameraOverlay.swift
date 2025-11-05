import SwiftUI
import AVFoundation
import UIKit
import PhotosUI

struct CameraOverlay: View {
    @ObservedObject private var camera = CameraSessionManager.shared
    @Environment(\.dismiss) private var dismiss
    
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void
    
    @State private var isCapturing = false
    @State private var showPhotoPicker = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isProcessingPickerItem = false
    
    var body: some View {
        ZStack {
            // Camera preview
            if camera.isReady {
                CameraPreviewView(layer: camera.makePreviewLayer())
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                
                if camera.error == .permissionDenied {
                    permissionDeniedView
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
            }
            
            // Controls overlay
            if camera.isReady {
                VStack {
                    // Top bar
                    HStack {
                        Spacer()
                        
                        Button(action: handleCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.3))
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 24)
                        .padding(.top, 50)
                        }
                    Spacer()
                    
                    // Bottom bar
                    ZStack {
                        captureButton
                        
                        HStack {
                            uploadButton
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
                }
            }
        }
        .task {
            await startCamera()
        }
        .onDisappear {
            // Keep session running for faster reopen
            // To stop: Task { await camera.stop() }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickerItem,
            matching: .images
        )
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            isProcessingPickerItem = true
            Task {
                await processPickerItem(newValue)
            }
        }
        .onChange(of: showPhotoPicker) { _, isPresented in
            if !isPresented, !isProcessingPickerItem {
                camera.resumePreview()
            }
        }
    }
    
    
    private var captureButton: some View {
        Button(action: handleCapture) {
            ZStack {
                Circle()
                 .fill(Color.white)
                  .frame(width: 70, height: 70)
                                
                   Circle()
                    .stroke(Color.white, lineWidth: 3)
                     .frame(width: 80, height: 80)
                            }
                        }
             .disabled(isCapturing)
             .opacity(isCapturing ? 0.5 : 1.0)
    }
    private var uploadButton: some View {
        Button(action: handleUploadFromGallery) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(AppTheme.ColorToken.primary)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.98))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .disabled(isCapturing)
        .accessibilityLabel("Upload photo from gallery")
    }
    
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.6))
            Text("Camera Access Required")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
            Text("Please enable camera access in Settings to take photos.")
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button(action: openSettings) {
                Text("Open Settings")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    .background(Color(red: 0/255, green: 81/255, blue: 63/255))
                    .clipShape(Capsule())
            }
            .padding(.top, 10)
            
            Button(action: handleCancel) {
                Text("Cancel")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.top, 5)
        }
    }
    
    private func startCamera() async {
        let granted = await camera.ensurePermission()
        guard granted else { return }
        // Configure before starting (proper ordering)
        camera.configureIfNeeded()
        camera.start()
    }
    
    private func handleCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        
        // Haptic feedback on shutter tap
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        
        camera.capture { image in
            isCapturing = false
            
            if let img = image {
                onCaptured(img)
            }
        }
    }
    
    private func handleUploadFromGallery() {
        guard !isCapturing else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        camera.pausePreview()
        showPhotoPicker = true
    }
    
    private func handleCancel() {
        onCancel()
    }
    
    private func openSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsUrl)
    }
    
    private func processPickerItem(_ item: PhotosPickerItem) async {
        defer {
            Task { @MainActor in
                pickerItem = nil
                isProcessingPickerItem = false
                if !showPhotoPicker {
                    camera.resumePreview()
                }
            }
        }
        
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                return
            }
            
            await MainActor.run {
                onCaptured(image)
            }
        } catch {
            // Ignore errors; resume handled in defer
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(layer)
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // No dynamic updates needed; layer is managed by CameraSessionManager
    }
    
    class PreviewView: UIView {
        private let previewLayer: AVCaptureVideoPreviewLayer
        
        init(_ providedLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = providedLayer
            super.init(frame: .zero)
            self.previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(self.previewLayer)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            // Guard against zero bounds to prevent CAMetalLayer warnings
            guard bounds.width > 0, bounds.height > 0 else { return }
            // Disable implicit animations when updating frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

// TODO: Preview not added — relies on live camera capture pipeline unavailable in SwiftUI previews
