import Foundation
import FirebaseCrashlytics

/// Thin wrapper around Firebase Crashlytics.
/// - Breadcrumbs: call `log(_:)` at key flow steps; the last ~64KB appear in every report.
/// - Non-fatal errors: call `record(_:context:)` for caught errors that don't crash the app.
/// - Identity: call `setUserId(_:)` on sign-in/sign-out so reports are user-linkable.
enum CrashlyticsService {

    static func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    /// Records a non-fatal error with context so it appears in the Crashlytics dashboard
    /// under "Non-fatals", grouped by context + error domain/code.
    static func record(_ error: Error, context: String, extra: [String: String] = [:]) {
        let nsError = error as NSError
        var info: [String: Any] = ["context": context]
        extra.forEach { info[$0.key] = $0.value }
        let wrapped = NSError(
            domain: nsError.domain.isEmpty ? "com.trashpicker.unknown" : nsError.domain,
            code: nsError.code,
            userInfo: info.merging(nsError.userInfo) { annotated, _ in annotated }
        )
        Crashlytics.crashlytics().record(error: wrapped)
    }

    static func setUserId(_ userId: String?) {
        Crashlytics.crashlytics().setUserID(userId ?? "")
    }

    static func setString(_ value: String, forKey key: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }
}
