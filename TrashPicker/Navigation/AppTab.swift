import SwiftUI

enum AppTab: Int, CaseIterable {
    case feed = 0
    case reservations = 1
    case profile = 2
    case camera = 3
    
    var title: String {
        switch self {
        case .feed:
            return "Feed"
        case .reservations:
            return "Reservations"
        case .profile:
            return "Profile"
        case .camera:
            return "Camera"
        }
    }
    
    var icon: String {
        switch self {
        case .feed:
            return "rectangle.grid.2x2.fill"
        case .reservations:
            return "clock.badge.checkmark"
        case .profile:
            return "person.crop.circle"
        case .camera:
            return "plus"
        }
    }
}
