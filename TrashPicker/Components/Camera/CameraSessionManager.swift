//
//  CameraSessionManager.swift
//  TrashPicker
//
//  AVCam-based camera session manager
//  Single source of truth for all camera operations
//

import AVFoundation
import UIKit
import Combine

/// Errors that can occur during camera operations
enum CameraError: Error, LocalizedError {
    case permissionDenied
    case noCameraAvailable
    case configurationFailed
    case captureFailed
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied"
        case .noCameraAvailable: return "No camera available"
        case .configurationFailed: return "Camera configuration failed"
        case .captureFailed: return "Photo capture failed"
        }
    }
}

/// Camera session manager following AVCam architecture.
/// UI-facing state is published on the main actor, while heavy capture work stays on a private queue.
final class CameraSessionManager: NSObject, ObservableObject {
    
    // MARK: - Published State (main actor only)
    
    @Published var isReady: Bool = false
    @Published var lastPhoto: UIImage?
    @Published var error: CameraError?
    
    // MARK: - Private Properties
    
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.trashpicker.camera.session")
    
    private var deviceInput: AVCaptureDeviceInput?
    private var photoCompletion: ((UIImage?) -> Void)?
    
    // Cached preview layer to avoid recreating on each render
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    
    #if DEBUG
    private var configStartTime: CFAbsoluteTime = 0
    private var captureStartTime: CFAbsoluteTime = 0
    #endif
    
    // MARK: - Singleton
    
    static let shared = CameraSessionManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// Ensure camera permission before presenting camera UI
    func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
            
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            
        case .denied, .restricted:
            await MainActor.run {
                self.error = .permissionDenied
            }
            return false
            
        @unknown default:
            return false
        }
    }
    
    /// Configure session if needed (called once per lifecycle or when reopening camera)
    func configureIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Skip if already configured
            guard self.deviceInput == nil else {
                #if DEBUG
                print("[CAM] Already configured, skipping")
                #endif
                return
            }
            
            #if DEBUG
            self.configStartTime = CFAbsoluteTimeGetCurrent()
            #endif
            
            self.configureSession()
            
            #if DEBUG
            let elapsed = (CFAbsoluteTimeGetCurrent() - self.configStartTime) * 1000
            print("[CAM] configureMs=\(String(format: "%.1f", elapsed))")
            #endif
        }
    }
    
    /// Start the capture session
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            #if DEBUG
            let startTime = CFAbsoluteTimeGetCurrent()
            #endif
            
            if !self.session.isRunning {
                self.session.startRunning()
            }
            
            Task { @MainActor in
                self.isReady = true
                
                #if DEBUG
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                print("[CAM] firstFrameMs=\(String(format: "%.1f", elapsed))")
                #endif
            }
        }
    }
    
    /// Stop the capture session
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.session.isRunning {
                self.session.stopRunning()
            }
            
            Task { @MainActor in
                self.isReady = false
            }
        }
    }
    
    /// Capture a photo
    func capture(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            #if DEBUG
            Task { @MainActor in
                self.captureStartTime = CFAbsoluteTimeGetCurrent()
            }
            #endif
            
            // Store completion handler
            self.photoCompletion = completion
            
            // Create fresh settings for each capture
            let settings = AVCapturePhotoSettings()
            
            // Enable high resolution only if supported
            if #available(iOS 16.0, *) {
                // No need to set isHighResolutionPhotoEnabled; maxPhotoDimensions on the output controls resolution
            } else {
                if self.photoOutput.isHighResolutionCaptureEnabled {
                    settings.isHighResolutionPhotoEnabled = true
                }
            }
            
            // Capture photo
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    
    /// Get the cached preview layer for display
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        return previewLayer
    }
    
    /// Pause the live camera preview without tearing down configuration
    func pausePreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
    
    /// Resume the camera preview after a temporary pause
    func resumePreview() {
        start()
    }
    
    // MARK: - Private Configuration
    
    private func configureSession() {
        session.beginConfiguration()
        
        // Set preset once
        session.sessionPreset = .photo
        
        // Select back camera
        guard let device = selectBackCamera() else {
            session.commitConfiguration()
            Task { @MainActor in
                self.error = .noCameraAvailable
            }
            return
        }
        
        // Create input
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.error = .configurationFailed
            }
            return
        }
        
        // Add input
        if session.canAddInput(input) {
            session.addInput(input)
            deviceInput = input
        } else {
            session.commitConfiguration()
            Task { @MainActor in
                self.error = .configurationFailed
            }
            return
        }
        
        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            
            // Configure optional features only if supported
            if #available(iOS 16.0, *) {
                // Prefer maxPhotoDimensions on iOS 16+
                let dims = device.activeFormat.highResolutionStillImageDimensions
                if dims.width > 0 && dims.height > 0 {
                    photoOutput.maxPhotoDimensions = dims
                }
            } else {
                // Fallback for iOS < 16
                photoOutput.isHighResolutionCaptureEnabled = true
            }
            
            if photoOutput.isDepthDataDeliverySupported {
                photoOutput.isDepthDataDeliveryEnabled = true
            }
            
            if photoOutput.isPortraitEffectsMatteDeliverySupported {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
            }
            
            // Disable live photo by default
            if photoOutput.isLivePhotoCaptureSupported {
                photoOutput.isLivePhotoCaptureEnabled = false
            }
        } else {
            session.commitConfiguration()
            Task { @MainActor in
                self.error = .configurationFailed
            }
            return
        }
        
        session.commitConfiguration()
    }
    
    /// Select back camera with preference order
    private func selectBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .back
        )
        
        return discovery.devices.first
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraSessionManager: AVCapturePhotoCaptureDelegate {
    
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        #if DEBUG
        Task { @MainActor in
            let elapsed = (CFAbsoluteTimeGetCurrent() - self.captureStartTime) * 1000
            print("[CAM] captureMs=\(String(format: "%.1f", elapsed))")
        }
        #endif
        
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            
            Task { @MainActor in
                self.error = .captureFailed
                self.photoCompletion?(nil)
                self.photoCompletion = nil
            }
            return
        }
        
        // Process image: fix orientation and downsample
        let processed = processImage(image)
        
        Task { @MainActor in
            self.lastPhoto = processed
            self.photoCompletion?(processed)
            self.photoCompletion = nil
        }
    }
    
    /// Process captured image: fix orientation and downsample to max 2048px
    nonisolated private func processImage(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 2048
        let size = image.size
        
        // Calculate scale factor
        let scale: CGFloat
        if size.width > size.height {
            scale = min(1.0, maxDimension / size.width)
        } else {
            scale = min(1.0, maxDimension / size.height)
        }
        
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        // Redraw with proper orientation
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let processed = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        
        return processed
    }
}
