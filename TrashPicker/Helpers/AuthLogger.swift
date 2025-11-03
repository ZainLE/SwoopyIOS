import Foundation
import OSLog
import UIKit

/// Structured logging for auth flows using OSLog.
/// NEVER logs secrets (tokens, passwords, idTokens).
/// For IDs/keys: shows last 6 chars max.
enum AuthLogger {
    // MARK: - OSLog Categories
    
    static let email = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "Auth.Email")
    static let apple = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "Auth.Apple")
    static let callback = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "Auth.Callback")
    static let general = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "Auth.General")
    
    // MARK: - App/Device/Config Info (logged once at first auth attempt)
    
    private static var hasLoggedEnvironment = false
    
    static func logEnvironmentOnce() {
        guard !hasLoggedEnvironment else { return }
        hasLoggedEnvironment = true
        
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let device = UIDevice.current.model
        let iosVersion = UIDevice.current.systemVersion
        let locale = Locale.current.identifier
        
        // Supabase config (NON-secret)
        let supabaseURL = SupabaseConfig.url.absoluteString
        let projectRef = extractProjectRef(from: supabaseURL)
        let anonKeySuffix = sanitizeKey(SupabaseConfig.anonKey)
        
        // Redirect scheme from Info.plist
        let expectedScheme = extractRedirectScheme()
        
        general.info("""
        ━━━ AUTH ENVIRONMENT ━━━
        App: \(bundleId, privacy: .public)
        Version: \(version, privacy: .public) (\(build, privacy: .public))
        Device: \(device, privacy: .public) iOS \(iosVersion, privacy: .public)
        Locale: \(locale, privacy: .public)
        
        Supabase URL: \(supabaseURL, privacy: .public)
        Project Ref: \(projectRef, privacy: .public)
        Anon Key (last 6): ...\(anonKeySuffix, privacy: .public)
        
        Expected Redirect Scheme: \(expectedScheme, privacy: .public)
        Expected Callback URL: swoopy://auth/callback
        ━━━━━━━━━━━━━━━━━━━━━━
        """)
    }
    
    // MARK: - Sanitization Helpers
    
    /// Shows only last 6 characters of a key/token
    static func sanitizeKey(_ key: String) -> String {
        guard key.count > 6 else { return "***" }
        return String(key.suffix(6))
    }
    
    /// Extract project reference from Supabase URL
    static func extractProjectRef(from url: String) -> String {
        // Example: https://api.swoopy.eu -> "swoopy.eu"
        // Or https://abcdefgh.supabase.co -> "abcdefgh"
        guard let host = URL(string: url)?.host else { return "unknown" }
        return host
    }
    
    /// Extract redirect scheme from Info.plist
    static func extractRedirectScheme() -> String {
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return "not-configured"
        }
        
        for urlType in urlTypes {
            if let schemes = urlType["CFBundleURLSchemes"] as? [String], let first = schemes.first {
                return first
            }
        }
        
        return "not-configured"
    }
    
    // MARK: - Auth Flow Logging
    
    static func emailSignInStart(email: String, mode: String) {
        logEnvironmentOnce()
        let sanitized = sanitizeEmail(email)
        self.email.info("📧 Email \(mode, privacy: .public) START | email: \(sanitized, privacy: .public)")
    }
    
    static func emailSignInSuccess(email: String, mode: String, userId: String?) {
        let sanitized = sanitizeEmail(email)
        let userIdSuffix = userId.map { sanitizeKey($0) } ?? "nil"
        self.email.info("✅ Email \(mode, privacy: .public) SUCCESS | email: \(sanitized, privacy: .public) | userId: ...\(userIdSuffix, privacy: .public)")
    }
    
    static func emailSignInFailure(email: String, mode: String, error: Error) {
        let sanitized = sanitizeEmail(email)
        let nsError = error as NSError
        let debugDescription = String(describing: error)
        let combined = nsError.localizedDescription == debugDescription
            ? nsError.localizedDescription
            : "\(nsError.localizedDescription) | \(debugDescription)"
        self.email.error("❌ Email \(mode, privacy: .public) FAILED | email: \(sanitized, privacy: .public) | domain: \(nsError.domain, privacy: .public) | code: \(nsError.code, privacy: .public) | error: \(combined, privacy: .public)")
    }
    
    static func appleSignInStart() {
        logEnvironmentOnce()
        apple.info("🍎 Apple Sign-In START")
    }
    
    static func appleSignInRequestCreated(nonce: String) {
        let nonceSuffix = sanitizeKey(nonce)
        apple.info("🍎 Apple request created | nonce: ...\(nonceSuffix, privacy: .public)")
    }
    
    static func appleSignInCredentialReceived(hasToken: Bool, hasNonce: Bool) {
        apple.info("🍎 Apple credential received | hasToken: \(hasToken, privacy: .public) | hasNonce: \(hasNonce, privacy: .public)")
    }
    
    static func appleSignInSupabaseExchange() {
        apple.info("🍎 Exchanging Apple credential with Supabase...")
    }
    
    static func appleSignInSuccess(userId: String?) {
        let userIdSuffix = userId.map { sanitizeKey($0) } ?? "nil"
        apple.info("✅ Apple Sign-In SUCCESS | userId: ...\(userIdSuffix, privacy: .public)")
    }
    
    static func appleSignInFailure(error: Error) {
        let nsError = error as NSError
        let debugDescription = String(describing: error)
        let combined = nsError.localizedDescription == debugDescription
            ? nsError.localizedDescription
            : "\(nsError.localizedDescription) | \(debugDescription)"
        apple.error("❌ Apple Sign-In FAILED | domain: \(nsError.domain, privacy: .public) | code: \(nsError.code, privacy: .public) | error: \(combined, privacy: .public)")
    }
    
    static func oauthCallbackReceived(url: URL) {
        logEnvironmentOnce()
        let scheme = url.scheme ?? "no-scheme"
        let host = url.host ?? "no-host"
        let path = url.path
        callback.info("🔗 OAuth callback received | scheme: \(scheme, privacy: .public) | host: \(host, privacy: .public) | path: \(path, privacy: .public)")
    }
    
    static func oauthCallbackSuccess(userId: String?) {
        let userIdSuffix = userId.map { sanitizeKey($0) } ?? "nil"
        callback.info("✅ OAuth callback SUCCESS | userId: ...\(userIdSuffix, privacy: .public)")
    }
    
    static func oauthCallbackFailure(error: Error) {
        callback.error("❌ OAuth callback FAILED | error: \(error.localizedDescription, privacy: .public)")
    }
    
    static func sessionApplied(userId: String?, accessTokenPresent: Bool) {
        let userIdSuffix = userId.map { sanitizeKey($0) } ?? "nil"
        general.info("🔐 Session applied | userId: ...\(userIdSuffix, privacy: .public) | hasAccessToken: \(accessTokenPresent, privacy: .public)")
    }
    
    static func signOutTriggered() {
        general.info("🚪 Sign out triggered")
    }
    
    // MARK: - Email Sanitization
    
    private static func sanitizeEmail(_ email: String) -> String {
        // Show first 2 chars + @domain
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@") else {
            return "***@unknown"
        }
        
        let prefix = String(trimmed.prefix(2))
        let domain = String(trimmed[atIndex...])
        return "\(prefix)***\(domain)"
    }
}
