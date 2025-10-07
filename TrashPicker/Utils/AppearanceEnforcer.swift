//
//  AppearanceEnforcer.swift
//  TrashPicker
//
//  Global appearance enforcement for Light Mode
//

import UIKit

enum AppearanceEnforcer {
    /// Force light appearance across all active windows
    /// Call once on app launch to ensure consistent Light Mode
    static func forceLight() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = .light
            }
        }
    }
}
