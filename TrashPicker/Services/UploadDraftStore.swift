//
//  UploadDraftStore.swift
//  TrashPicker
//
//  Single source of truth for upload draft state
//

import SwiftUI
import UIKit
import Supabase

// Kept outside the @MainActor class so detached upload tasks can read it
// without actor hops.
private let uploadBucket = "item-photos"

@MainActor
final class UploadDraftStore: ObservableObject {
    @Published var photos: [UIImage] = []
    @Published private(set) var lastCaptureTick = 0

    private let maxPhotos = 3

    /// Post id shared by eager storage uploads and the final post-create
    /// payload, so uploads that start while the user fills the form land in
    /// the right folder. Regenerated whenever the draft is cleared.
    private(set) var draftPostId = UUID()

    /// Per-photo background work. JPEGs are pre-encoded the moment a photo
    /// lands in the draft, and the storage upload starts right behind the
    /// encode — concurrent with the user filling the form — so submit only
    /// awaits whatever hasn't finished yet.
    private struct Slot {
        let encodeTask: Task<Data?, Never>
        var uploadTask: Task<URL, Error>?
        var remotePath: String?
        let addedAt: Date
    }

    private var slots: [Slot] = []
    private var duplicateCheckTask: Task<String?, Never>?

    /// Insert photo preserving capture order, trim to max, bump tick
    func insertPrimary(_ image: UIImage) {
        // Process image: fix orientation and downsample
        let processedImage = Self.prepareForDraft(image)

        // Append so earlier captures stay at lower indices
        photos.append(processedImage)
        let addedAt = Date()
        slots.append(Slot(encodeTask: Self.makeUploadEncodeTask(for: processedImage, addedAt: addedAt),
                          uploadTask: nil,
                          remotePath: nil,
                          addedAt: addedAt))

        // Trim to max photos
        if photos.count > maxPhotos {
            photos = Array(photos.prefix(maxPhotos))
            while slots.count > maxPhotos {
                tearDownSlot(slots.removeLast())
            }
        }

        startUploadIfPossible(at: slots.count - 1)
        rebuildDuplicateCheckTask()

        // Bump tick for observers
        lastCaptureTick += 1
    }

    /// Replace photo at specific index
    func replacePhoto(at index: Int, with image: UIImage) {
        guard photos.indices.contains(index) else { return }
        let processedImage = Self.prepareForDraft(image)
        photos[index] = processedImage
        if slots.indices.contains(index) {
            tearDownSlot(slots[index])
            let addedAt = Date()
            slots[index] = Slot(encodeTask: Self.makeUploadEncodeTask(for: processedImage, addedAt: addedAt),
                                uploadTask: nil,
                                remotePath: nil,
                                addedAt: addedAt)
            startUploadIfPossible(at: index)
        }
        rebuildDuplicateCheckTask()
        lastCaptureTick += 1
    }

