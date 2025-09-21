import SwiftUI

@Observable
class AppRouter {
    var selectedTab: AppTab
    var presentedSheet: PresentedSheet?
    
    init(initialTab: AppTab = .feed) {
        self.selectedTab = initialTab
    }
}

enum PresentedSheet: Identifiable {
    case camera
    case upload
    
    var id: String {
        switch self {
        case .camera:
            return "camera"
        case .upload:
            return "upload"
        }
    }
}
