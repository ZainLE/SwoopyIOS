import Foundation
import CoreLocation

// MARK: - App model used by SwiftUI (Supabase-backed, multi-photo)

public struct TrashDTO: Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var description: String?
    public var category: String
    public var condition: String         // "bad" | "good" | "excellent"
    public var mode: String              // "street" | "home"
    public var city: String?             // optional UI label (not stored in items table)
    public var lat: Double?
    public var lon: Double?
    public var approxLat: Double?
    public var approxLon: Double?
    public var photoURLs: [URL]          // <= multiple images
    public var createdAt: Date
    public var expiresAt: Date
    public var status: String            // "available" | "reserved" | "picked" | "expired"
    public var reservedUntil: Date?
    public var reservedBy: UUID?
    public var uploader: UUID
    public var pickedUpAt: Date?

    // Common conveniences
    public var isExpired: Bool { Date() >= expiresAt }
    public var isReservationActive: Bool { (reservedUntil ?? .distantPast) > Date() }

    /// First/primary image for list cards etc.
    public var heroImageURL: URL? { photoURLs.first }

    public static func == (lhs: TrashDTO, rhs: TrashDTO) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Database wire format (items table)

struct DBItem: Decodable, Identifiable {
    var id: UUID
    var uploader: UUID
    var title: String
    var description: String?
    var category: String
    var condition: String
    var mode: String
    var lat: Double?
    var lon: Double?
    var approx_lat: Double?
    var approx_lon: Double?
    var photo_urls: [String]             // stored as text[] in Postgres
    var created_at: Date
    var expires_at: Date
    var status: String
    var reserved_until: Date?
    var reserved_by: UUID?
    var picked_up_at: Date?

    func toDTO() -> TrashDTO {
        TrashDTO(
            id: id,
            title: title,
            description: description,
            category: category,
            condition: condition,
            mode: mode,
            city: nil, // you can fill this later via reverse-geocoding if you want
            lat: lat, lon: lon,
            approxLat: approx_lat, approxLon: approx_lon,
            photoURLs: photo_urls.compactMap(URL.init(string:)),
            createdAt: created_at,
            expiresAt: expires_at,
            status: status,
            reservedUntil: reserved_until,
            reservedBy: reserved_by,
            uploader: uploader,
            pickedUpAt: picked_up_at
        )
    }
}

// MARK: - Convenience computed properties

extension TrashDTO {
    // Images
    var firstPhotoURL: URL? { photoURLs.first }
    /// Back-compat alias many views used before
    var photoURL: URL? { firstPhotoURL }

    // City text safe for UI
    var cityText: String { city ?? "" }

    // Coordinates
    var exactCoordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    var approxCoordinate: CLLocationCoordinate2D? {
        guard let approxLat, let approxLon else { return nil }
        return CLLocationCoordinate2D(latitude: approxLat, longitude: approxLon)
    }
    /// One coordinate to show on the map
    var mapCoordinate: CLLocationCoordinate2D? { exactCoordinate ?? approxCoordinate }
}
