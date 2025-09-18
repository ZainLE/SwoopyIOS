// ImageStorage.swift
import Foundation
import UIKit
import Supabase

enum ImageStorage {

    /// Upload one JPEG and return (storage path, signed URL string).
    static func uploadJPEG(client: SupabaseClient, data: Data, uploader: UUID) async throws -> (path: String, publicURL: String) {
        let path = "\(uploader.uuidString)/\(UUID().uuidString).jpg"
        let options = FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)

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

    /// Upload up to 3 JPEGs and return their signed URL strings (ordered).
    static func uploadJPEGs(client: SupabaseClient, images: [UIImage], uploader: UUID) async throws -> [String] {
        var urls: [String] = []
        let folder = uploader.uuidString
        let options = FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)

        for (i, img) in images.prefix(3).enumerated() {
            guard let data = img.jpegData(compressionQuality: 0.85) else { continue }
            let path = "\(folder)/\(UUID().uuidString)_\(i).jpg"

            _ = try await client
                .storage
                .from(SupabaseConfig.photosBucket)
                .upload(path: path, file: data, options: options)

            let url = try await client
                .storage
                .from(SupabaseConfig.photosBucket)
                .createSignedURL(path: path, expiresIn: 60 * 60 * 24 * 7)

            urls.append(url.absoluteString)
        }
        return urls
    }
}
