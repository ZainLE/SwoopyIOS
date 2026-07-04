//
//  AppleNameCapture.swift
//  TrashPicker
//
//  Apple returns the user's name exactly once, client-side, in
//  credential.fullName on the FIRST authorization — if it isn't persisted at
//  that moment it is lost forever, and the user shows up as "Someone" on the
//  leaderboard and everywhere else. So: stash the name in UserDefaults the
//  instant the credential arrives (before any network work), PATCH it to the
//  profile as soon as a session exists, and keep retrying on later launches
//  until a flush succeeds.
//

import Foundation

enum AppleNameCapture {
    private static let givenKey = "appleSignIn.pendingGivenName"
    private static let familyKey = "appleSignIn.pendingFamilyName"

    static var hasPending: Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: givenKey) != nil
            || defaults.string(forKey: familyKey) != nil
    }

    /// Called from the Apple credential callback, before the Supabase token
    /// exchange — a failed sign-in must not lose the one-shot name.
    static func stash(_ name: PersonNameComponents?) {
        guard let name else { return }
        let given = normalized(name.givenName)
        let family = normalized(name.familyName)
        guard given != nil || family != nil else { return }

        let defaults = UserDefaults.standard
        if let given {
            defaults.set(given, forKey: givenKey)
        } else {
            defaults.removeObject(forKey: givenKey)
        }
        if let family {
            defaults.set(family, forKey: familyKey)
        } else {
            defaults.removeObject(forKey: familyKey)
        }
        DLog("[APPLE NAME] stashed name from credential (given=\(given != nil) family=\(family != nil))")
    }

    /// PATCH the stashed name to the caller's profile via the same
    /// `/me/profile` path the profile-edit screen uses. No-op without a stash.
    /// Keeps the stash on failure so the next launch retries; discards it if
    /// the profile already carries a first name (e.g. the user edited their
    /// name in the meantime — never clobber that).
    static func flushIfPending(api: ApiService) async {
        let defaults = UserDefaults.standard
        let given = defaults.string(forKey: givenKey)
        let family = defaults.string(forKey: familyKey)
        guard given != nil || family != nil else { return }

        if let existing = (try? await api.getProfile())?.firstName,
           existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            DLog("[APPLE NAME] profile already has a first name — dropping stash")
            clear()
            return
        }

        // Guarantee first_name gets a value: display surfaces (leaderboard,
        // callouts) key off first_name, so promote a family-only name into it.
        let patch = ProfilePatch(
            firstName: given ?? family,
            lastName: given != nil ? family : nil,
            phone: nil,
            city: nil,
            avatarUrl: nil
        )

        do {
            _ = try await api.updateProfile(patch)
            DLog("[APPLE NAME] pushed Apple-provided name to profile")
            clear()
        } catch {
            DLog("[APPLE NAME] flush failed, keeping stash for retry: \(error.localizedDescription)")
        }
    }

    private static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: givenKey)
        defaults.removeObject(forKey: familyKey)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else { return nil }
        return String(trimmed.prefix(50))
    }
}
