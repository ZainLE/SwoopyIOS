import Foundation
import CoreLocation
import UIKit
import CloudKit

// ---- Minimal CloudKit shims (so the rest of your views compile unchanged)
public struct CKRecord {
    public struct ID: Hashable, Codable { public let uuid: UUID; public init(_ u: UUID = UUID()) { uuid = u } }
    public struct Reference: Hashable, Codable { public let id: ID; public init(recordID: ID) { id = recordID } }
}

// ---- App model exposed to views (no Codable needed)
struct TrashDTO: Identifiable {
    let id: CKRecord.ID
    var title: String
    var category: String
    var photoURL: URL?
    var coordinate: CLLocationCoordinate2D
    var city: String
    var createdAt: Date
    var expiresAt: Date
    var status: String               // "open" | "reserved" | "picked" | "expired"
    var reservedUntil: Date?
    var reservedBy: CKRecord.Reference?
    var uploader: CKRecord.Reference?
    var pickedUpAt: Date?
    var interestedCount: Int

    var isExpired: Bool { Date() >= expiresAt }
    var isReservationActive: Bool { (reservedUntil ?? .distantPast) > Date() }
}
extension TrashDTO: Equatable { static func ==(l: Self, r: Self) -> Bool { l.id == r.id } }
extension TrashDTO: Hashable { func hash(into h: inout Hasher) { h.combine(id) } }

// ---- Local persistence schema
private struct LocalRecord: Codable, Hashable {
    var id: UUID
    var title: String
    var category: String
    var photoFilename: String?
    var latitude: Double
    var longitude: Double
    var city: String
    var createdAt: Date
    var expiresAt: Date
    var status: String
    var reservedUntil: Date?
    var reservedBy: UUID?
    var uploader: UUID?
    var pickedUpAt: Date?
    var interestedBy: [UUID]         // users who swiped right
}

final class CKTrashService: ObservableObject {
    static let shared = CKTrashService()

    @Published var feed: [TrashDTO] = []
    @Published var myUploads: [TrashDTO] = []
    @Published var myReservations: [TrashDTO] = []

    // bump keys to v2 to migrate old data cleanly
    private let storeKey  = "local_trash_store_v2"
    private let seededKey = "local_trash_seeded_v2"

    // pseudo current user for local mode
    private let me = UUID()

    init() {
        seedIfNeeded()
        Task { await refreshViews() }
    }

    // MARK: Public API

    func createTrash(image: UIImage, title: String, category: String, coordinate: CLLocationCoordinate2D, city: String) async throws {
        var all = load()
        let now = Date()
        let expires = Calendar.current.date(byAdding: .hour, value: 24, to: now)!

        let filename = "\(UUID().uuidString).jpg"
        try image.jpegData(compressionQuality: 0.85)?
            .write(to: photosDir().appendingPathComponent(filename), options: .atomic)

        all.append(LocalRecord(
            id: UUID(),
            title: title,
            category: category,
            photoFilename: filename,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            city: city,
            createdAt: now,
            expiresAt: expires,
            status: "open",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: me,
            pickedUpAt: nil,
            interestedBy: []
        ))
        save(all)
        await refreshViews()
    }

    func fetchFeed() async { await refreshViews() }

    func fetchMyStuff() async {
        let all = load()
        myUploads = all
            .filter { $0.uploader == me }
            .map(map(_:))
            .sorted { $0.createdAt > $1.createdAt }

        myReservations = all
            .filter { $0.reservedBy == me && ($0.reservedUntil ?? .distantPast) > Date() }
            .map(map(_:))
            .sorted { ($0.reservedUntil ?? .distantPast) > ($1.reservedUntil ?? .distantPast) }
    }

    func reserve(_ item: TrashDTO, hours: Int = 6) async throws {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
        all[idx].status = "reserved"
        all[idx].reservedBy = me
        all[idx].reservedUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
        save(all)
        await refreshViews()
    }

    func confirmPickup(_ item: TrashDTO) async throws {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
        all[idx].status = "picked"
        all[idx].pickedUpAt = Date()
        save(all)
        await refreshViews()
    }

