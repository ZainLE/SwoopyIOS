////
////  SupabaseService.swift
////  TrashPicker
////
////  Uses Supabase Swift 2.x style:
////  - client.from("table") instead of client.database
////  - client.rpc("func_name", params: ...) (no `fn:` label)
////  - Encodable payloads for inserts/updates (no heterogenous dictionaries)
////
//
//import Foundation
//import SwiftUI
//import CoreLocation
//import UIKit
//import Supabase
//
//@MainActor
//final class SupabaseService: ObservableObject {
//    static let shared = SupabaseService()
//
//    // MARK: - State exposed to UI
//    @Published var feed: [TrashDTO] = []
//    @Published var myUploads: [TrashDTO] = []
//    @Published var myReservations: [TrashDTO] = []
//
//    @Published private(set) var userId: UUID?
//
//    // MARK: - Supabase client
//    let client: SupabaseClient = .init(
//        supabaseURL: SupabaseConfig.url,
//        supabaseKey: SupabaseConfig.anonKey
//    )
//
//    private init() {}
//
//    // MARK: - Auth
//
//    /// Anonymous sign-in is simplest for TestFlight; enable it in Supabase Auth.
//    func ensureSession() async {
//        do {
//            if self.userId == nil {
//                _ = try await client.auth.signInAnonymously()
//            }
//            let session = try await client.auth.session
//            self.userId = session.user.id
//        } catch {
//            print("Auth ensureSession error:", error.localizedDescription)
//        }
//    }
//
//    // MARK: - Fetch
//
//    func fetchFeed(limit: Int = 50) async {
//        do {
//            let nowIso = iso(Date())
//            // open, not expired, and either no reservation or reservation in the past
//            let rows: [DBPost] = try await client
//                .from(SupabaseConfig.postsTable)
//                .select()
//                .eq("status", value: "open")
//                .gt("expires_at", value: nowIso)
//                .or("reserved_until.is.null,reserved_until.lt.\(nowIso)")
//                .order("created_at", ascending: false)
//                .limit(limit)
//                .execute()
//                .value
//
//            self.feed = rows.map { $0.toDTO() }
//        } catch {
//            print("fetchFeed error:", error.localizedDescription)
//        }
//    }
//
//    func fetchMyStuff() async {
//        guard let uid = userId else { return }
//        do {
//            async let uploads: [DBPost] = client
//                .from(SupabaseConfig.postsTable)
//                .select()
//                .eq("uploader", value: uid.uuidString)
//                .order("created_at", ascending: false)
//                .execute()
//                .value
//
//            let nowIso = iso(Date())
//            async let reservations: [DBPost] = client
//                .from(SupabaseConfig.postsTable)
//                .select()
//                .eq("reserved_by", value: uid.uuidString)
//                .gt("reserved_until", value: nowIso)
//                .order("reserved_until", ascending: false)
//                .execute()
//                .value
//
//            self.myUploads = try await uploads.map { $0.toDTO() }
//            self.myReservations = try await reservations.map { $0.toDTO() }
//        } catch {
//            print("fetchMyStuff error:", error.localizedDescription)
//        }
//    }
//
//    // MARK: - Mutations
//
//    func createTrash(image: UIImage,
//                     title: String,
//                     description: String,
//                     condition: String,
//                     category: String,
//                     coordinate: CLLocationCoordinate2D,
//                     city: String) async throws {
//        guard let uid = userId else { throw SimpleError("No user/session") }
//        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw SimpleError("JPEG encode failed") }
//
//        // 1) Upload image
//        let (path, publicURL) = try await ImageStorage.uploadJPEG(client: client, data: jpeg, uploader: uid)
//
//        // 2) Insert row (Encodable payload; dates as ISO strings)
//        let now = Date()
//        let insert = NewPostInsert(
//            id: UUID(),
//            title: title,
//            description: description,
//            category: category,
//            condition: condition,
//            city: city,
//            lat: coordinate.latitude,
//            lon: coordinate.longitude,
//            photo_path: path,
//            photo_url: publicURL,
//            created_at: iso(now),
//            expires_at: iso(now.addingTimeInterval(24*3600)),
//            status: "open",
//            uploader: uid
//        )
//
//        _ = try await client
//            .from(SupabaseConfig.postsTable)
//            .insert(insert)
//            .execute()
//
//        await fetchFeed()
//        await fetchMyStuff()
//    }
//
//    func reserve(_ item: TrashDTO, hours: Int = 6) async throws {
//        guard let uid = userId else { throw SimpleError("No user/session") }
//        let until = iso(Date().addingTimeInterval(Double(hours) * 3600))
//
//        let patch = ReservePatch(status: "reserved", reserved_by: uid, reserved_until: until)
//
//        _ = try await client
//            .from(SupabaseConfig.postsTable)
//            .update(patch)
//            .eq("id", value: item.id)
//            .execute()
//
//        await fetchFeed()
//        await fetchMyStuff()
//    }
//
//    func cancelReservation(_ item: TrashDTO) async {
//        // Preferred: server-side function that sets reserved_by = NULL, reserved_until = NULL, status='open'
//        do {
//            _ = try await client
//                .rpc("clear_reservation", params: ["p_post_id": item.id.uuidString])
//                .execute()
//        } catch {
//            // Fallback: open it and push reserved_until into the past (visible again in feed).
//            do {
//                let fallback = OpenPatch(
//                    status: "open",
//                    reserved_until: iso(Date().addingTimeInterval(-3600))
//                )
//                _ = try await client
//                    .from(SupabaseConfig.postsTable)
//                    .update(fallback)
//                    .eq("id", value: item.id)
//                    .execute()
//            } catch {
//                print("cancelReservation error:", error.localizedDescription)
//            }
//        }
//
//        await fetchFeed()
//        await fetchMyStuff()
//    }
//
//    func confirmPickup(_ item: TrashDTO) async throws {
//        let patch = PickupPatch(status: "picked", picked_up_at: iso(Date()))
//        _ = try await client
//            .from(SupabaseConfig.postsTable)
//            .update(patch)
//            .eq("id", value: item.id)
//            .execute()
//
//        await fetchFeed()
//        await fetchMyStuff()
//    }
//
//    func registerInterest(_ item: TrashDTO) async {
//        do {
//            _ = try await client
//                .rpc("increment_interest", params: ["post_id": item.id.uuidString])
//                .execute()
//            await fetchFeed()
//        } catch {
//            // Fallback without RPC
//            do {
//                let patch = InterestPatch(interested_count: item.interestedCount + 1)
//                _ = try await client
//                    .from(SupabaseConfig.postsTable)
//                    .update(patch)
//                    .eq("id", value: item.id)
//                    .execute()
//                await fetchFeed()
//            } catch {
//                print("registerInterest error:", error.localizedDescription)
//            }
//        }
//    }
//}
//
//// MARK: - Payloads (Encodable)
//
///// Row insert
//private struct NewPostInsert: Encodable {
//    let id: UUID
//    let title: String
//    let description: String
//    let category: String
//    let condition: String
//    let city: String
//    let lat: Double
//    let lon: Double
//    let photo_path: String?
//    let photo_url: String?
//    let created_at: String    // ISO string
//    let expires_at: String    // ISO string
//    let status: String
//    let uploader: UUID
//    let interested_count: Int = 0
//}
//
///// Reserve patch
//private struct ReservePatch: Encodable {
//    let status: String
//    let reserved_by: UUID
//    let reserved_until: String   // ISO
//}
//
///// Open (fallback) patch
//private struct OpenPatch: Encodable {
//    let status: String
//    let reserved_until: String   // ISO
//}
//
///// Picked up patch
//private struct PickupPatch: Encodable {
//    let status: String
//    let picked_up_at: String     // ISO
//}
//
///// Interest fallback patch
//private struct InterestPatch: Encodable {
//    let interested_count: Int
//}
//
//// MARK: - Helpers
//
//struct SimpleError: LocalizedError { let message: String; init(_ m: String){ message = m }
//    var errorDescription: String? { message }
//}
//
//fileprivate func iso(_ date: Date) -> String {
//    let f = ISO8601DateFormatter()
//    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
//    return f.string(from: date)
//}

