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
    @Published var feedIsOffline = false
    @Published var myUploads: [TrashDTO] = []
    @Published var myReservations: [TrashDTO] = []
    @Published var pending: [TrashDTO] = []
    
    private var cachedFeed: [TrashDTO] = []
    private let feedCacheStore = FeedCacheStore()

    // Auth state
    @Published private(set) var phase: AuthPhase = .checking
    @Published private(set) var userId: UUID?
    @Published private(set) var session: Session?
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var didCheckSession = false
    // Single refresh guard to avoid concurrent refresh storms
    private let refreshGate = RefreshGate()
    // Shared single-flight gate for feed/map fetches
    private let feedGate = FeedSingleFlight()
    private var feedReqCounter: Int = 0
    
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
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10 // seconds
        configuration.timeoutIntervalForResource = 20 // seconds

        return SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey,
            options: .init(
                auth: .init(
                    redirectToURL: SupabaseService.callbackURL, flowType: .pkce
                ),
                global: .init(session: URLSession(configuration: configuration))
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
        // Try to acquire the refresh gate
        let acquired = await refreshGate.begin()
        if !acquired {
            #if DEBUG
            print("[AUTH] refresh skip (guarded=true)")
            #endif
            return
        }
        #if DEBUG
        print("[AUTH] refresh start (guarded=true)")
        #endif
        defer { Task { await refreshGate.end()
            #if DEBUG
            print("[AUTH] refresh end (guarded=true)")
            #endif
        } }

        let refreshedSession = try await client.auth.refreshSession()
        await MainActor.run { [refreshedSession] in
            applyAuthSession(refreshedSession)
        }
    }

    private override init() {
        super.init()
        
        // Prefer Keychain restore to avoid auth screen flash
        // Run off-main to ensure no disk/Keychain I/O on the main actor
        Task.detached { [weak self] in
            await self?.restoreSessionIfPossible()
        }
        
        // Also kick a background verification/refresh (non-blocking)
        Task.detached { [weak self] in
            await self?.bootstrapAuth()
        }

        // Load last-known feed cache (local-only Stage 0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let cache = feedCacheStore.load() {
                self.feed = cache.items
                self.cachedFeed = cache.items
                self.feedIsOffline = false
                #if DEBUG
                let ageMs = Int(Date().timeIntervalSince(cache.savedAt) * 1000)
                print("[FEED cache] loaded count=\(cache.items.count) dataAgeMs=\(ageMs)")
                #endif
            }
        }
    }

    // MARK: - Public Auth API

    func ensureSession() async {
        // Legacy shim: route to bootstrapAuth to resolve current status
        await bootstrapAuth()
    }

    /// Runs once at launch to restore a cached session (if any).
    /// This method performs network work off the main actor, then publishes results on main actor.
    func bootstrapAuth() async {
        // Perform the actual network request OFF the main actor with aggressive timeout
        let bootStart = Date()
        let result: Result<Session, Error> = await Task.detached {
            do {
                // Race the session fetch against a hard 3-second timeout
                let s = try await withThrowingTaskGroup(of: Session.self) { group in
                    // Session fetch task
                    group.addTask {
                        try await self.client.auth.session
                    }
                    
                    // Timeout task
                    group.addTask {
                        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        throw TimeoutError.timedOut
                    }
                    
                    // First to complete wins, cancel the other
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                return .success(s)
            } catch {
                #if DEBUG
                print("Session bootstrap failed or timed out: \(error.localizedDescription)")
                #endif
                return .failure(error)
            }
        }.value

        // Now update @Published properties on the main actor
        await MainActor.run {
            switch result {
            case .success(let session):
                self.applyAuthSession(session)
            case .failure:
                self.session = nil
                self.isAuthenticated = false
                self.phase = .signedOut
            }
        }
        let ms = Int(Date().timeIntervalSince(bootStart) * 1000)
        Metrics.sessionRestoreMs(ms)
    }

    func refreshAuthState() async {
        let s = try? await client.auth.session
        await MainActor.run { [s] in
            applyAuthSession(s)
        }
    }

    /// Handle oauth deep link (call from App.onOpenURL).
    @MainActor
    func handleOAuthRedirect(_ url: URL) async {
        AuthLogger.oauthCallbackReceived(url: url)
        do {
            let s = try await client.auth.session(from: url)
            applyAuthSession(s)
            AuthLogger.oauthCallbackSuccess(userId: s.user.id.uuidString)
        } catch {
            AuthLogger.oauthCallbackFailure(error: error)
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
        AuthLogger.appleSignInStart()
        let nonce = Self.randomNonceString()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        AuthLogger.appleSignInRequestCreated(nonce: nonce)

        let cred = try await Self.performAppleSignIn(request: request, on: window)
        AuthLogger.appleSignInCredentialReceived(hasToken: cred.identityToken != nil, hasNonce: true)

        guard let tokenData = cred.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            let error = SimpleError(message: "No Apple identity token")
            AuthLogger.appleSignInFailure(error: error)
            throw error
        }

        AuthLogger.appleSignInSupabaseExchange()
        let s = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
        applyAuthSession(s)
        phase = .signedIn
        AuthLogger.appleSignInSuccess(userId: s.user.id.uuidString)
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
        AuthLogger.emailSignInStart(email: email, mode: "sign-up")
        do {
            _ = try await client.auth.signUp(email: email, password: password)
            let s = try? await client.auth.session
            applyAuthSession(s)
            if let s = s {
                AuthLogger.emailSignInSuccess(email: email, mode: "sign-up", userId: s.user.id.uuidString)
            } else {
                AuthLogger.emailSignInSuccess(email: email, mode: "sign-up", userId: nil)
            }
        } catch {
            AuthLogger.emailSignInFailure(email: email, mode: "sign-up", error: error)
            throw error
        }
    }

    /// Sign in an existing user with email/password.
    @MainActor
    func signInEmailPassword(email: String, password: String) async throws {
        AuthLogger.emailSignInStart(email: email, mode: "sign-in")
        do {
            let s = try await client.auth.signIn(email: email, password: password)
            applyAuthSession(s)
            AuthLogger.emailSignInSuccess(email: email, mode: "sign-in", userId: s.user.id.uuidString)
        } catch {
            AuthLogger.emailSignInFailure(email: email, mode: "sign-in", error: error)
            throw error
        }
    }

    /// Call this on successful login flows to store the session and mark authenticated.
    @MainActor
    func setSession(_ s: Session) {
        applyAuthSession(s)
    }

    @MainActor
    func signOut() async {
        AuthLogger.signOutTriggered()
        do { try await client.auth.signOut(scope: .local) } catch { }
        KeychainStore.clearSession()
        applyAuthSession(nil)
        // Keep didCheckSession = true so UI shows Auth immediately
        phase = .signedOut
    }
    
    // MARK: - Profile Management
    
    /// Update user profile information
    /// Tries API endpoint first, falls back to direct SDK update
    @MainActor
    func updateProfile(firstName: String?, lastName: String?, phone: String?) async throws {
        guard session != nil else {
            throw SimpleError(message: "No active session")
        }
        
        // Build patch object
        let patch = ProfilePatch(
            firstName: firstName?.trimmingCharacters(in: .whitespacesAndNewlines),
            lastName: lastName?.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: phone?.trimmingCharacters(in: .whitespacesAndNewlines),
            city: nil,
            avatarUrl: nil
        )
        
        // Try API endpoint first
        let api = ApiService(supabaseService: self)
        do {
            let updatedProfile = try await api.updateProfile(patch)
            
            #if DEBUG
            print("[PROFILE] Updated via API: \(updatedProfile.firstName ?? "") \(updatedProfile.lastName ?? "")")
            #endif
            
            // Update session metadata to reflect changes
            try await updateSessionMetadata(firstName: firstName, lastName: lastName, phone: phone)
            
        } catch ApiServiceError.notFound {
            // API endpoint doesn't exist, fall back to SDK
            #if DEBUG
            print("[PROFILE] API endpoint not found, using SDK fallback")
            #endif
            try await updateProfileDirect(patch)
        } catch {
            // Other errors bubble up
            throw error
        }
    }
    
    /// Direct SDK update to profiles table (fallback)
    private func updateProfileDirect(_ patch: ProfilePatch) async throws {
        guard let uid = session?.user.id.uuidString else {
            throw SimpleError(message: "No user ID")
        }
        
        struct ProfileUpdate: Encodable {
            let first_name: String?
            let last_name: String?
            let phone: String?
            let city: String?
            let avatar_url: String?
        }

        let payload = ProfileUpdate(
            first_name: patch.firstName,
            last_name: patch.lastName,
            phone: patch.phone,
            city: patch.city,
            avatar_url: patch.avatarUrl
        )

        // Update profiles table
        _ = try await client.database
            .from("profiles")
            .update(payload)
            .eq("id", value: uid)
            .execute()
        
        #if DEBUG
        print("[PROFILE] Updated via SDK: \(patch.firstName ?? "") \(patch.lastName ?? "")")
        #endif
        
        // Update session metadata
        try await updateSessionMetadata(
            firstName: patch.firstName,
            lastName: patch.lastName,
            phone: patch.phone
        )
    }
    
    /// Update session metadata after profile changes
    private func updateSessionMetadata(firstName: String?, lastName: String?, phone: String?) async throws {
        // Construct full name from first and last name
        let fullName = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        var updates: [String: Any] = [:]
        if !fullName.isEmpty {
            updates["full_name"] = fullName
            updates["name"] = fullName // Some providers use 'name' instead
        }
        if let phone = phone?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
            updates["phone"] = phone
        }
        
        // Refresh session to get updated metadata
        let refreshedSession = try await client.auth.refreshSession()
        applyAuthSession(refreshedSession)
    }
    
    /// Delete user account and all associated data
    @MainActor
    func deleteAccount() async throws {
        // Domain account deletion is not handled via Supabase RPC in the app layer.
        // If needed, expose a Flask endpoint and call it via ApiService.
        throw SimpleError(message: "Account deletion not supported from client.")
    }
    
    @MainActor
    func applyAuthForGate(_ s: Session?) { applyAuthSession(s) }

    // MARK: - Feed

    func fetchFeed(
        near: CLLocationCoordinate2D,
        radiusKM: Double = 50,
        category: String? = nil,
        condition: String? = nil,
        mode: String? = nil
    ) async {
        // Build key and debounce window
        let key = FeedFetchKey(lat: near.latitude, lon: near.longitude, radiusKM: radiusKM, mode: mode ?? "all")
        let debounceMs = Int.random(in: 300...500)
        feedReqCounter &+= 1
        let reqId = feedReqCounter

        await feedGate.schedule(key: key, debounceMs: debounceMs) { [weak self] in
            guard let self else { return }
            let start = Date()
            #if DEBUG
            print("[FEED req] id=\(reqId) key=(lat=\(String(format: "%.5f", key.lat)), lon=\(String(format: "%.5f", key.lon)), mode=\(key.mode), r=\(key.radiusKM)) start")
            #endif
            do {
                let count = try await self._performFetchFeed(near: near, radiusKM: radiusKM, category: category, condition: condition)
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("[FEED req] id=\(reqId) done ms=\(ms) count=\(count)")
                #endif
            } catch {
                // Silent on cancellations; otherwise fallback remains handled inside
                if error.isCancellationLike {
                    return
                }
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("[FEED req] id=\(reqId) fail ms=\(ms) error=\(error.localizedDescription)")
                #endif
            }
        }
    }

    @MainActor
    private func _performFetchFeed(
        near: CLLocationCoordinate2D,
        radiusKM: Double,
        category: String?,
        condition: String?
    ) async throws -> Int {
        let maxAttempts = 2
        var lastError: Error?
        for attempt in 1...maxAttempts {
            let attemptStart = Date()
            do {
                try Task.checkCancellation()
                let rows = try await withTimeout(seconds: 6.0) {
                    try await ItemsService.shared.getFeed(
                        lat: near.latitude,
                        lon: near.longitude,
                        radiusKm: radiusKM,
                        category: category,
                        condition: condition
                    )
                }
                let mapped = rows.map { r in
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
                feed = mapped
                cachedFeed = mapped
                feedIsOffline = false
                // Persist cache after successful fetch
                feedCacheStore.save(items: mapped)
                let ms = Int(Date().timeIntervalSince(attemptStart) * 1000)
                Metrics.feedFetchMs(ms, count: mapped.count)
                return mapped.count
            } catch {
                if error.isCancellationLike { throw error }
                lastError = error
                let elapsed = Date().timeIntervalSince(attemptStart)
                #if DEBUG
                let formatted = String(format: "%.2f", elapsed)
                print("[FEED retry] attempt=\(attempt) elapsed=\(formatted)s error=\(error.localizedDescription)")
                #endif
            }
        }
        feedIsOffline = true
        if !cachedFeed.isEmpty {
            feed = cachedFeed
            #if DEBUG
            let ageMs = feedCacheStore.currentAgeMs() ?? -1
            print("[FEED fallback] using cached feed count=\(cachedFeed.count) dataAgeMs=\(ageMs)")
            if let lastError {
                print("[FEED fallback] lastError=\(lastError.localizedDescription)")
            }
            #endif
            return cachedFeed.count
        } else if let lastError {
            #if DEBUG
            print("[FEED fallback] no cache available error=\(lastError.localizedDescription)")
            #endif
        }
        return 0
    }

    // MARK: - My stuff

    func fetchMyStuff() async {
        guard hasAuthToken else {
            resetLists()
            return
        }
        
        let api = ApiService(supabaseService: self)
        do {
            try Task.checkCancellation()
            
            async let postsTask = api.getMyPosts()
            async let reservationsTask = api.getMyReservations()
            
            let posts = try await postsTask
            let reservations = try await reservationsTask
            
            let uploads = posts.map { mapPostToDTO($0, reservation: nil) }
            let reservationItems = reservations.map { mapPostToDTO($0.post, reservation: $0) }
            
            myUploads = uploads
            myReservations = reservationItems
            pending = reservationItems.filter { $0.status.lowercased() == "pending" }
            #if DEBUG
            print("[PROFILE] fetchMyStuff success uploads=\(uploads.count) reservations=\(reservationItems.count) pending=\(pending.count)")
            #endif
        } catch {
            // Silently ignore cancellations - they're expected when view disappears
            if error.isCancellationLike {
                return
            }
            
            #if DEBUG
            NetLog.profileOnce("fetchMyStuff error=\(error.localizedDescription)")
            #endif
            resetLists()
        }
    }
    
    private func resetLists() {
        myUploads = []
        myReservations = []
        pending = []
    }
    
    private func mapPostToDTO(_ post: Post, reservation: Reservation?) -> TrashDTO {
        let exactCoord = post.exactLocation?.coordinate
        let approxCoord = post.approxLocation?.coordinate
        let createdAt = post.createdAt ?? Date()
        let expiresAt = post.expiresAt ?? createdAt
        let status = reservation?.status ?? post.userReservation?.status ?? "available"
        let reservedUntil = reservation?.endAt.flatMap(parseISODate)
        let reservedBy = (reservation?.reserver).flatMap { UUID(uuidString: $0) }
        let pickedUpAt = reservation?.pickedAt.flatMap(parseISODate)
        
        let uploaderUUID = UUID(uuidString: post.ownerId)
        if uploaderUUID == nil {
            #if DEBUG
            print("[PROFILE] ⚠️ ownerId not UUID: \(post.ownerId)")
            #endif
        }
        let postUUID = UUID(uuidString: post.id)
        if postUUID == nil {
            #if DEBUG
            print("[PROFILE] ⚠️ post id not UUID: \(post.id)")
            #endif
        }
        
        let sortedImages = post.images.sorted { $0.orderIndex < $1.orderIndex }
        return TrashDTO(
            id: postUUID ?? UUID(),
            title: post.title,
            description: post.description,
            category: post.category,
            condition: post.condition.rawValue,
            mode: post.mode.rawValue,
            city: post.owner?.city,
            lat: exactCoord?.latitude,
            lon: exactCoord?.longitude,
            approxLat: approxCoord?.latitude,
            approxLon: approxCoord?.longitude,
            photoURLs: sortedImages.map(\.url),
            createdAt: createdAt,
            expiresAt: expiresAt,
            status: status,
            reservedUntil: reservedUntil,
            reservedBy: reservedBy,
            uploader: uploaderUUID ?? UUID(),
            pickedUpAt: pickedUpAt
        )
    }
    
    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    private func parseISODate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let value = SupabaseService.iso8601WithFraction.date(from: raw) {
            return value
        }
        return SupabaseService.iso8601NoFraction.date(from: raw)
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

        // Use a deterministic postId for both DB row and storage object paths
        let postId = UUID()
        let signedURLs: [URL] = try await ImageStorage.uploadJPEGs(client: client, images: images, uploader: uid, postId: postId)
        guard !signedURLs.isEmpty else { throw SimpleError(message: "Image upload failed") }

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
            id: postId,
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
            photo_urls: signedURLs.map { $0.absoluteString },
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
        let api = ApiService(supabaseService: self)
        try await api.approveReservation(reservationId.uuidString)
    }

    func cancelReservation(_ item: TrashDTO) async {
        let api = ApiService(supabaseService: self)
        do { _ = try await api.cancelReservation(item.id.uuidString) }
        catch { /* swallow to keep UI responsive */ }
    }

    func confirmPickup(_ item: TrashDTO) async {
        // For pickups we typically complete a reservation; depends on your domain.
        // If you have a reservation id, call ApiService.completeReservation.
        // Here we no-op on the service layer; views already call ApiService directly.
    }
}

