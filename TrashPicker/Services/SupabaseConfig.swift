import Foundation

/// Central app configuration for Supabase + storage tables.
/// Reads keys from Info.plist (never hardcode secrets here).
enum SupabaseConfig {
    // Storage / tables
    static let photosBucket = "post-content"
    static let postsTable   = "items"
    
    // API base URL for backend calls
    static let apiBaseURL = "https://swoopy.eu/custom-api"
    
    // Read from Info.plist (DO NOT hardcode here in source)
    static let url: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseUrl") as? String,
            let url = URL(string: raw),
            !raw.isEmpty
        else { fatalError("Missing or invalid SupabaseUrl in Info.plist") }
        return url
    }()
    
    static let anonKey: String = {
        guard
            let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !key.isEmpty
        else { fatalError("Missing SupabaseAnonKey in Info.plist") }
        return key
    }()
    
}
