import Foundation
import UIKit
import Supabase

protocol ProfileService {
    func uploadAvatar(_ image: UIImage) async throws -> URL
    func updateProfile(fullName: String, phone: String?, avatarURL: URL?) async throws
}

extension SupabaseProfileService {
    func fetchProfile() async throws -> ProfileDTO {
        let token = await MainActor.run { supabase.currentAccessTokenOrNil() } ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }

        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/profile") else {
            throw SimpleError(message: "Invalid URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SimpleError(message: "Network error") }

        switch http.statusCode {
        case 200:
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let raw else { throw SimpleError(message: "Bad response") }
            let id = (raw["user_id"] as? String) ?? (raw["id"] as? String) ?? ""
            let first = raw["first_name"] as? String
            let last = raw["last_name"] as? String
            let phone = raw["phone"] as? String
            let photo = raw["photo_url"] as? String
            let updatedAtStr = raw["updated_at"] as? String
            let onboarding = (raw["onboarding_completed"] as? Bool) ?? false

            var updatedDate: Date? = nil
            if let s = updatedAtStr {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                updatedDate = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }

            return ProfileDTO(
                id: id,
                fullName: nil,
                firstName: first,
                lastName: last,
                phone: phone,
                avatarUrl: photo,
                city: nil,
                onboardingCompleted: onboarding,
                updatedAt: updatedDate
            )
        case 401: throw SimpleError(message: "Please sign in again.")
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SimpleError(message: text.isEmpty ? "Couldn't load profile" : text)
        }
    }

    func updateProfile(firstName: String?, lastName: String?, phone: String?) async throws -> ProfileDTO {
        let token = await MainActor.run { supabase.currentAccessTokenOrNil() } ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }
        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/profile") else {
            throw SimpleError(message: "Invalid URL")
        }

        var body: [String: Any] = [:]
        if let firstName { body["first_name"] = firstName }
        if let lastName { body["last_name"] = lastName }
        if let phone { body["phone"] = phone }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SimpleError(message: "Network error") }

        switch http.statusCode {
        case 200:
            let profile = try await fetchProfile()
            await MainActor.run {
                FeedViewModel.requestFeedRefresh()
                NotificationCenter.default.post(name: .profileDidUpdate, object: nil)
            }
            return profile
        case 401: throw SimpleError(message: "Please sign in again.")
        case 422: throw SimpleError(message: "Enter a valid phone number in international format (e.g., +34…)")
        case 429: throw SimpleError(message: "You’re updating too quickly. Please try again shortly.")
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SimpleError(message: text.isEmpty ? "Couldn't save changes. Please try again." : text)
        }
    }

    func uploadAvatar(image: UIImage) async throws -> URL {
        let token = await MainActor.run { supabase.currentAccessTokenOrNil() } ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }
        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/profile/photo") else {
            throw SimpleError(message: "Invalid URL")
        }

        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw SimpleError(message: "Could not encode image")
        }
        if jpeg.count > 5 * 1024 * 1024 { throw SimpleError(message: "Image too large (max 5MB)") }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        let lineBreak = "\r\n"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append(lineBreak.data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SimpleError(message: "Network error") }
        switch http.statusCode {
        case 200:
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let urlStr = obj?["photo_url"] as? String, let url = URL(string: urlStr) {
                return url
            }
            throw SimpleError(message: "Upload failed")
        case 401: throw SimpleError(message: "Please sign in again.")
        case 422: throw SimpleError(message: "Invalid image format or size.")
        case 429: throw SimpleError(message: "You’re updating too quickly. Please try again shortly.")
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SimpleError(message: text.isEmpty ? "Couldn't upload photo. Please try again." : text)
        }
    }
}

struct MockProfileService: ProfileService {
    @MainActor func uploadAvatar(_ image: UIImage) async throws -> URL {
        try await Task.sleep(nanoseconds: 400_000_000)
        return URL(string: "https://example.com/profile/avatar.jpg")!
    }
    
    @MainActor func updateProfile(fullName: String, phone: String?, avatarURL: URL?) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}

/// Real Supabase-backed ProfileService implementation used by onboarding
struct SupabaseProfileService: ProfileService {
    @MainActor private var supabase: SupabaseService { .shared }
    
    @MainActor
    func uploadAvatar(_ image: UIImage) async throws -> URL {
        guard let session = supabase.session else {
            throw SimpleError(message: "Not authenticated")
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw SimpleError(message: "Could not encode image")
        }
        let uid = session.user.id.uuidString
        
        // Use consistent path structure: users/{auth.uid()}/avatar_{timestamp}.jpg
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "users/\(uid)/avatar_\(timestamp).jpg"
        
        // Upload (upsert) to profile-photos bucket
        let options = FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true)
        _ = try await supabase.client
            .storage
            .from("profile-photos")
            .upload(path: path, file: jpeg, options: options)
        
        // Get public URL (preferred over signed URL for public buckets)
        let publicURL = try supabase.client
            .storage
            .from("profile-photos")
            .getPublicURL(path: path)
        
        return publicURL
    }
    
    @MainActor
    func updateProfile(fullName: String, phone: String?, avatarURL: URL?) async throws {
        // Split full name into first/last for API contract
        let components = fullName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let first = components.first.map(String.init)
        let last = components.count > 1 ? String(components[1]) : nil

        let api = ApiService(supabaseService: supabase)
        let patch = ProfilePatch(
            firstName: first,
            lastName: last,
            phone: phone,
            city: nil,
            avatarUrl: avatarURL?.absoluteString
        )
        _ = try await api.updateProfile(patch)
        // SupabaseService will refresh profile elsewhere as needed
    }
}
