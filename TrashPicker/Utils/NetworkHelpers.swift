import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Unified retry helper for all API calls
/// Call an async operation; if we get 401/unauthorized, refresh and retry once.
@MainActor
func fetchWithRetry<T>(
    svc: SupabaseService,
    _ operation: @escaping () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch {
        // Don't retry cancellations
        if error.isCancellationLike {
            throw error
        }
        
        let msg = error.localizedDescription.lowercased()
        if msg.contains("401") || msg.contains("unauthorized") {
            do {
                try await svc.refreshSessionIfNeeded()
                return try await operation()  // retry once
            } catch {
                // DO NOT auto-signOut() - surface auth error instead
                throw AuthError.sessionExpired
            }
        }
        throw error
    }
}

/// Auth-specific errors for better error handling
enum AuthError: Error, LocalizedError {
    case sessionExpired
    
    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return "Please sign in again to continue."
        }
    }
}

// MARK: - Cancellation Detection

extension Error {
    /// Returns true if this error represents a task cancellation or network cancellation
    var isCancellationLike: Bool {
        // Swift Concurrency cancellation
        if self is CancellationError {
            return true
        }
        
        // URLSession cancellation (NSURLErrorCancelled = -999)
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        
        return false
    }
}

// MARK: - Rate-Limited Logging

struct RateLimiter {
    private static var lastPrintTimes: [String: Date] = [:]
    private static let lock = NSLock()
    
    static func permit(key: String, interval: TimeInterval = 2.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        if let last = lastPrintTimes[key], now.timeIntervalSince(last) < interval {
            return false
        }
        lastPrintTimes[key] = now
        return true
    }
}

enum NetLog {
    static func profileOnce(_ message: String) {
        #if DEBUG
        if RateLimiter.permit(key: "profile", interval: 2.0) {
            print("[PROFILE] \(message)")
        }
        #endif
    }
}

#if canImport(SwiftUI)
/// No-op location usage tracker shim
extension View {
    func trackLocationUsage(_ _: String) -> some View { self }
}
#endif