// MARK: - Single refresh guard actor
actor RefreshGate {
    private var refreshing = false
    func begin() -> Bool {
        if refreshing { return false }
        refreshing = true
        return true
    }
    func end() { refreshing = false }
}

// MARK: - Feed single-flight with debounce
struct FeedFetchKey: Hashable {
    let lat: Double
    let lon: Double
    let radiusKM: Double
    let mode: String
}

actor FeedSingleFlight {
    private struct TrackedTask {
        let id: UUID
        let task: Task<Void, Error>
    }

    private var tasks: [FeedFetchKey: TrackedTask] = [:]

    /// Schedule a debounced single-flight task for a key. Any in-flight task for the key is cancelled.
    /// Cancellations are silent. The latest scheduled task wins.
    func schedule(key: FeedFetchKey, debounceMs: Int, operation: @escaping @Sendable () async throws -> Void) async {
        // Cancel prior task if any
        if let existing = tasks[key] {
            existing.task.cancel()
        }
        // Create new debounced task
        let token = UUID()
        let task = Task<Void, Error> {
            // Debounce window 300–500ms
            try? await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
            // If cancelled during debounce, throw to exit silently
            try Task.checkCancellation()
            try await operation()
        }
        tasks[key] = TrackedTask(id: token, task: task)

        do {
            try await task.value
        } catch {
            // Silent on cancellations or if the task was superseded
            if error.isCancellationLike {
                // no-op
            }
        }
        // Clean up if still the same scheduled task (compare by token)
        if let current = tasks[key], current.id == token {
            tasks[key] = nil
        }
    }
}

