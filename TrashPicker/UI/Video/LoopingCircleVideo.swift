import SwiftUI
import AVFoundation

struct LoopingCircleVideo: View {
    private let resourceName: String
    
    init(name: String) {
        self.resourceName = name
    }
    
    var body: some View {
        LoopingCircleVideoRepresentable(resourceName: resourceName)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(AppColor.brandGreen, lineWidth: 6)
            )
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
}

private struct LoopingCircleVideoRepresentable: UIViewRepresentable {
    let resourceName: String
    
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.startPlaybackIfNeeded()
        return view
    }
    
    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player == nil {
            uiView.playerLayer.player = context.coordinator.player
            context.coordinator.startPlaybackIfNeeded()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(resourceName: resourceName)
    }
    
    final class PlayerView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }
        
        var playerLayer: AVPlayerLayer {
            guard let layer = self.layer as? AVPlayerLayer else {
                fatalError("Expected AVPlayerLayer backing layer")
            }
            return layer
        }
    }
    
    final class Coordinator {
        let player: AVQueuePlayer
        private var looper: AVPlayerLooper?
        private var hasStarted = false
        
        init(resourceName: String) {
            self.player = AVQueuePlayer()
            player.isMuted = true
            player.actionAtItemEnd = .none
            
            if let item = Coordinator.makeItem(resourceName: resourceName) {
                looper = AVPlayerLooper(player: player, templateItem: item)
            }
        }
        
        private static func makeItem(resourceName: String) -> AVPlayerItem? {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
                #if DEBUG
                DLog("[LoopingCircleVideo] Missing video resource: \(resourceName).mp4")
                #endif
                return nil
            }
            return AVPlayerItem(url: url)
        }
        
        func startPlaybackIfNeeded() {
            guard hasStarted == false else { return }
            hasStarted = true
            player.play()
        }
    }
}