    /// Remove photo at index
    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
        if slots.indices.contains(index) {
            tearDownSlot(slots.remove(at: index))
        }
        rebuildDuplicateCheckTask()
        lastCaptureTick += 1
    }

    /// Clear all photos (on successful post or discard).
    /// - Parameter deleteRemoteUploads: pass `false` after a successful
    ///   submit, where the eagerly uploaded objects now back a real post.
    ///   The default (`true`) is for abandoned drafts and best-effort
    ///   deletes anything already in storage.
    func clearDraft(deleteRemoteUploads: Bool = true) {
        photos.removeAll()
        slots.forEach { tearDownSlot($0, deleteRemote: deleteRemoteUploads) }
        slots.removeAll()
        duplicateCheckTask?.cancel()
        duplicateCheckTask = nil
        draftPostId = UUID()
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

    // MARK: - Eager storage uploads

    /// Kick off the storage upload for the slot at `index`, chained behind
    /// its encode task. Skipped when there is no auth session yet — submit
    /// falls back to uploading inline in that case.
    private func startUploadIfPossible(at index: Int) {
        guard slots.indices.contains(index), slots[index].uploadTask == nil else { return }
        guard let userId = SupabaseService.shared.session?.user.id else {
            #if DEBUG
            DLog("[UPLOAD EAGER] skipped (no session) index=\(index)")
            #endif
            return
        }
        // Unique object name per photo instance: replacing or reordering a
        // photo never collides with an earlier upload of the same slot.
        let path = "posts/\(userId.uuidString.lowercased())/\(draftPostId.uuidString)/\(UUID().uuidString).jpg"
        slots[index].remotePath = path
        slots[index].uploadTask = Self.makeUploadTask(
            encodeTask: slots[index].encodeTask,
            client: SupabaseService.shared.client,
            path: path,
            addedAt: slots[index].addedAt
        )
    }

    /// Result of the eager upload for the photo at `index`, or nil when no
    /// eager upload was started or it failed — callers fall back to an
    /// inline upload so a background failure never breaks submit.
    func eagerUploadResult(at index: Int) async -> URL? {
        guard slots.indices.contains(index), let task = slots[index].uploadTask else { return nil }
        return try? await task.value
    }

    /// Cancel a slot's background work and best-effort delete anything it
    /// already put in storage (abandoned drafts must not leave orphans).
    private func tearDownSlot(_ slot: Slot, deleteRemote: Bool = true) {
        slot.encodeTask.cancel()
        guard let uploadTask = slot.uploadTask else { return }
        uploadTask.cancel()
        guard deleteRemote, let path = slot.remotePath else { return }
        let client = SupabaseService.shared.client
        Task.detached(priority: .utility) {
            // Let the upload settle first so the delete can't race a write.
            _ = try? await uploadTask.value
            do {
                _ = try await client.storage.from(uploadBucket).remove(paths: [path])
                #if DEBUG
                DLog("[UPLOAD EAGER] removed abandoned object \(path)")
                #endif
            } catch {
                #if DEBUG
                DLog("[UPLOAD EAGER] orphan cleanup failed (harmless) \(path): \(error.localizedDescription)")
                #endif
            }
        }
    }

    nonisolated private static func makeUploadTask(
        encodeTask: Task<Data?, Never>,
        client: SupabaseClient,
        path: String,
        addedAt: Date
    ) -> Task<URL, Error> {
        Task.detached(priority: .userInitiated) {
            guard let data = await encodeTask.value, !data.isEmpty else {
                throw UploadError.imageProcessingFailed
            }
            try Task.checkCancellation()
            let start = Date()
            // upsert so a submit-time retry of the same path can't 409.
            try await client.storage
                .from(uploadBucket)
                .upload(path: path,
                        file: data,
                        options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
            #if DEBUG
            let uploadMs = Int(Date().timeIntervalSince(start) * 1000)
            let sinceAddMs = Int(Date().timeIntervalSince(addedAt) * 1000)
            DLog("[TIMING] eager upload ok bytes=\(data.count) upload=\(uploadMs)ms capture→uploaded=\(sinceAddMs)ms \(path)")
            #endif
            return try client.storage.from(uploadBucket).getPublicURL(path: path)
        }
    }

    // MARK: - Pre-encoded upload payloads

    /// Upload-ready JPEG for the photo at `index`, pre-encoded off the main
    /// thread when the photo was added. Nil if encoding failed.
    func uploadJPEGData(at index: Int) async -> Data? {
        guard slots.indices.contains(index) else { return nil }
        return await slots[index].encodeTask.value
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

    nonisolated private static func makeUploadEncodeTask(for image: UIImage, addedAt: Date) -> Task<Data?, Never> {
        Task.detached(priority: .userInitiated) {
            let data = encodeForUpload(image)
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(addedAt) * 1000)
            DLog("[TIMING] capture→encode-ready \(ms)ms bytes=\(data?.count ?? 0)")
            #endif
            return data
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
