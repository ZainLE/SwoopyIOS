import Foundation

enum TimeoutError: Error, LocalizedError {
    case timedOut
    
    var errorDescription: String? {
        return "Request timed out"
    }
}

/// Runs an async operation with a specified timeout and truly cancels underlying work.
/// Uses structured concurrency to ensure the operation task is cancelled when timeout fires.
/// - Parameters:
///   - seconds: timeout duration in seconds
///   - operation: async work to run (must respect Task.isCancelled)
/// - Returns: result of the operation if it finishes first
/// - Throws: TimeoutError.timedOut if the timeout fires first, or the operation's error
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    let start = Date()
    let reqId = UUID().uuidString.prefix(8)
    
    return try await withThrowingTaskGroup(of: Result<T, Error>.self) { group in
        // Spawn the actual operation in a child task
        group.addTask {
            do {
                let result = try await operation()
                return .success(result)
            } catch {
                return .failure(error)
            }
        }
        
        // Spawn timeout watchdog
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .failure(TimeoutError.timedOut)
        }
        
        // Wait for first result
        guard let firstResult = try await group.next() else {
            throw TimeoutError.timedOut
        }
        
        // Cancel all remaining tasks immediately
        group.cancelAll()
        
        let elapsed = Date().timeIntervalSince(start)
        
        switch firstResult {
        case .success(let value):
            #if DEBUG
            DLog("[PERF] withTimeout: succeeded (reqId=\(reqId), seconds=\(seconds), elapsed=\(String(format: "%.3f", elapsed)))")
            #endif
            return value
            
        case .failure(let error):
            if case TimeoutError.timedOut = error {
                #if DEBUG
                DLog("[NET] timeout → cancel underlying (reqId=\(reqId), seconds=\(seconds), elapsed=\(String(format: "%.3f", elapsed)))")
                #endif
            } else if error.isCancellationLike {
                #if DEBUG
                DLog("[NET] cancelled (reqId=\(reqId), elapsed=\(String(format: "%.3f", elapsed)))")
                #endif
            } else {
                #if DEBUG
                DLog("[PERF] withTimeout: failed (reqId=\(reqId), seconds=\(seconds), elapsed=\(String(format: "%.3f", elapsed)), error=\(error.localizedDescription))")
                #endif
            }
            throw error
        }
    }
}
