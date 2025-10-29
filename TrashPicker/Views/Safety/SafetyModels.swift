//
//  SafetyModels.swift
//  TrashPicker
//
//  Data models for UGC Safety & Report System
//

import Foundation

struct ReportPayload: Codable {
    enum Category: String, CaseIterable, Codable {
        case spam
        case harassment
        case hate
        case fraud
        case illegal
        case inappropriate
        case other
        
        var displayName: String {
            switch self {
            case .spam: return SafetyStrings.categorySpam
            case .harassment: return SafetyStrings.categoryHarassment
            case .hate: return SafetyStrings.categoryHate
            case .fraud: return SafetyStrings.categoryFraud
            case .illegal: return SafetyStrings.categoryIllegal
            case .inappropriate: return SafetyStrings.categoryInappropriate
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

enum SafetyDemoMode {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "safety_demo_mode")
    }
    
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "safety_demo_mode")
    }
}
