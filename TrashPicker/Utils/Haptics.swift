import UIKit
import CoreHaptics

// MARK: - Haptic Events

enum HapticEvent {
    case tabSelect          // switching Feed/Reservations/Profile
    case tabReselect        // tapping an already-selected tab
    case primaryAction      // the big +
    case success, warning, error
}

// MARK: - Lightweight Haptics Helper

enum Haptics {
    // MARK: Lightweight (recommended default)
    static func play(_ event: HapticEvent) {
        DispatchQueue.main.async {
            switch event {
            case .tabSelect:
                UISelectionFeedbackGenerator().selectionChanged()
                
            case .tabReselect:
                let g = UIImpactFeedbackGenerator(style: .soft)
                g.impactOccurred()
                
            case .primaryAction:
                let g = UIImpactFeedbackGenerator(style: .heavy)
                g.impactOccurred()
                
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .warning:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .error:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
    
    // MARK: Optional: pre-warm to remove first-tap latency
    static func prewarm() {
        DispatchQueue.main.async {
            // "prepare()" hints iOS to spin up the Taptic engine once.
            UIImpactFeedbackGenerator(style: .soft).prepare()
            UIImpactFeedbackGenerator(style: .medium).prepare()
            UIImpactFeedbackGenerator(style: .heavy).prepare()
            UISelectionFeedbackGenerator().prepare()
            UINotificationFeedbackGenerator().prepare()
        }
    }
}

// MARK: - Core Haptics (Premium Patterns)

final class CHaptic {
    static let shared = CHaptic()
    private var engine: CHHapticEngine?
    
    private init() {}
    
    func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
        } catch {
            #if DEBUG
            print("[Haptics] Failed to start Core Haptics engine: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Premium primary action haptic (camera "+" button)
    /// Intensity: 1.0, Sharpness: 0.7 - confident and slightly snappy
    func primaryAction() {
        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Fallback to UIKit heavy impact
            Haptics.play(.primaryAction)
            return
        }
        
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                ],
                relativeTime: 0
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: 0)
        } catch {
            #if DEBUG
            print("[Haptics] Failed to play primary action: \(error.localizedDescription)")
            #endif
            // Fallback
            Haptics.play(.primaryAction)
        }
    }
    
    /// Secondary action haptic
    /// Intensity: 0.7, Sharpness: 0.4 - softer, less prominent
    func secondaryAction() {
        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
                ],
                relativeTime: 0
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: 0)
        } catch {
            #if DEBUG
            print("[Haptics] Failed to play secondary action: \(error.localizedDescription)")
            #endif
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
    
    /// Gentle tick (selection-like)
    /// Intensity: 0.45, Sharpness: 0.5 - subtle and crisp
    func gentleTick() {
        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: 0)
        } catch {
            #if DEBUG
            print("[Haptics] Failed to play gentle tick: \(error.localizedDescription)")
            #endif
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
