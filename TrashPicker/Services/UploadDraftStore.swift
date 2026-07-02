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

    // Upload payloads are pre-encoded on a background thread as soon as a
    // photo lands in the draft, so they are ready by the time the user has
    // filled in the form and submit is pure network I/O.
    private var uploadEncodeTasks: [Task<Data?, Never>] = []
    private var duplicateCheckTask: Task<String?, Never>?

    /// Insert photo preserving capture order, trim to max, bump tick
    func insertPrimary(_ image: UIImage) {
        // Process image: fix orientation and downsample
        let processedImage = Self.prepareForDraft(image)

        // Append so earlier captures stay at lower indices
        photos.append(processedImage)
        uploadEncodeTasks.append(Self.makeUploadEncodeTask(for: processedImage))

        // Trim to max photos
        if photos.count > maxPhotos {
            photos = Array(photos.prefix(maxPhotos))
            while uploadEncodeTasks.count > maxPhotos {
                uploadEncodeTasks.removeLast().cancel()
            }
        }

        rebuildDuplicateCheckTask()

        // Bump tick for observers
        lastCaptureTick += 1
    }

    /// Replace photo at specific index
    func replacePhoto(at index: Int, with image: UIImage) {
        guard photos.indices.contains(index) else { return }
        let processedImage = Self.prepareForDraft(image)
        photos[index] = processedImage
        if uploadEncodeTasks.indices.contains(index) {
            uploadEncodeTasks[index].cancel()
            uploadEncodeTasks[index] = Self.makeUploadEncodeTask(for: processedImage)
        }
        rebuildDuplicateCheckTask()
        lastCaptureTick += 1
    }

    /// Remove photo at index
    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
        if uploadEncodeTasks.indices.contains(index) {
            uploadEncodeTasks[index].cancel()
            uploadEncodeTasks.remove(at: index)
        }
        rebuildDuplicateCheckTask()
        lastCaptureTick += 1
    }

    /// Clear all photos (on successful post or discard)
    func clearDraft() {
        photos.removeAll()
        uploadEncodeTasks.forEach { $0.cancel() }
        uploadEncodeTasks.removeAll()
        duplicateCheckTask?.cancel()
        duplicateCheckTask = nil
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

    // MARK: - Pre-encoded upload payloads

    /// Upload-ready JPEG for the photo at `index`, pre-encoded off the main
    /// thread when the photo was added. Nil if encoding failed.
    func uploadJPEGData(at index: Int) async -> Data? {
        guard uploadEncodeTasks.indices.contains(index) else { return nil }
        return await uploadEncodeTasks[index].value
    }

    /// Small base64 JPEG of the primary photo for the server-side duplicate
    /// hash check (the server only computes a perceptual hash from it).
    func duplicateCheckBase64() async -> String? {
        if let task = duplicateCheckTask {
            return await task.value
        }
        guard let primary = photos.first else { return nil }
        let task = Self.makeDuplicateCheckTask(for: primary)
        duplicateCheckTask = task
        return await task.value
    }

    private func rebuildDuplicateCheckTask() {
        duplicateCheckTask?.cancel()
        if let primary = photos.first {
            duplicateCheckTask = Self.makeDuplicateCheckTask(for: primary)
        } else {
            duplicateCheckTask = nil
        }
    }

    nonisolated private static func makeUploadEncodeTask(for image: UIImage) -> Task<Data?, Never> {
        Task.detached(priority: .userInitiated) {
            encodeForUpload(image)
        }
    }

    nonisolated private static func makeDuplicateCheckTask(for image: UIImage) -> Task<String?, Never> {
        Task.detached(priority: .userInitiated) {
            encodeForDuplicateCheck(image)
        }
    }

    // MARK: - Image Processing (thread-safe, callable off the main actor)

    /// Downscale + JPEG-encode for storage upload. 1600px / 0.7 keeps feed
    /// cards sharp while roughly halving upload size vs 2048px / 0.8.
    nonisolated static func encodeForUpload(_ image: UIImage) -> Data? {
        let scaled = downscale(image, maxDimension: 1600)
        return scaled.jpegData(compressionQuality: 0.7)
    }

    /// Small payload for the duplicate check: the server hashes the image
    /// down to a few dozen pixels, so 768px is far more than it needs.
    nonisolated static func encodeForDuplicateCheck(_ image: UIImage) -> String? {
        let scaled = downscale(image, maxDimension: 768)
        return scaled.jpegData(compressionQuality: 0.5)?.base64EncodedString()
    }

    /// Fix orientation and downsample to max 2048px. Safe to call from any
    /// thread — picker paths use it off-main before handing the image over.
    nonisolated static func prepareForDraft(_ image: UIImage) -> UIImage {
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

    nonisolated private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return image.resized(to: newSize) ?? image
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
