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
        let msg = error.localizedDescription.lowercased()
        if msg.contains("401") || msg.contains("unauthorized") {
            do {
                try await svc.refreshSessionIfNeeded()
                return try await operation()  // retry once
            } catch {
                // If still unauthorized, sign out
                await svc.signOut()
                throw error
            }
        }
        throw error
    }
}

#if canImport(SwiftUI)
/// No-op location usage tracker shim
extension View {
    func trackLocationUsage(_ _: String) -> some View { self }
}
#endif
