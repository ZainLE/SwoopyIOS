//
//  ConsentRuntime.swift
//  TrashPicker
//
//  Controls Smartlook analytics based on consent state
//

import Foundation
import SmartlookAnalytics

/// Runtime control for analytics based on consent
enum ConsentRuntime {
    
    /// Apply analytics consent state to Smartlook
    /// - Parameter state: The consent state to apply
    @MainActor
    static func applyAnalytics(_ state: AnalyticsConsent) {
        switch state {
        case .provided:
            #if DEBUG
            DLog("[ANALYTICS] ✅ Starting Smartlook - user provided consent")
            #endif
            
            // Start Smartlook (idempotent if already started)
            Smartlook.instance.start()
            
        case .denied, .unknown:
            #if DEBUG
            DLog("[ANALYTICS] ⚠️ Stopping Smartlook - consent: \(state)")
            #endif
            
            // Stop Smartlook session
            Smartlook.instance.stop()
        }
    }
}
