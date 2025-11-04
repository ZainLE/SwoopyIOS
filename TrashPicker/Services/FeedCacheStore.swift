import Foundation

// Disk-backed cache for last-known feed results
struct FeedCacheRecord: Codable {
    let items: [CacheItem]
    let savedAt: Date

    struct CacheItem: Codable {
        let id: UUID
        let title: String
        let description: String?
        let category: String?
        let condition: String?
        let mode: String?
        let city: String?
        let lat: Double?
        let lon: Double?
        let approxLat: Double?
        let approxLon: Double?
        let photoURLs: [String]
        let createdAt: Date
        let expiresAt: Date
        let status: String
        let reservedUntil: Date?
        let reservedBy: UUID?
        let uploader: UUID
        let pickedUpAt: Date?
    }
}

final class FeedCacheStore {
    private let fileName = "feed.cache.json"
    private var lastSavedAt: Date?

    private var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(fileName)
    }

    func save(items: [TrashDTO]) {
        let mapped = items.map { dto in
            FeedCacheRecord.CacheItem(
                id: dto.id,
                title: dto.title,
                description: dto.description,
                category: dto.category,
                condition: dto.condition,
                mode: dto.mode,
                city: dto.city,
                lat: dto.lat,
                lon: dto.lon,
                approxLat: dto.approxLat,
                approxLon: dto.approxLon,
                photoURLs: dto.photoURLs.map { $0.absoluteString },
                createdAt: dto.createdAt,
                expiresAt: dto.expiresAt,
                status: dto.status,
                reservedUntil: dto.reservedUntil,
                reservedBy: dto.reservedBy,
                uploader: dto.uploader,
                pickedUpAt: dto.pickedUpAt
            )
        }
        let record = FeedCacheRecord(items: mapped, savedAt: Date())
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: .atomic)
            lastSavedAt = record.savedAt
        } catch {
            DLog("[FEED cache] save error=\(error.localizedDescription)")
        }
    }

    func load() -> (items: [TrashDTO], savedAt: Date)? {
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(FeedCacheRecord.self, from: data)
            lastSavedAt = record.savedAt
            let items = record.items.map { c in
                TrashDTO(
                    id: c.id,
                    title: c.title,
                    description: c.description,
                    category: c.category ?? "",
                    condition: c.condition ?? "",
                    mode: c.mode ?? "",
                    city: c.city ?? "",
                    lat: c.lat,
                    lon: c.lon,
                    approxLat: c.approxLat,
                    approxLon: c.approxLon,
                    photoURLs: c.photoURLs.compactMap(URL.init(string:)),
                    createdAt: c.createdAt,
                    expiresAt: c.expiresAt,
                    status: c.status,
                    reservedUntil: c.reservedUntil,
                    reservedBy: c.reservedBy,
                    uploader: c.uploader,
                    pickedUpAt: c.pickedUpAt
                )
            }
            return (items, record.savedAt)
        } catch {
            return nil
        }
    }

    func currentAgeMs() -> Int? {
        guard let saved = lastSavedAt else { return nil }
        return Int(Date().timeIntervalSince(saved) * 1000)
    }

    func clear() {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                DLog("[FEED cache] clear error=\(error.localizedDescription)")
            }
        }
        lastSavedAt = nil
    }
}