    func releaseIfReservationExpired(_ item: TrashDTO) async {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
        if all[idx].status == "reserved",
           (all[idx].reservedUntil ?? .distantPast) < Date() {
            all[idx].status = "open"
            all[idx].reservedBy = nil
            all[idx].reservedUntil = nil
            save(all)
        }
    }

    func expireIfPast24h(_ item: TrashDTO) async {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
        if all[idx].status != "picked", all[idx].expiresAt < Date() {
            all[idx].status = "expired"
            save(all)
        }
    }

    // called when someone swipes right on a card (interest)
    func registerInterest(_ item: TrashDTO) async {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
        if !all[idx].interestedBy.contains(me) {
            all[idx].interestedBy.append(me)
            save(all)
            await refreshViews()
        }
    }

    // helpers
    func isMine(_ item: TrashDTO) -> Bool { item.uploader?.id.uuid == me }
    func reservationText(_ item: TrashDTO) -> String {
        if let until = item.reservedUntil, until > Date() { return "Reserved until \(until.formatted(date: .omitted, time: .shortened))" }
        return "Not reserved"
    }

    // MARK: Internals

    private func refreshViews() async {
        var all = load()
        let now = Date()
        for i in all.indices {
            if all[i].status != "picked", all[i].expiresAt < now { all[i].status = "expired" }
            if all[i].status == "reserved", (all[i].reservedUntil ?? .distantPast) < now {
                all[i].status = "open"; all[i].reservedBy = nil; all[i].reservedUntil = nil
            }
        }
        save(all)

        let open = all.filter {
            $0.status == "open" &&
            $0.expiresAt > now &&
            (($0.reservedUntil ?? .distantPast) < now)
        }
        self.feed = open.map(map(_:)).sorted { $0.createdAt > $1.createdAt }
        await fetchMyStuff()
    }

    private func map(_ r: LocalRecord) -> TrashDTO {
        let url = r.photoFilename.map { photosDir().appendingPathComponent($0) }
        return TrashDTO(
            id: .init(r.id),
            title: r.title,
            category: r.category,
            photoURL: url,
            coordinate: .init(latitude: r.latitude, longitude: r.longitude),
            city: r.city,
            createdAt: r.createdAt,
            expiresAt: r.expiresAt,
            status: r.status,
            reservedUntil: r.reservedUntil,
            reservedBy: r.reservedBy.map { .init(recordID: .init($0)) },
            uploader: r.uploader.map { .init(recordID: .init($0)) },
            pickedUpAt: r.pickedUpAt,
            interestedCount: r.interestedBy.count
        )
    }

    private func photosDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func load() -> [LocalRecord] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([LocalRecord].self, from: data)) ?? []
    }

    private func save(_ all: [LocalRecord]) {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        var all: [LocalRecord] = []
        let base = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686) // Barcelona
        let cats = ["Plastic","Glass","Paper","E-Waste","Bulky","Other"]
        let titles = ["Plastic bags", "Broken glass", "Cardboard pile", "Old monitor", "Sofa", "Mixed trash"]
        for i in 0..<6 {
            let dLat = Double.random(in: -0.01...0.01)
            let dLon = Double.random(in: -0.01...0.01)
            let coord = CLLocationCoordinate2D(latitude: base.latitude + dLat, longitude: base.longitude + dLon)
            let title = titles[i]
            let img = placeholderImage(text: String(title.prefix(1)))
            let filename = "\(UUID().uuidString).jpg"
            try? img.jpegData(compressionQuality: 0.85)?
                .write(to: photosDir().appendingPathComponent(filename), options: .atomic)
            let now = Date()
            all.append(LocalRecord(
                id: UUID(),
                title: title,
                category: cats[i % cats.count],
                photoFilename: filename,
                latitude: coord.latitude,
                longitude: coord.longitude,
                city: "Barcelona",
                createdAt: now.addingTimeInterval(-Double(i)*3600),
                expiresAt: now.addingTimeInterval(24*3600),
                status: "open",
                reservedUntil: nil,
                reservedBy: nil,
                uploader: UUID(),     // seed as “others”
                pickedUpAt: nil,
                interestedBy: []
            ))
        }
        save(all)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    private func placeholderImage(text: String) -> UIImage {
        let size = CGSize(width: 600, height: 400)
        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        UIColor(hue: CGFloat.random(in: 0...1), saturation: 0.4, brightness: 0.95, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 200, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.9)
        ]
        let t = NSString(string: text)
        let r = t.size(withAttributes: attrs)
        t.draw(at: CGPoint(x: (size.width - r.width)/2, y: (size.height - r.height)/2), withAttributes: attrs)
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }
}



