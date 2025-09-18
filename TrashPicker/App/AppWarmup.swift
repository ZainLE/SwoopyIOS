//
//  AppWarmup.swift
//  TrashPicker
//
//  Created by Zain Latif  on 14/9/25.
//


import Foundation
import UIKit
import MapKit
import ImageIO

/// Non-blocking, Swift 6-safe warmup helpers used at app launch.
enum AppWarmup {

    /// Runs a few tasks to reduce the first-interaction hitch.
    @MainActor
    static func preheat(with svc: SupabaseService) async {
        // 1) Warm common SF Symbols & a haptic generator (must run on main actor)
        prewarmSymbols([
            "camera", "photo.on.rectangle", "mappin.circle.fill",
            "xmark", "heart.fill", "location", "clock.badge.checkmark"
        ])
        let h = UIImpactFeedbackGenerator(style: .medium)
        h.prepare()

        // 2) Warm MapKit’s rendering caches (fire-and-forget, background)
        prewarmMap()

        // 3) Pre-decode a few images so the first card is instant (background)
        //    We assume svc.feed was loaded already in App.task.
        //    TrashDTO exposes `photoURLs: [URL]` — warm the first one per item.
        let urls = Array(svc.feed.compactMap { $0.photoURLs.first }.prefix(12))
        predecodeImages(urls: urls, maxDimension: 600)
    }

    // MARK: - Internals

    /// Ask the system to rasterize a few SF Symbols up-front (main actor).
    @MainActor
    private static func prewarmSymbols(_ names: [String]) {
        for n in names {
            _ = UIImage(systemName: n)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: UIImage.SymbolWeight.regular))
        }
    }

    /// Pre-renders a tiny snapshot to warm up MapKit caches (fire-and-forget).
    private static func prewarmMap() {
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

    /// Downsamples & decodes a handful of local image URLs off the main thread to warm caches.
    private static func predecodeImages(urls: [URL], maxDimension: CGFloat) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                autoreleasepool {
                    _ = downsampledImage(at: url, maxPixel: Int(maxDimension))
                }
            }
        }
    }

    private static func downsampledImage(at url: URL, maxPixel: Int) -> UIImage? {
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
}
