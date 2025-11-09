import Foundation
import SwiftUI

enum ConditionBackend: String, Codable {
    case bad
    case good
    case excellent
}

enum ConditionUI: String, CaseIterable, Identifiable, Codable {
    case needsFixing
    case good
    case likeNew
    
    var id: ConditionUI { self }
    
    var displayName: String {
        switch self {
        case .needsFixing: return "Needs fixing"
        case .good: return "Good"
        case .likeNew: return "Like new"
        }
    }
    
    var backend: ConditionBackend {
        switch self {
        case .needsFixing: return .bad
        case .good: return .good
        case .likeNew: return .excellent
        }
    }
    
    var backendValue: String { backend.rawValue }
    
    var title: String { displayName }
    
    var dotColor: Color {
        switch self {
        case .likeNew:
            return Color("SwoopyGreen")
        case .good:
            return Color("SwoopyOlive")
        case .needsFixing:
            return Color("SwoopyOrange")
        }
    }
}

extension ConditionBackend {
    var ui: ConditionUI {
        switch self {
        case .bad: return .needsFixing
        case .good: return .good
        case .excellent: return .likeNew
        }
    }
}

typealias ItemCondition = ConditionUI
typealias Condition = ConditionUI
