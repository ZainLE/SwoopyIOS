import Foundation
import CoreLocation

struct FeedQueryKey: Hashable {
    private let latKey: Int
    private let lngKey: Int
    private let radiusKey: Int
    private let limit: Int
    private let excludeSelf: Bool
    private let mode: String?
    private let category: String?
    
    init(
        coordinate: CLLocationCoordinate2D,
        radiusKm: Double,
        limit: Int,
        excludeSelf: Bool,
        mode: String?,
        category: String?
    ) {
        func scaled(_ value: Double) -> Int {
            Int((value * 100_000).rounded())
        }
        latKey = scaled(coordinate.latitude)
        lngKey = scaled(coordinate.longitude)
        radiusKey = Int((radiusKm * 1000).rounded())
        self.limit = limit
        self.excludeSelf = excludeSelf
        self.mode = mode
        self.category = category
    }
    
    var debugDescription: String {
        "[lat=\(latKey) lng=\(lngKey) r=\(radiusKey)m limit=\(limit) exclude=\(excludeSelf) mode=\(mode ?? "nil")]"
    }
}

actor FeedCoalescer {
    private var tasks: [FeedQueryKey: Task<[Post], Error>] = [:]
    
    func runOnce(
        key: FeedQueryKey,
        operation: @escaping () async throws -> [Post]
    ) async throws -> [Post] {
        if let existing = tasks[key] {
            #if DEBUG
            DLog("[FEED gate] coalesced key=\(key.debugDescription)")
            #endif
            return try await existing.value
        }
        
        let task = Task<[Post], Error> {
            try await operation()
        }
        tasks[key] = task
        do {
            let result = try await task.value
            tasks[key] = nil
            return result
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}
