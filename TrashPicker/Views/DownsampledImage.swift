import SwiftUI
import ImageIO

struct DownsampledImage: View {
    let url: URL
    let maxDimension: CGFloat         
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable()
            } else {
                Color.clear.onAppear(perform: load)
            }
        }
    }

    private func load() {
        let maxPixels = maxDimension * UIScreen.main.scale
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let ui = UIImage(cgImage: cg)
            DispatchQueue.main.async { self.image = ui }
        }
    }
}
