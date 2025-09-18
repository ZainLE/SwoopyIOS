///
///
///TRASH DTO IS DOING THE SAME STUFF AS THIS FILE
///
///
///
//import Foundation
//import CoreLocation
//import UIKit
//import CloudKit
//
//// ---- Minimal CloudKit shims
//public struct CKRecord {
//    public struct ID: Hashable, Codable { public let uuid: UUID; public init(_ u: UUID = UUID()) { uuid = u } }
//    public struct Reference: Hashable, Codable { public let id: ID; public init(recordID: ID) { id = recordID } }
//}
//
//// ---- App model exposed to views (local/CloudKit shim)
//struct CKTrashItem: Identifiable, Equatable, Hashable {
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
//    // Optional extras (already in your project)
//    var desc: String?
//    var condition: String?           // "bad" | "good" | "excellent"
//
//    var isExpired: Bool { Date() >= expiresAt }
//    var isReservationActive: Bool { (reservedUntil ?? .distantPast) > Date() }
//
//    static func ==(l: Self, r: Self) -> Bool { l.id == r.id }
//    func hash(into h: inout Hasher) { h.combine(id) }
//}
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
//    var interestedBy: [UUID]
//
//    // optional new fields
//    var desc: String?
//    var condition: String?
//}
//
//// ---- Reservation history log (read-only UI)
//struct ReservationHistory: Identifiable, Codable, Hashable {
//    enum Outcome: String, Codable { case picked, canceled, expired, unknown }
//    let id: UUID
//    let itemId: UUID
//    var title: String
//    var city: String
//    var photoFilename: String?
//    var reservedAt: Date
//    var outcome: Outcome?            // nil while still active
//    var completedAt: Date?
//}
//
//// MARK: - Service
//
//final class CKTrashService: ObservableObject {
//    static let shared = CKTrashService()
//
//    @Published var feed: [CKTrashItem] = []
//    @Published var myUploads: [CKTrashItem] = []
//    @Published var myReservations: [CKTrashItem] = []
//    @Published var reservationHistory: [ReservationHistory] = [] // ⬅️ for Profile "History"
//
//    private let storeKey  = "local_trash_store_v2"
//    private let seededKey = "local_trash_seeded_v2"
//    private let historyKey = "local_reservation_history_v1"
//
//    private let me = UUID()
//    private let ioQueue = DispatchQueue(label: "cktrash.io", qos: .utility)
//
//    init() {
//        seedIfNeeded()
//        // load history once
//        self.reservationHistory = loadHistorySync().sorted { ($0.completedAt ?? $0.reservedAt) > ($1.completedAt ?? $1.reservedAt) }
//        Task { await refreshViews() }
//    }
//
//    // MARK: Public API
//
//    func createTrash(
//        image: UIImage,
//        title: String,
//        category: String,
//        coordinate: CLLocationCoordinate2D,
//        city: String,
//        desc: String? = nil,
//        condition: String? = nil
//    ) async throws {
//        let filename = "\(UUID().uuidString).jpg"
//        let fileURL = photosDir().appendingPathComponent(filename)
//
//        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
//            ioQueue.async {
//                guard let data = image.jpegData(compressionQuality: 0.85) else {
//                    cont.resume(throwing: NSError(domain: "jpeg.encode", code: -1))
//                    return
//                }
//                do { try data.write(to: fileURL, options: .atomic); cont.resume(returning: ()) }
//                catch { cont.resume(throwing: error) }
//            }
//        }
//
//        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
//            ioQueue.async {
//                var all = self.loadSync()
//                let now = Date()
//                let expires = Calendar.current.date(byAdding: .hour, value: 24, to: now)!
//                all.append(LocalRecord(
//                    id: UUID(),
//                    title: title,
//                    category: category,
//                    photoFilename: filename,
//                    latitude: coordinate.latitude,
//                    longitude: coordinate.longitude,
//                    city: city,
//                    createdAt: now,
//                    expiresAt: expires,
//                    status: "open",
//                    reservedUntil: nil,
//                    reservedBy: nil,
//                    uploader: self.me,
//                    pickedUpAt: nil,
//                    interestedBy: [],
//                    desc: desc,
//                    condition: condition
//                ))
//                self.saveSync(all)
//                cont.resume(returning: ())
//            }
//        }
//
//        await refreshViews()
//    }
//
//    func fetchFeed() async { await refreshViews() }
//    func fetchMyStuff() async { await refreshViews() }
//
//    func reserve(_ item: CKTrashItem, hours: Int = 6) async throws {
//        ioQueue.sync {
//            var all = loadSync()
//            guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//            all[idx].status = "reserved"
//            all[idx].reservedBy = me
//            all[idx].reservedUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
//            saveSync(all)
//
//            // ⬇️ history: create entry if not exists
//            var hist = loadHistorySync()
//            if !hist.contains(where: { $0.itemId == all[idx].id && $0.reservedAt > Date(timeIntervalSince1970: 0) && $0.outcome == nil }) {
//                hist.append(ReservationHistory(
//                    id: UUID(),
//                    itemId: all[idx].id,
//                    title: all[idx].title,
//                    city: all[idx].city,
//                    photoFilename: all[idx].photoFilename,
//                    reservedAt: Date(),
//                    outcome: nil,
//                    completedAt: nil
//                ))
//                saveHistorySync(hist)
//            }
//        }
//        await refreshViews()
//    }
//
//    func confirmPickup(_ item: CKTrashItem) async throws {
//        ioQueue.sync {
//            var all = loadSync()
//            guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//            all[idx].status = "picked"
//            all[idx].pickedUpAt = Date()
//            saveSync(all)
//            // ⬇️ history outcome
//            markHistory(itemId: all[idx].id, outcome: .picked)
//        }
//        await refreshViews()
//    }
//
//    func cancelReservation(_ item: CKTrashItem) async {
//        ioQueue.sync {
//            var all = loadSync()
//            guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//            if all[idx].status == "reserved" {
//                all[idx].status = "open"
//                all[idx].reservedBy = nil
//                all[idx].reservedUntil = nil
//                saveSync(all)
//                // ⬇️ history outcome
//                markHistory(itemId: all[idx].id, outcome: .canceled)
//            }
//        }
//        await refreshViews()
//    }
//
//    func registerInterest(_ item: CKTrashItem) async {
//        ioQueue.sync {
//            var all = loadSync()
//            guard let idx = all.firstIndex(where: { $0.id == item.id.uuid }) else { return }
//            if !all[idx].interestedBy.contains(me) {
//                all[idx].interestedBy.append(me)
//                saveSync(all)
//            }
//        }
//        await refreshViews()
//    }
//
//    func isMine(_ item: CKTrashItem) -> Bool { item.uploader?.id.uuid == me }
//    func reservationText(_ item: CKTrashItem) -> String {
//        if let until = item.reservedUntil, until > Date() { return "Reserved until \(until.formatted(date: .omitted, time: .shortened))" }
//        return "Not reserved"
//    }
//
//    // MARK: Internals
//
//    private func refreshViews() async {
//        // compute off-main
//        let output: (feed: [CKTrashItem], uploads: [CKTrashItem], reserves: [CKTrashItem], history: [ReservationHistory]) = ioQueue.sync {
//            var all = loadSync()
//            var hist = loadHistorySync()
//            let now = Date()
//
//            for i in all.indices {
//                if all[i].status != "picked", all[i].expiresAt < now { all[i].status = "expired" }
//                // detect expired reservations by me and close them
//                if all[i].status == "reserved",
//                   (all[i].reservedUntil ?? .distantPast) < now {
//                    // if it was mine, mark expired in history
//                    if all[i].reservedBy == me {
//                        markHistoryInPlace(hist: &hist, itemId: all[i].id, outcome: .expired)
//                    }
//                    all[i].status = "open"; all[i].reservedBy = nil; all[i].reservedUntil = nil
//                }
//            }
//            saveSync(all)
//            saveHistorySync(hist)
//
//            let open = all.filter { $0.status == "open" && $0.expiresAt > now && (($0.reservedUntil ?? .distantPast) < now) }
//            let feed = open.map(map(_:)).sorted { $0.createdAt > $1.createdAt }
//            let uploads = all.filter { $0.uploader == me }.map(map(_:)).sorted { $0.createdAt > $1.createdAt }
//            let reserves = all.filter { $0.reservedBy == me && ($0.reservedUntil ?? .distantPast) > now }
//                .map(map(_:))
//                .sorted { ($0.reservedUntil ?? .distantPast) > ($1.reservedUntil ?? .distantPast) }
//
//            let history = hist.sorted { ($0.completedAt ?? $0.reservedAt) > ($1.completedAt ?? $1.reservedAt) }
//            return (feed, uploads, reserves, history)
//        }
//
//        // publish on main
//        await MainActor.run {
//            self.feed = output.feed
//            self.myUploads = output.uploads
//            self.myReservations = output.reserves
//            self.reservationHistory = output.history
//        }
//    }
//
//    private func map(_ r: LocalRecord) -> CKTrashItem {
//        let url = r.photoFilename.map { photosDir().appendingPathComponent($0) }
//        return CKTrashItem(
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
//            interestedCount: r.interestedBy.count,
//            desc: r.desc,
//            condition: r.condition
//        )
//    }
//
//    private func photosDir() -> URL {
//        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
//    }
//
//    // JSON helpers
//    private func loadSync() -> [LocalRecord] {
//        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
//        return (try? JSONDecoder().decode([LocalRecord].self, from: data)) ?? []
//    }
//    private func saveSync(_ all: [LocalRecord]) {
//        if let data = try? JSONEncoder().encode(all) {
//            UserDefaults.standard.set(data, forKey: storeKey)
//        }
//    }
//
//    private func loadHistorySync() -> [ReservationHistory] {
//        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
//        return (try? JSONDecoder().decode([ReservationHistory].self, from: data)) ?? []
//    }
//    private func saveHistorySync(_ all: [ReservationHistory]) {
//        if let data = try? JSONEncoder().encode(all) {
//            UserDefaults.standard.set(data, forKey: historyKey)
//        }
//    }
//    private func markHistory(itemId: UUID, outcome: ReservationHistory.Outcome) {
//        var hist = loadHistorySync()
//        markHistoryInPlace(hist: &hist, itemId: itemId, outcome: outcome)
//        saveHistorySync(hist)
//    }
//    private func markHistoryInPlace(hist: inout [ReservationHistory], itemId: UUID, outcome: ReservationHistory.Outcome) {
//        if let i = hist.firstIndex(where: { $0.itemId == itemId && $0.outcome == nil }) {
//            hist[i].outcome = outcome
//            hist[i].completedAt = Date()
//        } else {
//            // if we never logged (edge case), create one
//            hist.append(ReservationHistory(
//                id: UUID(), itemId: itemId,
//                title: "Reservation", city: "", photoFilename: nil,
//                reservedAt: Date(), outcome: outcome, completedAt: Date()
//            ))
//        }
//    }
//
//    // Seed demo data
//    private func seedIfNeeded() {
//        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
//        var all: [LocalRecord] = []
//        let base = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
//        let cats = ["Plastic","Glass","Paper","E-Waste","Bulky","Other"]
//        let titles = ["Plastic bags", "Broken glass", "Cardboard pile", "Old monitor", "Sofa", "Mixed trash"]
//        let conditions = ["good","excellent","bad","good","excellent","bad"]
//        let descs = [
//            "Clean bags near the bin.",
//            "Shards in a box.",
//            "Folded cardboard.",
//            "Old but working monitor.",
//            "Two-seater couch.",
//            "Mixed, mostly plastic."
//        ]
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
//                uploader: UUID(),
//                pickedUpAt: nil,
//                interestedBy: [],
//                desc: descs[i],
//                condition: conditions[i]
//            ))
//        }
//        saveSync(all)
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
