//
//  ConsentManager.swift
//  TrashPicker
//
//  Native analytics consent management
//

import Foundation
import Combine

/// Analytics consent states
enum AnalyticsConsent {
    case provided
    case denied
    case unknown
}

/// Manages analytics consent state with live updates from iOS Settings
@MainActor
final class ConsentManager: ObservableObject {
    static let shared = ConsentManager()
    
    @Published private(set) var analytics: AnalyticsConsent = .unknown
    
    private let key = "swoopy.analytics_consent"
    
    private init() {
        // Optional: Register default false if you want explicit initial Bool
        // UserDefaults.standard.register(defaults: [key: false])
        
        load()
        
        // Observe UserDefaults changes from iOS Settings on main queue
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main // Ensure main thread delivery
        ) { [weak self] _ in
            self?.load()
        }
        
        #if DEBUG
        DLog("[CONSENT] ConsentManager initialized - state: \(analytics)")
        #endif
    }
    
    /// Load consent state from UserDefaults
    func load() {
        let defaults = UserDefaults.standard
        
        // Check if key exists - if not, state is unknown
        if defaults.object(forKey: key) == nil {
            // Key absent => unknown (first launch / not set in Settings yet)
            setPublished(.unknown)
        } else {
            // Key exists as Bool: true = provided, false = denied
            setPublished(defaults.bool(forKey: key) ? .provided : .denied)
        }
    }
    
    /// Set consent to provided (called from alert)
    func setProvidedByAlert() {
        #if DEBUG
        DLog("[CONSENT] User granted consent via alert")
        #endif
        
        UserDefaults.standard.set(true, forKey: key)
        setPublished(.provided)
    }
    
    /// Set consent to denied (called from alert)
    func setDeniedByAlert() {
        #if DEBUG
        DLog("[CONSENT] User denied consent via alert")
        #endif
        
        UserDefaults.standard.set(false, forKey: key)
        setPublished(.denied)
    }
    
    /// Update published state and apply to runtime (only if changed)
    private func setPublished(_ new: AnalyticsConsent) {
        guard analytics != new else { return }
        
        #if DEBUG
        DLog("[CONSENT] State changed: \(analytics) → \(new)")
        #endif
        
        analytics = new
        ConsentRuntime.applyAnalytics(new)
    }
}
