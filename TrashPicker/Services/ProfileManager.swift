import Foundation
import SwiftUI

/// Single source of truth for user profile data
/// Manages profile state and provides reactive updates across the app
@MainActor
final class ProfileManager: ObservableObject {
    @Published var profile: ProfileDTO?
    @Published var isLoading = false
    @Published var lastError: Error?
    
    private let apiService: ApiService
    private var loadTask: Task<Void, Never>?
    
    init(apiService: ApiService) {
        self.apiService = apiService
        
        // Listen for profile update notifications
        NotificationCenter.default.addObserver(
            forName: .profileDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshProfile()
            }
        }
    }
    
    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Load profile from server
    func loadProfile() async {
        // Cancel any existing load
        loadTask?.cancel()
        
        loadTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            
            isLoading = true
            lastError = nil
            
            do {
                let serverProfile = try await apiService.getProfile()
                
                guard !Task.isCancelled else { return }
                
                // Convert Profile to ProfileDTO for consistency
                profile = ProfileDTO(
                    id: serverProfile.id,
                    fullName: serverProfile.fullName,
                    firstName: serverProfile.firstName,
                    lastName: serverProfile.lastName,
                    phone: serverProfile.phone,
                    avatarUrl: serverProfile.avatarUrl?.absoluteString,
                    city: serverProfile.city,
                    phoneVerified: serverProfile.phoneVerified,
                    onboardingCompleted: true, // Default since we got a profile from server
                    updatedAt: nil // Profile struct doesn't have updatedAt
                )
                
                #if DEBUG
                DLog("[ProfileManager] Profile loaded: \(profile?.displayName ?? "nil")")
                #endif
                
            } catch {
                guard !Task.isCancelled else { return }
                
                lastError = error
                #if DEBUG
                DLog("[ProfileManager] Load error: \(error.localizedDescription)")
                #endif
            }
            
            isLoading = false
            loadTask = nil
        }
        
        await loadTask?.value
    }
    
    /// Refresh profile data (called when profile is updated elsewhere)
    private func refreshProfile() async {
        await loadProfile()
    }
    
    /// Computed properties for UI convenience
    var displayName: String {
        profile?.displayName ?? "Your Name"
    }
    
    var avatarUrl: String? {
        profile?.avatarUrl
    }
    
    var hasProfile: Bool {
        profile != nil
    }
}
