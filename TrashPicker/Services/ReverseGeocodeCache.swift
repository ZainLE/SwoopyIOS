import Foundation
import CoreLocation

actor ReverseGeocoder {
    static let shared = ReverseGeocoder()

    struct PlacemarkSummary: Codable {
        let street: String?
        let number: String?
        let city: String?
    }

    private struct Entry: Codable {
        let summary: PlacemarkSummary
        let updatedAt: Date
    }

    private var storage: [String: Entry] = [:]
    private var inflight: [String: Task<PlacemarkSummary?, Never>] = [:]
    private let ttl: TimeInterval = 60 * 60 * 24 // 24 hours
    private let fileURL: URL

    init() {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        fileURL = cachesURL.appendingPathComponent("reverse-geocoder-cache.json")
        load()
    }

    func address(for coordinate: CLLocationCoordinate2D, cacheKey customKey: String? = nil) async -> String {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return "" }
        let key = customKey ?? Self.cacheKey(for: coordinate)
        if let entry = storage[key], Date().timeIntervalSince(entry.updatedAt) < ttl {
            return buildAddress(from: entry.summary)
        }

        if let task = inflight[key] {
            let summary = await task.value
            return buildAddress(from: summary)
        }

        let task = Task<PlacemarkSummary?, Never> {
            await Self.reverseGeocode(coordinate: coordinate)
        }
        inflight[key] = task
        let summary = await task.value
        inflight[key] = nil

        if let summary {
            storage[key] = Entry(summary: summary, updatedAt: Date())
            save()
        }

        return buildAddress(from: summary)
    }

    func clear() {
        storage.removeAll()
        inflight.removeAll()
        save()
    }

    // MARK: - Helpers

    private func buildAddress(from summary: PlacemarkSummary?) -> String {
        guard let summary else { return "" }
        var streetParts: [String] = []
        if let number = summary.number, !number.isEmpty {
            streetParts.append(number)
        }
        if let street = summary.street, !street.isEmpty {
            streetParts.append(street)
        }
        let streetLine = streetParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var components: [String] = []
        if !streetLine.isEmpty {
            components.append(streetLine)
        }
        if let city = summary.city, !city.isEmpty {
            components.append(city)
        }
        if components.isEmpty {
            return "Nearby"
        }
        return components.joined(separator: ", ")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let now = Date()
            storage = decoded.filter { now.timeIntervalSince($0.value.updatedAt) < ttl }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = String(format: "%.5f", coordinate.latitude)
        let lng = String(format: "%.5f", coordinate.longitude)
        return "\(lat),\(lng)"
    }

    private static func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> PlacemarkSummary? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current) { placemarks, error in
                guard error == nil, let placemark = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let summary = PlacemarkSummary(
                    street: placemark.thoroughfare ?? placemark.subLocality ?? placemark.name,
                    number: placemark.subThoroughfare,
                    city: placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
                )
                continuation.resume(returning: summary)
            }
        }
    }
}