////
////
////
//
///// The second part of the code
/////
/////
/////
//
//
//
//
//import Foundation
//import CoreLocation
//import UIKit
//import CloudKit
//
//// ---- Minimal CloudKit shims (so the rest of your views compile unchanged)
//public struct CKRecord {
//    public struct ID: Hashable, Codable { public let uuid: UUID; public init(_ u: UUID = UUID()) { uuid = u } }
//    public struct Reference: Hashable, Codable { public let id: ID; public init(recordID: ID) { id = recordID } }
//}
//
//// ---- App model exposed to views (no Codable needed)
//struct TrashDTO: Identifiable {
//    let id: CKRecord.ID
//    var title: String
//    var category: String
//    var photoURL: URL?
//    var coordinate: CLLocationCoordinate2D
//    var city: String
//    var createdAt: Date
//    var expiresAt: Date
//    var status: String               // "open" | "reserved" | "picked" | "expired"
//    var reservedUntil: Date?
//    var reservedBy: CKRecord.Reference?
//    var uploader: CKRecord.Reference?
//    var pickedUpAt: Date?
//    var interestedCount: Int
//
//    var isExpired: Bool { Date() >= expiresAt }
//    var isReservationActive: Bool { (reservedUntil ?? .distantPast) > Date() }
//}
//extension TrashDTO: Equatable { static func ==(l: Self, r: Self) -> Bool { l.id == r.id } }
//extension TrashDTO: Hashable { func hash(into h: inout Hasher) { h.combine(id) } }
//
//// ---- Local persistence schema
//private struct LocalRecord: Codable, Hashable {
//    var id: UUID
//    var title: String
//    var category: String
//    var photoFilename: String?
//    var latitude: Double
//    var longitude: Double
//    var city: String
//    var createdAt: Date
//    var expiresAt: Date
//    var status: String
//    var reservedUntil: Date?
//    var reservedBy: UUID?
//    var uploader: UUID?
//    var pickedUpAt: Date?
//    var interestedBy: [UUID]         // users who swiped right
//}
//
//// MARK: - Service
//
//final class CKTrashService: ObservableObject {
//    static let shared = CKTrashService()
//
//    @Published var feed: [TrashDTO] = []
//    @Published var myUploads: [TrashDTO] = []
//    @Published var myReservations: [TrashDTO] = []
//
//    // bump keys to v2 to migrate old data cleanly
//    private let storeKey  = "local_trash_store_v2"
//    private let seededKey = "local_trash_seeded_v2"
//
//    // pseudo current user for local mode
//    private let me = UUID()
//
//    // dedicated queue for JSON encode/decode and disk writes
//    private let ioQueue = DispatchQueue(label: "cktrash.io", qos: .userInitiated)
//
//    init() {
//        seedIfNeeded()                       // runs once; OK to keep sync at app start
//        Task { await refreshViews() }        // compute lists off-main, publish on main
//    }
//
//    // MARK: Public API
//
//    func createTrash(image: UIImage, title: String, category: String, coordinate: CLLocationCoordinate2D, city: String) async throws {
//        var all = await loadAsync()
//        let now = Date()
//        let expires = Calendar.current.date(byAdding: .hour, value: 24, to: now)!
//
//        let filename = "\(UUID().uuidString).jpg"
//        try image.jpegData(compressionQuality: 0.85)?
//            .write(to: photosDir().appendingPathComponent(filename), options: .atomic)
//
//        all.append(LocalRecord(
//            id: UUID(),
//            title: title,
//            category: category,
//            photoFilename: filename,
//            latitude: coordinate.latitude,
//            longitude: coordinate.longitude,
//            city: city,
//            createdAt: now,
//            expiresAt: expires,
//            status: "open",
//            reservedUntil: nil,
//            reservedBy: nil,
//            uploader: me,
//            pickedUpAt: nil,
//            interestedBy: []
//        ))
//        await saveAsync(all)
//        await refreshViews()
//    }
//
//    func fetchFeed() async { await refreshViews() }
//
//    func fetchMyStuff() async {
//        // not used directly anymore; refreshViews computes all three lists in one pass
//        await refreshViews()
//    }
//
//    func reserve(_ item: TrashDTO, hours: Int = 6) async throws {
//        var all = await loadAsync()
//        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//        all[idx].status = "reserved"
//        all[idx].reservedBy = me
//        all[idx].reservedUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
//        await saveAsync(all)
//        await refreshViews()
//    }
//
//    func confirmPickup(_ item: TrashDTO) async throws {
//        var all = await loadAsync()
//        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//        all[idx].status = "picked"
//        all[idx].pickedUpAt = Date()
//        await saveAsync(all)
//        await refreshViews()
//    }
//
//    // called when someone swipes right on a card (interest)
//    func registerInterest(_ item: TrashDTO) async {
//        var all = await loadAsync()
//        guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//        if !all[idx].interestedBy.contains(me) {
//            all[idx].interestedBy.append(me)
//            await saveAsync(all)
//            await refreshViews()
//        }
//    }
//
//    // helpers
//    func isMine(_ item: TrashDTO) -> Bool { item.uploader?.id.uuid == me }
//    func reservationText(_ item: TrashDTO) -> String {
//        if let until = item.reservedUntil, until > Date() { return "Reserved until \(until.formatted(date: .omitted, time: .shortened))" }
//        return "Not reserved"
//    }
//
//    // MARK: Internals (single-pass recompute; I/O off-main; publish on main)
//
//    private func refreshViews() async {
//        // Load entire store off-main
//        var all = await loadAsync()
//
//        // Maintenance pass (expire/purge). Track if anything changes to avoid useless writes.
//        let now = Date()
//        var changed = false
//        for i in all.indices {
//            if all[i].status != "picked", all[i].expiresAt < now {
//                if all[i].status != "expired" { all[i].status = "expired"; changed = true }
//            }
//            if all[i].status == "reserved",
//               (all[i].reservedUntil ?? .distantPast) < now {
//                all[i].status = "open"
//                all[i].reservedBy = nil
//                all[i].reservedUntil = nil
//                changed = true
//            }
//        }
//        if changed { await saveAsync(all) }   // ✅ only write if needed
//
//        // Build lists in memory (still off-main)
//        let open = all.filter {
//            $0.status == "open" &&
//            $0.expiresAt > now &&
//            (($0.reservedUntil ?? .distantPast) < now)
//        }
//
//        let feedNew = open.map(map(_:)).sorted { $0.createdAt > $1.createdAt }
//        let uploadsNew = all
//            .filter { $0.uploader == me }
//            .map(map(_:))
//            .sorted { $0.createdAt > $1.createdAt }
//        let reservationsNew = all
//            .filter { $0.reservedBy == me && ($0.reservedUntil ?? .distantPast) > now }
//            .map(map(_:))
//            .sorted { ($0.reservedUntil ?? .distantPast) > ($1.reservedUntil ?? .distantPast) }
//
//        // Publish on main
//        await MainActor.run {
//            self.feed = feedNew
//            self.myUploads = uploadsNew
//            self.myReservations = reservationsNew
//        }
//    }
//
//    private func map(_ r: LocalRecord) -> TrashDTO {
//        let url = r.photoFilename.map { photosDir().appendingPathComponent($0) }
//        return TrashDTO(
//            id: .init(r.id),
//            title: r.title,
//            category: r.category,
//            photoURL: url,
//            coordinate: .init(latitude: r.latitude, longitude: r.longitude),
//            city: r.city,
//            createdAt: r.createdAt,
//            expiresAt: r.expiresAt,
//            status: r.status,
//            reservedUntil: r.reservedUntil,
//            reservedBy: r.reservedBy.map { .init(recordID: .init($0)) },
//            uploader: r.uploader.map { .init(recordID: .init($0)) },
//            pickedUpAt: r.pickedUpAt,
//            interestedCount: r.interestedBy.count
//        )
//    }
//
//    private func photosDir() -> URL {
//        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
//    }
//
//    // MARK: - I/O helpers (run on a background queue)
//
//    private func loadAsync() async -> [LocalRecord] {
//        await withCheckedContinuation { cont in
//            ioQueue.async {
//                guard let data = UserDefaults.standard.data(forKey: self.storeKey) else {
//                    cont.resume(returning: [])
//                    return
//                }
//                let decoded = (try? JSONDecoder().decode([LocalRecord].self, from: data)) ?? []
//                cont.resume(returning: decoded)
//            }
//        }
//    }
//
//    private func saveAsync(_ all: [LocalRecord]) async {
//        await withCheckedContinuation { cont in
//            ioQueue.async {
//                if let data = try? JSONEncoder().encode(all) {
//                    UserDefaults.standard.set(data, forKey: self.storeKey)
//                }
//                cont.resume()
//            }
//        }
//    }
//
//    // MARK: - Seeding (runs once)
//
//    private func seedIfNeeded() {
//        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
//        var all: [LocalRecord] = []
//        let base = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686) // Barcelona
//        let cats = ["Plastic","Glass","Paper","E-Waste","Bulky","Other"]
//        let titles = ["Plastic bags", "Broken glass", "Cardboard pile", "Old monitor", "Sofa", "Mixed trash"]
//        for i in 0..<6 {
//            let dLat = Double.random(in: -0.01...0.01)
//            let dLon = Double.random(in: -0.01...0.01)
//            let coord = CLLocationCoordinate2D(latitude: base.latitude + dLat, longitude: base.longitude + dLon)
//            let title = titles[i]
//            let img = placeholderImage(text: String(title.prefix(1)))
//            let filename = "\(UUID().uuidString).jpg"
//            try? img.jpegData(compressionQuality: 0.85)?
//                .write(to: photosDir().appendingPathComponent(filename), options: .atomic)
//            let now = Date()
//            all.append(LocalRecord(
//                id: UUID(),
//                title: title,
//                category: cats[i % cats.count],
//                photoFilename: filename,
//                latitude: coord.latitude,
//                longitude: coord.longitude,
//                city: "Barcelona",
//                createdAt: now.addingTimeInterval(-Double(i)*3600),
//                expiresAt: now.addingTimeInterval(24*3600),
//                status: "open",
//                reservedUntil: nil,
//                reservedBy: nil,
//                uploader: UUID(),     // seed as “others”
//                pickedUpAt: nil,
//                interestedBy: []
//            ))
//        }
//        // write once synchronously at first launch; negligible
//        if let data = try? JSONEncoder().encode(all) {
//            UserDefaults.standard.set(data, forKey: storeKey)
//        }
//        UserDefaults.standard.set(true, forKey: seededKey)
//    }
//
//    private func placeholderImage(text: String) -> UIImage {
//        let size = CGSize(width: 600, height: 400)
//        UIGraphicsBeginImageContextWithOptions(size, true, 0)
//        UIColor(hue: CGFloat.random(in: 0...1), saturation: 0.4, brightness: 0.95, alpha: 1).setFill()
//        UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
//        let attrs: [NSAttributedString.Key: Any] = [
//            .font: UIFont.systemFont(ofSize: 200, weight: .bold),
//            .foregroundColor: UIColor.white.withAlphaComponent(0.9)
//        ]
//        let t = NSString(string: text)
//        let r = t.size(withAttributes: attrs)
//        t.draw(at: CGPoint(x: (size.width - r.width)/2, y: (size.height - r.height)/2), withAttributes: attrs)
//        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
//        UIGraphicsEndImageContext()
//        return img
//    }
//}
