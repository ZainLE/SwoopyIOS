import Foundation
import CoreLocation

enum DistanceFormatterHelper {
    private static let formatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = [.providedUnit]
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.numberFormatter.minimumFractionDigits = 1
        return formatter
    }()

    static func formattedDistance(from user: CLLocationCoordinate2D, to post: CLLocationCoordinate2D) -> String {
        let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let postLocation = CLLocation(latitude: post.latitude, longitude: post.longitude)
        let meters = userLocation.distance(from: postLocation)
        return formattedDistance(fromMeters: meters)
    }

    static func formattedDistance(fromMeters meters: CLLocationDistance) -> String {
        guard meters.isFinite else { return "" }
        if meters < 1_000 {
            let rounded = max(1, Int(meters.rounded()))
            return "\(rounded) m away"
        }
        let measurement = Measurement(value: meters / 1_000, unit: UnitLength.kilometers)
        return formatter.string(from: measurement) + " away"
    }
}
