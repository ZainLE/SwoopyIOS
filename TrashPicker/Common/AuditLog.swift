import Foundation

enum AuditLog {
    static func flow(_ msg: String) {
        #if DEBUG
        print("[FLOW] \(msg)")
        #endif
    }
    static func auth(_ msg: String) {
        #if DEBUG
        print("[AUTH] \(msg)")
        #endif
    }
    static func gate(_ msg: String) {
        #if DEBUG
        print("[GATE] \(msg)")
        #endif
    }
}
