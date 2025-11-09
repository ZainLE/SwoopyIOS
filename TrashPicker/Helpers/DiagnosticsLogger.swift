import Foundation
import os.log

#if DEBUG || RESERVATIONS_DIAGNOSTICS

// MARK: - Diagnostics Logger
// Structured, end-to-end diagnostics for reservation button actions
// Logs: tap → preconditions → request build → network → response → state mutations → auth changes
// All logs are JSON lines with correlation IDs for tracing

enum DiagCategory: String {
    case action     // User actions (tap, confirm)
    case request    // Network request start
    case response   // Network response end
    case store      // State mutations
    case error      // Errors
    case auth       // Auth state changes
}

struct DiagnosticsLogger {
    private static let logger = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "reservations-diag")
    
    // In-memory ring buffer (last 100 events)
    private static var ringBuffer: [DiagEvent] = []
    private static let ringBufferLock = NSLock()
    private static let maxRingBufferSize = 100
    
    struct DiagEvent: Codable {
        let timestamp: String
        let category: String
        let event: String
        let fields: [String: String]
    }
    
    // MARK: - Public Logging API
    
    static func log(_ category: DiagCategory, _ event: String, fields: [String: Any] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        // Convert all field values to strings, redacting sensitive data
        var sanitizedFields: [String: String] = [:]
        for (key, value) in fields {
            sanitizedFields[key] = sanitize(key: key, value: value)
        }
        
        // Add to ring buffer
        let diagEvent = DiagEvent(
            timestamp: timestamp,
            category: category.rawValue,
            event: event,
            fields: sanitizedFields
        )
        
        ringBufferLock.lock()
        ringBuffer.append(diagEvent)
        if ringBuffer.count > maxRingBufferSize {
            ringBuffer.removeFirst()
        }
        ringBufferLock.unlock()
        
        // Log as JSON line
        if let jsonData = try? JSONEncoder().encode(diagEvent),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            os_log("%{public}@", log: logger, type: .debug, jsonString)
        }
    }
    
    // MARK: - Correlation ID Generation
    
    static func generateCorrelationId() -> String {
        return UUID().uuidString.prefix(8).lowercased()
    }
    
    // MARK: - PII Redaction
    
    private static func sanitize(key: String, value: Any) -> String {
        let keyLower = key.lowercased()
        let stringValue = "\(value)"
        
        // Redact authorization headers
        if keyLower.contains("authorization") || keyLower.contains("bearer") {
            return "[REDACTED]"
        }
        
        // Redact cookies
        if keyLower.contains("cookie") {
            return "[REDACTED]"
        }
        
        // Redact tokens
        if keyLower.contains("token") {
            return "[REDACTED]"
        }
        
        // Mask phone numbers (show last 2 digits)
        if keyLower.contains("phone") {
            if stringValue.count > 2 {
                let lastTwo = stringValue.suffix(2)
                return "***\(lastTwo)"
            }
            return "***"
        }
        
        // Redact addresses
        if keyLower.contains("address") || keyLower.contains("street") {
            return "[REDACTED]"
        }
        
        // Redact coordinates (approximate location)
        if keyLower.contains("lat") || keyLower.contains("lng") || keyLower.contains("lon") {
            if let doubleValue = Double(stringValue) {
                return String(format: "%.2f", doubleValue) // Only 2 decimal places
            }
        }
        
        return stringValue
    }
    
    // MARK: - Request/Response Helpers
    
    static func logRequestStart(
        corr: String,
        method: String,
        url: String,
        headers: [String: String],
        bodySize: Int?
    ) {
        var fields: [String: Any] = [
            "corr": corr,
            "method": method,
            "url": url,
            "bodySize": bodySize ?? 0
        ]
        
        // Add redacted headers
        for (key, value) in headers {
            fields["header_\(key)"] = sanitize(key: key, value: value)
        }
        
        log(.request, "request.start", fields: fields)
    }
    
    static func logResponseEnd(
        corr: String,
        requestId: String?,
        statusCode: Int,
        bodySize: Int,
        durationMs: Int,
        error: String?
    ) {
        var fields: [String: Any] = [
            "corr": corr,
            "statusCode": statusCode,
            "bodySize": bodySize,
            "durationMs": durationMs
        ]
        
        if let requestId = requestId {
            fields["requestId"] = requestId
        }
        
        if let error = error {
            fields["error"] = error
        }
        
        log(.response, "response.end", fields: fields)
    }
    
    // MARK: - Auth State Changes
    
    static func logAuthStateChange(
        corr: String,
        event: String,
        reason: String
    ) {
        log(.auth, event, fields: [
            "corr": corr,
            "reason": reason
        ])
    }
    
    // MARK: - Main Thread Assertion
    
    static func assertMainThread(corr: String, context: String) {
        let onMain = Thread.isMainThread
        if !onMain {
            log(.error, "thread.violation", fields: [
                "corr": corr,
                "context": context,
                "onMain": false
            ])
        }
    }
    
    // MARK: - Ring Buffer Access (for debugging)
    
    static func getRecentEvents(limit: Int = 50) -> [DiagEvent] {
        ringBufferLock.lock()
        defer { ringBufferLock.unlock() }
        return Array(ringBuffer.suffix(limit))
    }
    
    static func clearRingBuffer() {
        ringBufferLock.lock()
        ringBuffer.removeAll()
        ringBufferLock.unlock()
    }
}

// MARK: - Convenience Aliases

typealias Diag = DiagnosticsLogger

#endif
