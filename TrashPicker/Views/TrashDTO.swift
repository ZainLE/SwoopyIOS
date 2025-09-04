//import Foundation
//import CloudKit
//import CoreLocation
//
///// Codable wrapper that still presents CK-like types to the UI.
//struct TrashDTO: Identifiable, Codable, Hashable {
//    // Stored (codable) primitives
//    private var idRaw: String
//    var title: String
//    var category: String
//    var photoURL: URL?
//    private var latitude: CLLocationDegrees
//    private var longitude: CLLocationDegrees
//    var city: String
//    var createdAt: Date
//    var expiresAt: Date
//    var status: String                 // "open" | "reserved" | "picked" | "expired"
//    var reservedUntil: Date?
//    private var reservedByRaw: String?
//    private var uploaderRaw: String?
//    var pickedUpAt: Date?
//    var interestedCount: Int
//
//    // Exposed API your views already use
//    var id: CKRecord.ID { CKRecord.ID(recordName: idRaw) }
//    var coordinate: CLLocationCoordinate2D {
//        get { .init(latitude: latitude, longitude: longitude) }
//        set { latitude = newValue.latitude; longitude = newValue.longitude }
//    }
//    var reservedBy: CKRecord.Reference? {
//        reservedByRaw.map { CKRecord.Reference(recordID: CKRecord.ID(recordName: $0), action: .none) }
//    }
//    var uploader: CKRecord.Reference? {
//        uploaderRaw.map { CKRecord.Reference(recordID: CKRecord.ID(recordName: $0), action: .none) }
//    }
//
//    init(
//        id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString),
//        title: String,
//        category: String,
//        photoURL: URL?,
//        coordinate: CLLocationCoordinate2D,
//        city: String,
//        createdAt: Date,
//        expiresAt: Date,
//        status: String = "open",
//        reservedUntil: Date? = nil,
//        reservedBy: CKRecord.Reference? = nil,
//        uploader: CKRecord.Reference? = nil,
//        pickedUpAt: Date? = nil,
//        interestedCount: Int = 0
//    ) {
//        self.idRaw = id.recordName
//        self.title = title
//        self.category = category
//        self.photoURL = photoURL
//        self.latitude = coordinate.latitude
//        self.longitude = coordinate.longitude
//        self.city = city
//        self.createdAt = createdAt
//        self.expiresAt = expiresAt
//        self.status = status
//        self.reservedUntil = reservedUntil
//        self.reservedByRaw = reservedBy?.recordID.recordName
//        self.uploaderRaw = uploader?.recordID.recordName
//        self.pickedUpAt = pickedUpAt
//        self.interestedCount = interestedCount
//    }
//}
