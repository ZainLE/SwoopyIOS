import Foundation
import CoreLocation

private struct CachedLocationRecord: Codable {
    let exactLat: Double?
    let exactLng: Double?
    let approxLat: Double?
    let approxLng: Double?
    let modeRaw: String
    let updatedAt: Date

    var exactCoordinate: CLLocationCoordinate2D? {
        guard let lat = exactLat, let lng = exactLng else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    var approximateCoordinate: CLLocationCoordinate2D? {
        guard let lat = approxLat, let lng = approxLng else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    var mode: ItemMode {
        ItemMode(rawValue: modeRaw) ?? .street
    }

    func merging(
        exact: CLLocationCoordinate2D?,
        approximate: CLLocationCoordinate2D?,
        mode: ItemMode
    ) -> CachedLocationRecord {
        CachedLocationRecord(
            exactLat: exact?.latitude ?? exactLat,
            exactLng: exact?.longitude ?? exactLng,
            approxLat: approximate?.latitude ?? approxLat,
            approxLng: approximate?.longitude ?? approxLng,
            modeRaw: mode.rawValue,
            updatedAt: Date()
        )
    }
}

final class LocationCache {
    static let shared = LocationCache()

    private let queue = DispatchQueue(label: "com.trashpicker.location-cache", attributes: .concurrent)
    private let fileURL: URL
    private let ttl: TimeInterval = 60 * 60 * 24 // 24 hours
    private var storage: [String: CachedLocationRecord] = [:]

    init() {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        fileURL = cachesURL.appendingPathComponent("location-cache.json")
        loadFromDisk()
    }

    func store(post: Post) {
        store(
            postId: post.id,
            mode: post.mode,
            exact: post.exactCoordinate,
            approximate: post.approxCoordinate
        )
    }

    func store(
        postId: String,
        mode: ItemMode,
        exact: CLLocationCoordinate2D?,
        approximate: CLLocationCoordinate2D?
    ) {
        guard exact != nil || approximate != nil else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let existing = storage[postId]
            let record = existing?.merging(exact: exact, approximate: approximate, mode: mode)
                ?? CachedLocationRecord(
                    exactLat: exact?.latitude,
                    exactLng: exact?.longitude,
                    approxLat: approximate?.latitude,
                    approxLng: approximate?.longitude,
                    modeRaw: mode.rawValue,
                    updatedAt: Date()
                )
            storage[postId] = record
            saveToDisk()
        }
    }

    func coordinate(for postId: String, mode: ItemMode) -> CLLocationCoordinate2D? {
        var record: CachedLocationRecord?
        queue.sync {
            if let entry = storage[postId], !isExpired(entry) {
                record = entry
            } else if storage[postId] != nil {
                storage.removeValue(forKey: postId)
                saveToDisk()
            }
        }
        guard let record else { return nil }
        switch mode {
        case .street:
            return record.exactCoordinate
        case .home:
            return record.approximateCoordinate
        }
    }

    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            self?.storage.removeAll()
            self?.saveToDisk()
        }
    }

    func remove(postId: String) {
        queue.async(flags: .barrier) { [weak self] in
            self?.storage.removeValue(forKey: postId)
            self?.saveToDisk()
        }
    }

    // MARK: - Private

    private func isExpired(_ record: CachedLocationRecord) -> Bool {
        Date().timeIntervalSince(record.updatedAt) > ttl
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else {
            storage = [:]
            return
        }
        if let decoded = try? JSONDecoder().decode([String: CachedLocationRecord].self, from: data) {
            let now = Date()
            storage = decoded.filter { now.timeIntervalSince($0.value.updatedAt) <= ttl }
        } else {
            storage = [:]
        }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
