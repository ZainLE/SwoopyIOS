// ImageStorage.swift
import Foundation
import UIKit
import Supabase

enum ImageStorage {
    
    // MARK: - Path Generation (Testable)
    
    /// Generate storage path for a post image
    /// - Parameters:
    ///   - userId: User ID
    ///   - postId: Post ID
    ///   - index: Image index (0-based)
    /// - Returns: Storage path string
    static func buildPostImagePath(userId: UUID, postId: UUID, index: Int) -> String {
        let userIdLower = userId.uuidString.lowercased()
        return "posts/\(userIdLower)/\(postId.uuidString)/\(index).jpg"
    }
    
    /// Generate FileOptions for JPEG uploads
    /// - Returns: FileOptions with JPEG content type and upsert enabled
    static func buildJPEGFileOptions() -> FileOptions {
        return FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)
    }

    // MARK: - Upload Methods

    /// Upload one JPEG and return (storage path, signed URL string).
    /// NOTE: Prefer `uploadJPEGs` for post flows to adhere to
    /// users/<userId>/<postId>/<index>.jpg naming.
    static func uploadJPEG(
        client: SupabaseClient,
        data: Data,
        uploader: UUID
    ) async throws -> (path: String, publicURL: String) {

            // Deprecated path for ad-hoc uploads; post flow should use uploadJPEGs
            let path = "items/\(uploader.uuidString)/\(UUID().uuidString).jpg"
            let options = FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true)

        _ = try await client
            .storage
            .from(SupabaseConfig.photosBucket)
            .upload(path: path, file: data, options: options)

        // Signed URL (works with private buckets)
        let url = try await client
            .storage
            .from(SupabaseConfig.photosBucket)
            .createSignedURL(path: path, expiresIn: 60 * 60 * 24 * 7) // 7 days

        return (path, url.absoluteString)
    }

    /// Upload up to 3 JPEGs and return their signed URLs (ordered).
    /// Path: users/<userId>/<postId>/<index>.jpg
    static func uploadJPEGs(
        client: SupabaseClient,
        images: [UIImage],
        uploader: UUID,
        postId: UUID
    ) async throws -> [URL] {

        var urls: [URL] = []
        let options = buildJPEGFileOptions()

        for (i, img) in images.prefix(3).enumerated() {
            guard let data = img.jpegData(compressionQuality: 0.8), data.count > 0 else {
                throw UploadError.imageProcessingFailed
            }
            let path = buildPostImagePath(userId: uploader, postId: postId, index: i)

            _ = try await client
                .storage
                .from(SupabaseConfig.photosBucket)
                .upload(path: path, file: data, options: options)

            let url = try await client
                .storage
                .from(SupabaseConfig.photosBucket)
                .createSignedURL(path: path, expiresIn: 60 * 60 * 24 * 7)

            urls.append(url)
        }
        return urls
    }

    /// Upload a file from disk and return a signed URL (7 days). Uses JPEG content type, upsert enabled.
    /// NOTE: Prefer `uploadJPEGs` for post flows to adhere to users/<userId>/<postId>/<index>.jpg.
    static func uploadFileURL(
        client: SupabaseClient,
        fileURL: URL,
        uploader: UUID
    ) async throws -> String {

        let folder = "items/\(uploader.uuidString)"
        let filename = fileURL.lastPathComponent.isEmpty
            ? "upload-\(UUID().uuidString).jpg"
            : fileURL.lastPathComponent
        let path = "\(folder)/\(filename)"
        let options = FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true)

        // Efficiently map file into memory if possible
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])

        _ = try await client
            .storage
            .from(SupabaseConfig.photosBucket)
            .upload(path: path, file: data, options: options)

        let url = try await client
            .storage
            .from(SupabaseConfig.photosBucket)
            .createSignedURL(path: path, expiresIn: 60 * 60 * 24 * 7)

        return url.absoluteString
    }
}
