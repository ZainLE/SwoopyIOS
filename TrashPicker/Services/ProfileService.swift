import Foundation
import UIKit

protocol ProfileService {
    func uploadAvatar(_ image: UIImage) async throws -> URL
    func updateProfile(fullName: String, phone: String?, avatarURL: URL?) async throws
}

struct MockProfileService: ProfileService {
    func uploadAvatar(_ image: UIImage) async throws -> URL {
        try await Task.sleep(nanoseconds: 400_000_000)
        return URL(string: "https://example.com/profile/avatar.jpg")!
    }
    
    func updateProfile(fullName: String, phone: String?, avatarURL: URL?) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}

// FUTURE (Supabase):
// let userId = supabase.auth.session.user.id
// let filePath = "profile-photos/\(userId)/avatar.jpg"
// guard let jpegData = image.jpegData(compressionQuality: 0.85) else { return }
// try await supabase.storage
//     .from("profile-photos")
//     .upload(path: filePath, data: jpegData, fileOptions: .init(contentType: "image/jpeg", upsert: true))
// let publicURL = try supabase.storage
//     .from("profile-photos")
//     .getPublicURL(path: filePath)
// try await api.updateProfile(fullName: fullName, phone: phone, avatarURL: publicURL)
