import SwiftUI

struct CameraScreen: View {
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        CameraOverlay(
            onCaptured: onCaptured,
            onCancel: onCancel
        )
        .onAppear {
            startSession()
        }
        .onDisappear {
            CameraSessionManager.shared.stop()
        }
    }
    
    private func startSession() {
        Task {
            let camera = CameraSessionManager.shared
            let granted = await camera.ensurePermission()
            guard granted else { return }
            camera.configureIfNeeded()
            camera.start()
        }
    }
}
