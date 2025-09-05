//
//  TrashPickerApp.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import UIKit
import ImageIO   // for CGImageSource (downsample)

// MARK: - App

@main
struct TrashPickerApp: App {
    // Singletons for the whole app
    @StateObject private var ck  = CKTrashService()
    @StateObject private var loc = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView() // your TabView / root nav
                .environmentObject(ck)
                .environmentObject(loc)
                .task { await warmStart() } // ✅ run in background; do not block UI
        }
    }

    // MARK: - Cold-start pre-warm to kill "first interaction" jank
    private func warmStart() async {
        // 1) Pre-warm MapKit tile/render pipeline
        prewarmMap()

        // 2) Pre-warm common SF Symbols used across the app (first render can stutter)
        prewarmSymbols([
            "camera", "photo.on.rectangle", "mappin.circle.fill",
            "xmark", "heart.fill", "location", "clock.badge.checkmark"
        ])

        // 3) Pre-warm a haptic generator (first hit can stutter if created on-demand)
        let h = UIImpactFeedbackGenerator(style: .medium)
        h.prepare()

        // 4) Fetch feed (background) and pre-decode the first few images so the first card is instant
        await ck.fetchFeed()
        let urls = Array(ck.feed.compactMap { $0.photoURL }.prefix(12))
        predecodeImages(urls: urls, maxDimension: 600)
    }

    /// Pre-renders a tiny snapshot to warm up MapKit caches (fire-and-forget)
    private func prewarmMap() {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.387, longitude: 2.170),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        options.size  = CGSize(width: 100, height: 100)
        options.scale = UIScreen.main.scale

        MKMapSnapshotter(options: options)
            .start(with: DispatchQueue.global(qos: .utility)) { _, _ in /* warm only */ }
    }

    /// Ask the system to rasterize a few SF Symbols up-front.
    private func prewarmSymbols(_ names: [String]) {
        for n in names {
            _ = UIImage(systemName: n)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        }
    }
}

// MARK: - Lightweight image pre-decoder (no 3rd-party dependency)

/// Downsamples & decodes a handful of local image URLs off the main thread to warm caches.
/// We don't store them anywhere; simply creating the `UIImage` is enough to avoid the first-use hitch.
private func predecodeImages(urls: [URL], maxDimension: CGFloat) {
    guard !urls.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
        for url in urls {
            autoreleasepool {
                _ = downsampledImage(at: url, maxPixel: Int(maxDimension))
            }
        }
    }
}

private func downsampledImage(at url: URL, maxPixel: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [NSString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgThumb)
}
