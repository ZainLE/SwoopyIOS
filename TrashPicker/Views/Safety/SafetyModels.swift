//
//  SafetyModels.swift
//  TrashPicker
//
//  Data models for UGC Safety & Report System
//

import Foundation

struct ReportPayload: Codable {
    enum Category: String, CaseIterable, Codable {
        case spamOrMisleading = "spam_or_misleading"
        case illegalOrUnsafe = "illegal_or_unsafe"
        case inappropriateContent = "inappropriate_content"
        case harassmentOrAbuse = "harassment_or_abuse"
        case hateOrViolence = "hate_or_violence"
        case fraudOrScam = "fraud_or_scam"
        case nudityOrSexual = "nudity_or_sexual_content"
        case impersonation = "impersonation"
        case other
        
        var displayName: String {
            switch self {
            case .spamOrMisleading: return SafetyStrings.categorySpam
            case .illegalOrUnsafe: return SafetyStrings.categoryIllegal
            case .inappropriateContent: return SafetyStrings.categoryInappropriate
            case .harassmentOrAbuse: return SafetyStrings.categoryHarassment
            case .hateOrViolence: return SafetyStrings.categoryHate
            case .fraudOrScam: return SafetyStrings.categoryFraud
            case .nudityOrSexual: return SafetyStrings.categoryNudity
            case .impersonation: return SafetyStrings.categoryImpersonation
            case .other: return SafetyStrings.categoryOther
            }
        }
    }
    
    let postId: String?
    let reportedUserId: String?
    let category: Category
    let notes: String?
}

struct BlockPayload: Codable {
    let userId: String
    let notes: String?
}
