import Foundation

/// Server-side profile model - single source of truth for profile completeness and onboarding status
struct ProfileDTO: Codable, Equatable {
    let id: String
    let fullName: String?
    let firstName: String?
    let lastName: String?
    let phone: String?
    let avatarUrl: String?
    let city: String?
    let phoneVerified: Bool?
    let onboardingCompleted: Bool
    let updatedAt: Date?

    init(
        id: String,
        fullName: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        phone: String? = nil,
        avatarUrl: String? = nil,
        city: String? = nil,
        phoneVerified: Bool? = nil,
        onboardingCompleted: Bool,
        updatedAt: Date?
    ) {
        self.id = id
        self.fullName = fullName
        self.firstName = firstName
        self.lastName = lastName
        self.phone = phone
        self.avatarUrl = avatarUrl
        self.city = city
        self.phoneVerified = phoneVerified
        self.onboardingCompleted = onboardingCompleted
        self.updatedAt = updatedAt
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case firstName = "first_name"
        case lastName = "last_name"
        case phone
        case avatarUrl = "avatar_url"
        case photoUrl = "photo_url"
        case city
        case phoneVerified = "phone_verified"
        case onboardingCompleted = "onboarding_completed"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        let avatarString = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
            ?? container.decodeIfPresent(String.self, forKey: .photoUrl)
        avatarUrl = avatarString
        city = try container.decodeIfPresent(String.self, forKey: .city)
        phoneVerified = try container.decodeIfPresent(Bool.self, forKey: .phoneVerified)
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        if let updatedString = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            updatedAt = iso.date(from: updatedString) ?? ISO8601DateFormatter().date(from: updatedString)
        } else {
            updatedAt = nil
        }
    }
    
    /// Profile is complete if it has name, phone, and avatar
    var isComplete: Bool {
        hasName && hasPhone && hasAvatar
    }
    
    var hasName: Bool {
        if let full = fullName, !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let first = firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !first.isEmpty || !last.isEmpty
    }
    
    var hasPhone: Bool {
        guard let phone = phone else { return false }
        return !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var hasAvatar: Bool {
        guard let url = avatarUrl else { return false }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var isPhoneVerified: Bool {
        phoneVerified ?? false
    }
    
    var requiresPhoneVerification: Bool {
        hasPhone && !isPhoneVerified
    }
    
    var displayName: String {
        if let full = fullName, !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return full
        }
        let first = firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? "User" : combined
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(fullName, forKey: .fullName)
        try container.encodeIfPresent(firstName, forKey: .firstName)
        try container.encodeIfPresent(lastName, forKey: .lastName)
        try container.encodeIfPresent(phone, forKey: .phone)
        try container.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(phoneVerified, forKey: .phoneVerified)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
        if let updatedAt {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(iso.string(from: updatedAt), forKey: .updatedAt)
        }
    }
}

/// Profile update payload for PATCH requests
struct ProfileUpdateDTO: Codable {
    var fullName: String?
    var firstName: String?
    var lastName: String?
    var phone: String?
    var avatarUrl: String?
    var city: String?
    var onboardingCompleted: Bool?
    
    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case firstName = "first_name"
        case lastName = "last_name"
        case phone
        case avatarUrl = "avatar_url"
        case city
        case onboardingCompleted = "onboarding_completed"
    }
}
