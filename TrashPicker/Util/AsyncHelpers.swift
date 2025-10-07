import Foundation

enum TimeoutError: Error { case timedOut }

/// Runs an async operation with a specified timeout and logs outcome.
/// - Parameters:
///   - seconds: timeout duration in seconds
///   - operation: async work to run
/// - Returns: result of the operation if it finishes first
/// - Throws: TimeoutError.timedOut if the timeout fires first, or the operation's error
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    let start = Date()
    do {
        let result = try await withThrowingTaskGroup(of: T.self) { group in
            // Actual operation
            group.addTask { try await operation() }

            // Timeout hedge
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }

            // First to finish wins
            guard let value = try await group.next() else { throw TimeoutError.timedOut }
            group.cancelAll()
            return value
        }
        let elapsed = Date().timeIntervalSince(start)
        print("[PERF] withTimeout fired: succeeded (seconds=\(seconds), elapsed=\(String(format: "%.3f", elapsed)))")
        return result
    } catch {
        let elapsed = Date().timeIntervalSince(start)
        if case TimeoutError.timedOut = error {
            print("[PERF] withTimeout fired: timeout (seconds=\(seconds), elapsed=\(String(format: "%.3f", elapsed)))")
        } else {
            print("[PERF] withTimeout fired: failed (seconds=\(seconds), elapsed=\(String(format: "%.3f", elapsed)), error=\(error.localizedDescription))")
        }
        throw error
    }
}
