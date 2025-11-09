import Foundation
import OSLog

/// Centralized logging infrastructure using OSLog with privacy redaction.
/// All logs default to `.private` for sensitive data; mark only known-safe strings as `.public`.
/// In Release builds, only `.error` and `.fault` levels are emitted.
enum AppLogger {
    
    // MARK: - Subsystem Loggers
    
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.trashpicker.app"
    
    static let flow = Logger(subsystem: subsystem, category: "flow")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let profile = Logger(subsystem: subsystem, category: "profile")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    
    // MARK: - Convenience Methods
    
    /// Log flow state transitions (DEBUG only)
    static func logFlow(_ message: String, file: String = #file, line: Int = #line) {
        #if DEBUG
        flow.debug("[\(extractFileName(file)):\(line)] \(message)")
        #endif
    }
    
    /// Log authentication events (DEBUG only for info, always for errors)
    static func logAuth(_ message: String, level: LogLevel = .debug, file: String = #file, line: Int = #line) {
        let location = "[\(extractFileName(file)):\(line)]"
        switch level {
        case .debug:
            #if DEBUG
            auth.debug("\(location) \(message)")
            #endif
        case .info:
            #if DEBUG
            auth.info("\(location) \(message)")
            #endif
        case .notice:
            auth.notice("\(location) \(message)")
        case .error:
            auth.error("\(location) \(message)")
        case .fault:
            auth.fault("\(location) \(message)")
        }
    }
    
    /// Log profile operations (DEBUG only for info, always for errors)
    static func logProfile(_ message: String, level: LogLevel = .debug, file: String = #file, line: Int = #line) {
        let location = "[\(extractFileName(file)):\(line)]"
        switch level {
        case .debug:
            #if DEBUG
            profile.debug("\(location) \(message)")
            #endif
        case .info:
            #if DEBUG
            profile.info("\(location) \(message)")
            #endif
        case .notice:
            profile.notice("\(location) \(message)")
        case .error:
            profile.error("\(location) \(message)")
        case .fault:
            profile.fault("\(location) \(message)")
        }
    }
    
    /// Log network operations (DEBUG only for info, always for errors)
    static func logNetwork(_ message: String, level: LogLevel = .debug, file: String = #file, line: Int = #line) {
        let location = "[\(extractFileName(file)):\(line)]"
        switch level {
        case .debug:
            #if DEBUG
            network.debug("\(location) \(message)")
            #endif
        case .info:
            #if DEBUG
            network.info("\(location) \(message)")
            #endif
        case .notice:
            network.notice("\(location) \(message)")
        case .error:
            network.error("\(location) \(message)")
        case .fault:
            network.fault("\(location) \(message)")
        }
    }
    
    /// Log storage operations (DEBUG only)
    static func logStorage(_ message: String, level: LogLevel = .debug, file: String = #file, line: Int = #line) {
        let location = "[\(extractFileName(file)):\(line)]"
        switch level {
        case .debug:
            #if DEBUG
            storage.debug("\(location) \(message)")
            #endif
        case .info:
            #if DEBUG
            storage.info("\(location) \(message)")
            #endif
        case .notice:
            storage.notice("\(location) \(message)")
        case .error:
            storage.error("\(location) \(message)")
        case .fault:
            storage.fault("\(location) \(message)")
        }
    }
    
    /// Log UI events (DEBUG only)
    static func logUI(_ message: String, file: String = #file, line: Int = #line) {
        #if DEBUG
        ui.debug("[\(extractFileName(file)):\(line)] \(message)")
        #endif
    }
    
    // MARK: - Privacy Helpers
    
    /// Redact sensitive string (email, token, etc.) with hash for correlation
    static func redactHash(_ value: String) -> String {
        let hash = value.hashValue
        return "***\(abs(hash) % 10000)"
    }
    
    /// Redact user ID for privacy (show last 4 chars only)
    static func redactUserId(_ userId: String?) -> String {
        guard let userId = userId, userId.count > 4 else { return "****" }
        let suffix = userId.suffix(4)
        return "***\(suffix)"
    }
    
    // MARK: - Private Helpers
    
    private static func extractFileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
    
    enum LogLevel {
        case debug
        case info
        case notice
        case error
        case fault
    }
}

// MARK: - Deprecated Logger Migration

/// Legacy AuditLog - redirects to AppLogger for migration
@available(*, deprecated, message: "Use AppLogger instead")
enum AuditLog {
    static func flow(_ msg: String) {
        AppLogger.logFlow(msg)
    }
    static func auth(_ msg: String) {
        AppLogger.logAuth(msg)
    }
    static func gate(_ msg: String) {
        AppLogger.logFlow("GATE: \(msg)")
    }
}
