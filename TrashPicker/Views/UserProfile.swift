//
//  UserProfile.swift
//  TrashPicker
//
//  Created by Zain Latif  on 8/9/25.
//


import Foundation
import UIKit

struct UserProfile: Codable {
    var username: String
    var email: String
    var phone: String
    var address: String
    var avatarFilename: String?
}

final class UserProfileStore: ObservableObject {
    static let shared = UserProfileStore()

    @Published var profile: UserProfile {
        didSet { save() }
    }

    private let key = "user_profile_v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode(UserProfile.self, from: data) {
            self.profile = p
        } else {
            self.profile = UserProfile(username: "Your Name", email: "you@example.com", phone: "", address: "", avatarFilename: nil)
            save()
        }
    }

    func saveAvatar(_ image: UIImage) {
        let filename = "avatar-\(UUID().uuidString).jpg"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url, options: .atomic)
            profile.avatarFilename = filename
        }
    }

    func avatarURL() -> URL? {
        guard let f = profile.avatarFilename else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(f)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}