import Foundation
import SwiftUI
import CoreLocation
import UIKit
import Supabase
import AuthenticationServices
import CryptoKit

// MARK: - Auth Phase

enum AuthPhase {
    case checking
    case signedOut
    case signedIn
}

// MARK: - SupabaseService

@MainActor
final class SupabaseService: NSObject, ObservableObject {
    static let shared = SupabaseService()

    // Published state
    @Published var feed: [TrashDTO] = []
    @Published var myUploads: [TrashDTO] = []
    @Published var myReservations: [TrashDTO] = []
    @Published var pending: [TrashDTO] = []

    // Auth state
    @Published private(set) var phase: AuthPhase = .checking
    @Published private(set) var userId: UUID?
    @Published private(set) var session: Session?
    @Published private(set) var isAuthenticated: Bool = false
    @Published var didCheckSession = false
    
    // User profile computed properties
    var displayName: String {
        session?.user.userMetadata["full_name"]?.description
        ?? session?.user.userMetadata["name"]?.description
        ?? "Your Name"
    }
    
    var userEmail: String {
        session?.user.email ?? "No email"
    }
    
    var memberSince: Date? {
        session?.user.createdAt
    }
    
    var accountAge: String {
        guard let createdAt = memberSince else { return "Unknown" }
        let days = Calendar.current.dateComponents([.day], from: createdAt, to: Date()).day ?? 0
        
        if days < 30 {
            return "\(days) days"
        } else {
            let months = days / 30
            return "\(months) months"
        }
    }


    // Supabase client with OAuth callback configuration
    private static let callbackURL = URL(string: "swoopy://auth/callback")!
    
