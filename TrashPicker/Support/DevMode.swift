import Foundation

enum DevMode {
    #if DEBUG
    static let authBypassEnabled = false  // must remain false in production builds and during QA
    static let mockDataEnabled   = false
    #else
    static let authBypassEnabled = false
    static let mockDataEnabled   = false
    #endif
}
