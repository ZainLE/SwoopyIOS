import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif


@MainActor
func fetchWithRetry<T>(
    svc: SupabaseService,
    _ operation: @escaping () async throws -> T
) async throws -> T {
    func is5xx(_ ns: NSError) -> Bool { ns.domain == NSURLErrorDomain ? false : (ns.code >= 500 && ns.code < 600) }
    func isNetworkTimeout(_ ns: NSError) -> Bool { ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut }

    var attempt = 0
    let maxRetries = 2 // total attempts = 1 + 2
    var lastError: Error?

    while attempt <= maxRetries {
        do {
            return try await operation()
        } catch {
            // Cancellations and our TimeoutError: do not retry
            if error.isCancellationLike {
                DLog("[FETCH] skip retry (reason=cancellation)")
                throw error
            }

            lastError = error
            let ns = error as NSError
            let msg = ns.localizedDescription.lowercased()

            // 401 Unauthorized
            if msg.contains("401") || msg.contains("unauthorized") {
                do {
                    try await svc.refreshSessionIfNeeded()
                    return try await operation()
                } catch {
                    await svc.signOut() // no-flash sign-out
                    Metrics.errorType("401_sessionExpired")
                    throw AuthError.sessionExpired
                }
            }

            // 403 Forbidden (RLS)
            if msg.contains("403") || msg.contains("forbidden") {
                BootCoordinator.shared.showBanner("You don't have access to this action.")
                Metrics.errorType("403_forbidden")
                throw error
            }

            if isNetworkTimeout(ns) || is5xx(ns) {
                if attempt < maxRetries {
                    let base = 150 * Int(pow(2.0, Double(attempt)))
                    let jitter = Int.random(in: 0...150)
                    let delayMs = base + jitter
                    DLog("[FETCH] retry attempt \(attempt + 1)/\(maxRetries) after \(delayMs)ms")
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    attempt += 1
                    continue
                } else {
                    BootCoordinator.shared.showBanner("Network is slow. Showing cached content.")
                    Metrics.errorType(isNetworkTimeout(ns) ? "network_timeout" : "5xx")
                    throw error
                }
            }

            // Other errors: no retries
            Metrics.errorType("other")
            throw error
        }
    }
    throw lastError ?? AuthError.sessionExpired
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
    /// Returns true if this error represents a task cancellation, timeout, or network cancellation
    var isCancellationLike: Bool {
        // Swift Concurrency cancellation
        if self is CancellationError {
            return true
        }
        
        // Our TimeoutError (from withTimeout)
        if self is TimeoutError {
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
        if RateLimiter.permit(key: "profile", interval: 2.0) {
            DLog("[PROFILE] \(message)")
        }
    }
}

#if canImport(SwiftUI)
/// No-op location usage tracker shim
extension View {
    func trackLocationUsage(_ _: String) -> some View { self }
}
#endif