    let client: SupabaseClient = {
        SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey,
            options: .init(
                auth: .init(
                    redirectToURL: SupabaseService.callbackURL, flowType: .pkce
                )
            )
        )
    }()
    
    // MARK: - Helper Methods for Upload
    
    /// Get current access token or nil if not authenticated
    func currentAccessTokenOrNil() -> String? {
        return session?.accessToken
    }
    
    /// Refresh the current session if needed
    func refreshSessionIfNeeded() async throws {
        let refreshedSession = try await client.auth.refreshSession()
        applyAuthSession(refreshedSession)
    }

    private override init() {
        super.init()
        let hasTokens = KeychainStore.loadSession() != nil
        self.phase = hasTokens ? .checking : .signedOut   // ⬅️ key line: NO splash on first run
        Task { [weak self] in
            await self?.restoreSessionIfPossible()          // only does work if tokens exist
            await MainActor.run {
                self?.didCheckSession = true
            }
        }
    }

    // MARK: - Public Auth API

    func ensureSession() async {
        // Only check if we're still in checking phase
        guard phase == .checking else { return }
        let s = try? await client.auth.session
        applyAuthSession(s)
    }

    func refreshAuthState() async {
        let s = try? await client.auth.session
        applyAuthSession(s)
    }

    /// Handle oauth deep link (call from App.onOpenURL).
    @MainActor
    func handleOAuthRedirect(_ url: URL) async {
        do {
            let s = try await client.auth.session(from: url)
            applyAuthSession(s)
        } catch {
            #if DEBUG
            print("OAuth redirect handling failed:", error.localizedDescription)
            #endif
        }
    }

    /// Google OAuth (PKCE). Make sure `swoopy://auth/callback` is in Supabase Redirect URLs.
    @MainActor
    func signInWithGoogle() async throws {
        try await client.auth.signInWithOAuth(
            provider: .google
        )
        let s = try? await client.auth.session
        applyAuthSession(s)
    }

    /// Native Apple Sign-In (no Apple client secret needed on iOS).K
    func signInWithApple(on window: UIWindow?) async throws {
        let nonce = Self.randomNonceString()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let cred = try await Self.performAppleSignIn(request: request, on: window)

        guard let tokenData = cred.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw SimpleError(message: "No Apple identity token")
        }

        let s = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
        applyAuthSession(s)
        phase = .signedIn
    }

    func signInWithEmailMagicLink(_ email: String) async throws {
        try await client.auth.signInWithOTP(email: email)
    }

    // MARK: - Email/Password

    /// Create account with email/password.
    /// If email confirmations are OFF in Supabase Auth settings, this returns a session immediately.
    /// If confirmations are ON, no session is returned; you can still call signInEmailPassword after confirmation.
    @MainActor
    func signUpEmailPassword(email: String, password: String) async throws {
        _ = try await client.auth.signUp(email: email, password: password)
        let s = try? await client.auth.session
        applyAuthSession(s)
    }

    /// Sign in an existing user with email/password.
    @MainActor
    func signInEmailPassword(email: String, password: String) async throws {
        let s = try await client.auth.signIn(email: email, password: password)
        applyAuthSession(s)
    }

    func signOut() async {
        do { try await client.auth.signOut() } catch {
            #if DEBUG
            print("signOut error:", error.localizedDescription)
            #endif
        }
        KeychainStore.clearSession()
        applyAuthSession(nil)
        phase = .signedOut
    }
    
    // MARK: - Profile Management
    
    /// Update user profile information
    @MainActor
    func updateProfile(firstName: String?, lastName: String?, phone: String?) async throws {
        guard session != nil else {
            throw SimpleError(message: "No active session")
        }
        
        var updates: [String: Any] = [:]
        
        // Construct full name from first and last name
        let fullName = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        if !fullName.isEmpty {
            updates["full_name"] = fullName
            updates["name"] = fullName // Some providers use 'name' instead
        }
        
        if let phone = phone?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
            updates["phone"] = phone
        }
        
        // Update user metadata
        let refreshedSession = try await client.auth.refreshSession()
        applyAuthSession(refreshedSession)  // ✅ Session
    }
    
    /// Delete user account and all associated data
    @MainActor
    func deleteAccount() async throws {
        guard session != nil else {
            throw SimpleError(message: "No active session")
        }
        
        // Delete user account (this will cascade delete associated data)
        try await client.rpc("delete_user_account").execute()
        
        // Sign out locally
        await signOut()
    }
    
    @MainActor
    func applyAuthForGate(_ s: Session?) { applyAuthSession(s) }

    // MARK: - Feed

    func fetchFeed(
        near: CLLocationCoordinate2D,
        radiusKM: Double = 50,
        category: String? = nil,
        condition: String? = nil
    ) async {
        do {
            let rows = try await ItemsService.shared.getFeed(
                lat: near.latitude,
                lon: near.longitude,
                radiusKm: radiusKM,
                category: category,
                condition: condition
            )
            self.feed = rows.map { r in
                TrashDTO(
                    id: r.id,
                    title: r.title,
                    description: r.description,
                    category: r.category,
                    condition: r.condition,
                    mode: r.mode,
                    city: (String?).none,
                    lat: r.lat,
                    lon: r.lon,
                    approxLat: r.approx_lat,
                    approxLon: r.approx_lon,
                    photoURLs: r.photo_urls.compactMap(URL.init(string:)),
                    createdAt: r.created_at,
                    expiresAt: r.expires_at,
                    status: r.status,
                    reservedUntil: r.reserved_until,
                    reservedBy: r.reserved_by,
                    uploader: r.uploader,
                    pickedUpAt: r.picked_up_at
                )
            }
        } catch {
            #if DEBUG
            print("fetchFeed:", error.localizedDescription)
            #endif
        }
    }

    // MARK: - My stuff

    func fetchMyStuff() async {
        // TODO: Re-enable real implementation once DBItem/TrashDTO models and ItemsService are available.
        // Temporary stub to avoid build errors and warnings about missing types and unnecessary try/await.
        guard userId != nil else {
            self.myUploads = []
            self.myReservations = []
            self.pending = []
            return
        }
        self.myUploads = []
        self.myReservations = []
        self.pending = []
    }

    // MARK: - Create post

    func createItem(
        images: [UIImage],
        title: String,
        description: String?,
        category: String,
        condition: String,
        mode: String,                       // "street" | "home"
        coordinate: CLLocationCoordinate2D, // exact user point
        homeGrid: Double = 0.01
    ) async throws {
        guard let uid = userId else { throw SimpleError(message: "No user/session") }

        let photoURLs = try await ImageStorage.uploadJPEGs(client: client, images: images, uploader: uid)
        guard !photoURLs.isEmpty else { throw SimpleError(message: "Image upload failed") }

        var lat = coordinate.latitude, lon = coordinate.longitude
        var approxLat: Double? = nil, approxLon: Double? = nil
        if mode == "home" {
            approxLat = (lat / homeGrid).rounded() * homeGrid
            approxLon = (lon / homeGrid).rounded() * homeGrid
            lat = .nan; lon = .nan
        }

        struct Insert: Encodable {
            let id: UUID
            let uploader: UUID
            let title: String
            let description: String?
            let category: String
            let condition: String
            let mode: String
            let lat: Double?
            let lon: Double?
            let approx_lat: Double?
            let approx_lon: Double?
            let photo_urls: [String]
            let created_at: String
            let expires_at: String
            let status: String
        }

        let now = Date()
        let payload = Insert(
            id: UUID(),
            uploader: uid,
            title: title,
            description: description?.prefix(100).description,
            category: category,
            condition: condition,
            mode: mode,
            lat: mode == "street" ? lat : nil,
            lon: mode == "street" ? lon : nil,
            approx_lat: mode == "home" ? approxLat : nil,
            approx_lon: mode == "home" ? approxLon : nil,
            photo_urls: photoURLs,
            created_at: ISOTime.isoString(now),
            expires_at: ISOTime.isoString(now.addingTimeInterval(24*3600)),
            status: "available"
        )

        _ = try await client
            .from(SupabaseConfig.postsTable)
            .insert(payload)
            .execute()
    }

    // MARK: - Reservation life-cycle

    func reserve(_ item: TrashDTO, hours: Int = 6) async throws {
        try await ItemsService.shared.reservePost(itemId: item.id, hours: hours)
    }

    func approve(reservationId: UUID, hours: Int = 6) async throws {
        struct Params: Encodable { let p_reservation_id: UUID; let p_hours: Int }
        let params = Params(p_reservation_id: reservationId, p_hours: hours)
        _ = try await client.rpc("approve_reservation", params: params).execute()
    }

    func cancelReservation(_ item: TrashDTO) async {
        struct Params: Encodable { let p_post_id: UUID }
        do { _ = try await client.rpc("clear_reservation", params: Params(p_post_id: item.id)).execute() }
        catch { 
            #if DEBUG
            print("cancelReservation:", error.localizedDescription) 
            #endif
        }
    }

    func confirmPickup(_ item: TrashDTO) async {
        struct Params: Encodable { let p_post_id: UUID }
        do { _ = try await client.rpc("mark_picked_up", params: Params(p_post_id: item.id)).execute() }
        catch { 
            #if DEBUG
            print("confirmPickup:", error.localizedDescription) 
            #endif
        }
    }
}

