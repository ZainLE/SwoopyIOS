//
//  AppConfiguration.swift
//  TrashPicker
//
//  App configuration and launch argument handling
//

import Foundation

enum AppConfiguration {
    /// Check if app is running with mock API
    static var useMockAPI: Bool {
        return ProcessInfo.processInfo.arguments.contains("-USE_MOCK_API") &&
               ProcessInfo.processInfo.arguments.contains("YES")
    }
    
    /// Check if app is running in UI test mode
    static var isUITesting: Bool {
        return ProcessInfo.processInfo.arguments.contains("-UI_TESTING")
    }
    
    /// Get launch argument value
    static func launchArgument(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: key), index + 1 < args.count {
            return args[index + 1]
        }
        return nil
    }
}
