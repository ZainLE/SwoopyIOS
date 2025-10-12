//
//  UploadDraftStore.swift
//  TrashPicker
//
//  Single source of truth for upload draft state
//

import SwiftUI
import UIKit

@MainActor
final class UploadDraftStore: ObservableObject {
    @Published var photos: [UIImage] = []
    @Published private(set) var lastCaptureTick = 0
    
    private let maxPhotos = 3
    
    /// Insert photo preserving capture order, trim to max, bump tick
    func insertPrimary(_ image: UIImage) {
        // Process image: fix orientation and downsample
        let processedImage = processImage(image)
        
        // Append so earlier captures stay at lower indices
        photos.append(processedImage)
        
        // Trim to max photos
        if photos.count > maxPhotos {
            photos = Array(photos.prefix(maxPhotos))
        }
        
        // Bump tick for observers
        lastCaptureTick += 1
    }
    
    /// Replace photo at specific index
    func replacePhoto(at index: Int, with image: UIImage) {
        guard photos.indices.contains(index) else { return }
        let processedImage = processImage(image)
        photos[index] = processedImage
        lastCaptureTick += 1
    }
    
    /// Remove photo at index
    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
        lastCaptureTick += 1
    }
    
    /// Clear all photos (on successful post or discard)
    func clearDraft() {
        photos.removeAll()
        lastCaptureTick += 1
    }
    
    /// Check if we have space for more photos
    var canAddPhoto: Bool {
        photos.count < maxPhotos
    }
    
    /// Get photo at index safely
    func photo(at index: Int) -> UIImage? {
        photos.indices.contains(index) ? photos[index] : nil
    }
    
    // MARK: - Private Helpers
    
    private func processImage(_ image: UIImage) -> UIImage {
        // Fix orientation
        let orientationFixed = image.fixedOrientation()
        
        // Downsample to max 2048px
        let maxDimension: CGFloat = 2048
        let size = orientationFixed.size
        
        if max(size.width, size.height) <= maxDimension {
            return orientationFixed
        }
        
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
        
        return orientationFixed.resized(to: newSize) ?? orientationFixed
    }
}

// MARK: - UIImage Extensions

private extension UIImage {
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
    
    func resized(to newSize: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        
        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