// MARK: - Public refresh wrapper for ApiService 401 retry
extension SupabaseService {
    /// Refresh the GoTrue session so a new access token is issued.
    /// Guarded to avoid concurrent refresh storms.
    func refreshSession() async throws {
        let acquired = await refreshGate.begin()
        if !acquired {
            #if DEBUG
            print("[AUTH] refresh skip (guarded=true)")
            #endif
            return
        }
        #if DEBUG
        print("[AUTH] refresh start (guarded=true)")
        #endif
        defer { Task { await refreshGate.end()
            #if DEBUG
            print("[AUTH] refresh end (guarded=true)")
            #endif
        } }

        let s = try await client.auth.refreshSession()
        await MainActor.run { [s] in
            applyAuthSession(s)
        }
    }

    @MainActor
    func setDidCheckSession(_ value: Bool) {
#if DEBUG
        assert(Thread.isMainThread, "setDidCheckSession must be on main thread")
#endif
        didCheckSession = value
    }
}

// MARK: - Public Auth Mutations (single entry points for views)

extension SupabaseService {
    /// Views should call this instead of mutating auth/session state directly.
    @MainActor
    func signOut() {
        applyAuthSession(nil)
        didCheckSession = true
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
    @MainActor
    func applyAuthSession(_ session: Session?) {
        #if DEBUG
        print("[AUTH] applyAuthSession on main actor")
        #endif
        self.session = session
        if let s = session {
            self.userId = s.user.id
            // Authenticated only if we have a non-empty access token
            let tokenOk = s.accessToken.isEmpty == false
            self.isAuthenticated = tokenOk
            if tokenOk {
                KeychainStore.saveSession(accessToken: s.accessToken, refreshToken: s.refreshToken)
                if phase != .signedIn { phase = .signedIn }
                AuthLogger.sessionApplied(userId: s.user.id.uuidString, accessTokenPresent: true)
            } else {
                KeychainStore.clearSession()
                if phase != .signedOut { phase = .signedOut }
            }
        } else {
            self.userId = nil
            self.isAuthenticated = false
            KeychainStore.clearSession()
            if phase != .signedOut { phase = .signedOut }
        }
    }

    func restoreSessionIfPossible() async {
        // Load Keychain off-main
        let creds = await Task.detached { KeychainStore.loadSession() }.value
        guard let creds else {
            // No tokens: update UI state on main actor
            await MainActor.run {
                applyAuthSession(nil)
                didCheckSession = true
            }
            return
        }
        // Try setSession (network) off-main, then publish on main
        do {
            let s = try await client.auth.setSession(
                accessToken: creds.accessToken,
                refreshToken: creds.refreshToken
            )
            await MainActor.run {
                applyAuthSession(s)
                didCheckSession = true
            }
        } catch {
            // On failure with cached tokens: avoid brief auth flash; keep splash briefly
            await Task.detached { KeychainStore.clearSession() }.value
            // Allow background bootstrapAuth up to 600ms to succeed, then fall back to auth
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if self.phase != .signedIn {
                    applyAuthSession(nil)
                    didCheckSession = true
                }
            }
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

// MARK: - Auth readiness helper

extension SupabaseService {
    var hasAuthToken: Bool {
        guard let token = session?.accessToken else { return false }
        return token.isEmpty == false
    }
}

