import Foundation

enum DevMode {
    #if DEBUG
    static let authBypassEnabled = false  // <— flip to false when you want to test real auth
    static let mockDataEnabled   = true
    #else
    static let authBypassEnabled = false
    static let mockDataEnabled   = false
    #endif
}