// SupabaseService.swift
import Foundation
import SwiftUI
import CoreLocation
import UIKit
import Supabase

@MainActor
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    @Published var feed: [TrashDTO] = []
    @Published var myUploads: [TrashDTO] = []
    @Published var myReservations: [TrashDTO] = []
    @Published var pending: [TrashDTO] = []           // pending approvals for my items (Home mode)
    @Published private(set) var userId: UUID?

    let client = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)

    private init() {}

    // MARK: Auth (Email/Apple/Google supported by Supabase)
    func ensureSession() async {
        do {
            if (try? await client.auth.session.user.id) == nil {
                _ = try await client.auth.signInAnonymously()
            }
            let s = try await client.auth.session
            self.userId = s.user.id
        } catch {
            print("ensureSession:", error.localizedDescription)
            self.userId = nil
        }
    }

    // Add real logins when you wire UI:
    // - Apple: signInWithIdToken(idToken:identityTokenString, nonce:nonce)
    // - Google: signInWithIdToken(..., accessToken: ...)
    // - Email: signInWithOTP(email:)

    // MARK: Feed (sorted by distance)
    private struct GetFeedParams: Encodable {
        let p_lat: Double
        let p_lon: Double
        let p_radius_km: Double
        let p_category: String?
        let p_condition: String?
    }

    func fetchFeed(near: CLLocationCoordinate2D, radiusKM: Double = 50, category: String? = nil, condition: String? = nil) async {
        do {
            let params = GetFeedParams(
                p_lat: near.latitude,
                p_lon: near.longitude,
                p_radius_km: radiusKM,
                p_category: category,
                p_condition: condition
            )
            let rows: [DBItem] = try await client.rpc("get_feed", params: params).execute().value
            self.feed = rows.map { $0.toDTO() }
        } catch {
            print("fetchFeed:", error.localizedDescription)
        }
    }

    // MARK: My stuff
    func fetchMyStuff() async {
        guard let uid = userId else { return }
        do {
            // uploads
            let uploads: [DBItem] = try await client
                .from(SupabaseConfig.postsTable)
                .select()
                .eq("uploader", value: uid.uuidString)
                .order("created_at", ascending: false)
                .execute().value
            self.myUploads = uploads.map { $0.toDTO() }

            // active reservations (where I am reserver)
            let active: [DBItem] = try await client
                .from(SupabaseConfig.postsTable)
                .select()
                .eq("reserved_by", value: uid.uuidString)
                .order("reserved_until", ascending: false)
                .execute().value
            self.myReservations = active.map { $0.toDTO() }

            // pending approvals for my items (Home mode)
            struct Row: Decodable { let id: UUID }
            let pend: [Row] = try await client
                .from("reservations")
                .select("item_id:id, item_id") // compatibility
                .eq("status", value: "pending")
                .execute().value
            let ids = pend.map { $0.id }
            if ids.isEmpty {
                self.pending = []
            } else {
                let pendItems: [DBItem] = try await client
                    .from(SupabaseConfig.postsTable)
                    .select()
                    .in("id", values: ids)
                    .eq("uploader", value: uid.uuidString)
                    .execute().value
                self.pending = pendItems.map { $0.toDTO() }
            }
        } catch {
            print("fetchMyStuff:", error.localizedDescription)
        }
    }

    // MARK: Create post (street/home, up to 3 images)
    func createItem(images: [UIImage],
                    title: String,
                    description: String?,
                    category: String,
                    condition: String,
                    mode: String,                       // "street" | "home"
                    coordinate: CLLocationCoordinate2D,  // exact user point
                    homeGrid: Double = 0.01) async throws
    {
        if userId == nil { await ensureSession() }
        guard let uid = userId else { throw SimpleError(message: "No user/session") }

        let photoURLs = try await ImageStorage.uploadJPEGs(client: client, images: images, uploader: uid)
        guard !photoURLs.isEmpty else { throw SimpleError(message: "Image upload failed") }

        // Home mode: obfuscate coordinate on client *too*, for defense in depth.
        var lat = coordinate.latitude, lon = coordinate.longitude
        var approxLat: Double? = nil, approxLon: Double? = nil
        if mode == "home" {
            approxLat = (lat / homeGrid).rounded() * homeGrid
            approxLon = (lon / homeGrid).rounded() * homeGrid
            lat = .nan; lon = .nan        // do not send exact location for Home mode
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
            created_at: iso(now),
            expires_at: iso(now.addingTimeInterval(24*3600)),
            status: "available"
        )

        _ = try await client.from(SupabaseConfig.postsTable).insert(payload).execute()
    }

    // MARK: Reservation life-cycle
    private struct ReservePostParams: Encodable {
        let p_post_id: UUID
        let p_hours: Int
    }
    func reserve(_ item: TrashDTO, hours: Int = 6) async throws {
        if userId == nil { await ensureSession() }
        let params = ReservePostParams(p_post_id: item.id, p_hours: hours)
        _ = try await client.rpc("reserve_post", params: params).execute()
    }

    private struct ApproveReservationParams: Encodable {
        let p_reservation_id: UUID
        let p_hours: Int
    }
    func approve(reservationId: UUID, hours: Int = 6) async throws {
        let params = ApproveReservationParams(p_reservation_id: reservationId, p_hours: hours)
        _ = try await client.rpc("approve_reservation", params: params).execute()
    }

    private struct ClearReservationParams: Encodable {
        let p_post_id: UUID
    }
    func cancelReservation(_ item: TrashDTO) async {
        do {
            let params = ClearReservationParams(p_post_id: item.id)
            _ = try await client.rpc("clear_reservation", params: params).execute()
        } catch { print("cancelReservation:", error.localizedDescription) }
    }

    private struct MarkPickedParams: Encodable {
        let p_post_id: UUID
    }
    func confirmPickup(_ item: TrashDTO) async {
        do {
            let params = MarkPickedParams(p_post_id: item.id)
            _ = try await client.rpc("mark_picked_up", params: params).execute()
        } catch { print("confirmPickup:", error.localizedDescription) }
    }
}

// Errors + date
struct SimpleError: LocalizedError { let message: String; var errorDescription: String? { message } }
fileprivate func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from: d) }