// MARK: - Apple sign-in bridge (single source of truth)

@MainActor
private extension SupabaseService {

    /// Strong reference so the coordinator isn't deallocated before callbacks.
    private static var appleCoordinatorRetain: AppleCoordinator?

    static func performAppleSignIn(
        request: ASAuthorizationAppleIDRequest,
        on window: UIWindow?
    ) async throws -> ASAuthorizationAppleIDCredential {

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
            let controller = ASAuthorizationController(authorizationRequests: [request])
            let coordinator = AppleCoordinator(continuation: cont)
            coordinator.window = window
            coordinator.controller = controller

            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator

            // Retain until one of the delegate callbacks fires.
            Self.appleCoordinatorRetain = coordinator

            controller.performRequests()
        }
    }

    /// Coordinator that resumes the continuation exactly once.
    final class AppleCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        var window: UIWindow?
        var controller: ASAuthorizationController?

        private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

        init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
            self.continuation = continuation
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            window
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
            ?? UIWindow()
        }

        func authorizationController(controller: ASAuthorizationController,
                                     didCompleteWithAuthorization authorization: ASAuthorization) {
            if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
                continuation?.resume(returning: cred)
            } else {
                continuation?.resume(throwing: SimpleError(message: "Invalid Apple credential"))
            }
            cleanup()
        }

        func authorizationController(controller: ASAuthorizationController,
                                     didCompleteWithError error: Error) {
            continuation?.resume(throwing: error) // includes user-cancel
            cleanup()
        }

        private func cleanup() {
            continuation = nil
            controller = nil
            SupabaseService.appleCoordinatorRetain = nil
        }
    }
}

