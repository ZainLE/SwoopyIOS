//
//  CameraExpandOverlay.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//

import SwiftUI
import AVFoundation

struct CameraExpandOverlay: View {
    var camNS: Namespace.ID
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var session = AVCaptureSession()
    @State private var cam = CameraController()
    @State private var isReady = false

    var body: some View {
        ZStack {
            // Expanding shell
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Material.ultraThin) // <- apply fill while it's still a Shape
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.15))
                }
                .matchedGeometryEffect(id: "camBubble", in: camNS)
                .ignoresSafeArea()
                .animation(
                    Animation.spring(response: 0.28, dampingFraction: 0.95, blendDuration: 0),
                    value: isReady
                )

            // Live preview on top (fades in fast)
            if isReady {
                CameraPreview(session: session)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Controls
            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                    }
                    .padding()
                    Spacer()
                }
                Spacer()
                Button {
                    cam.capturePhoto { img in
                        if let img { onCapture(img) } else { onCancel() }
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.8)).frame(width: 74, height: 74)
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 84, height: 84)
                    }
                }
                .padding(.bottom, 30)
            }
            .foregroundStyle(.black)
        }
        .task {
            await cam.configure(session: session)
            isReady = true
            session.startRunning()
        }
        .onDisappear {
            session.stopRunning()
        }
    }
}

// MARK: - Camera plumbing

final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    private var output = AVCapturePhotoOutput()
    private var onShot: ((UIImage?) -> Void)?

    func configure(session: AVCaptureSession) async {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        session.addOutput(output)
        if #available(iOS 16.0, *) {
        } else {
            output.isHighResolutionCaptureEnabled = true
        }
        session.commitConfiguration()
    }

    func capturePhoto(_ handler: @escaping (UIImage?) -> Void) {
        onShot = handler
        let settings = AVCapturePhotoSettings()
        if #available(iOS 16.0, *) {
            // On iOS 16+, rely on default maxPhotoDimensions behavior (highest supported by default)
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let img = UIImage(data: data) else {
            onShot?(nil); onShot = nil
            return
        }
        onShot?(img); onShot = nil
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraView {
        let v = CameraView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: CameraView, context: Context) {}

    final class CameraView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