// MARK: - Internal auth plumbing

private extension SupabaseService {
    func applyAuthSession(_ session: Session?) {
        self.session = session
        if let s = session {
            self.userId = s.user.id
            self.isAuthenticated = !Self.isAnonymousUser(s.user)
            KeychainStore.saveSession(accessToken: s.accessToken, refreshToken: s.refreshToken)
            if phase != .signedIn { phase = .signedIn }
        } else {
            self.userId = nil
            self.isAuthenticated = false
            KeychainStore.clearSession()
            if phase != .signedOut { phase = .signedOut }
        }
    }

    func restoreSessionIfPossible() async {
        guard let creds = KeychainStore.loadSession() else {
            // If no tokens: applyAuthSession(nil) and phase = .signedOut; return immediately
            applyAuthSession(nil)
            didCheckSession = true
            return
        }
        // If tokens exist: try client.auth.setSession(...)
        do {
            let s = try await client.auth.setSession(
                accessToken: creds.accessToken,
                refreshToken: creds.refreshToken
            )
            // On success: applyAuthSession(s) and phase = .signedIn
            applyAuthSession(s)
            didCheckSession = true
        } catch {
            // On failure: clear Keychain → applyAuthSession(nil) and phase = .signedOut
            KeychainStore.clearSession()
            applyAuthSession(nil)
            didCheckSession = true
        }
    }

    static func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = "", remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess { fatalError("Unable to generate nonce.") }
            bytes.forEach { b in if remaining > 0, b < charset.count { result.append(charset[Int(b)]); remaining -= 1 } }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isAnonymousUser(_ user: User) -> Bool {
        let provider = user.appMetadata["provider"]?.description.lowercased() ?? ""
        return provider == "anonymous" || provider == "anon"
    }
}

// MARK: - Keychain minimal session storage

private enum KeychainStore {
    private static let service = "com.zainlatif.Swoopy.supabase"
    private static let accountAccess = "accessToken"
    private static let accountRefresh = "refreshToken"

    struct Credentials { let accessToken: String; let refreshToken: String }

    static func saveSession(accessToken: String, refreshToken: String) {
        save(key: accountAccess, value: accessToken)
        save(key: accountRefresh, value: refreshToken)
    }
    static func loadSession() -> Credentials? {
        guard let access = load(key: accountAccess), let refresh = load(key: accountRefresh) else { return nil }
        return .init(accessToken: access, refreshToken: refresh)
    }
    static func clearSession() { delete(key: accountAccess); delete(key: accountRefresh) }

    private static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
    private static func load(key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func delete(key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Time helper & error

private enum ISOTime {
    private static let f: ISO8601DateFormatter = {
        let x = ISO8601DateFormatter()
        x.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return x
    }()
    static func isoString(_ d: Date) -> String { f.string(from: d) }
}

struct SimpleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

