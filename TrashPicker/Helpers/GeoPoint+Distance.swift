import Foundation
import CoreLocation

extension GeoPoint {
    /// Convenience initializer that safely wraps an optional coordinate.
    init?(coordinate: CLLocationCoordinate2D?) {
        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        self.init(lng: coordinate.longitude, lat: coordinate.latitude)
    }

    /// Returns a Core Location coordinate if the stored lat/lng are valid.
    var coordinateValue: CLLocationCoordinate2D? {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return coordinate
    }

    /// Human-friendly "lat, lng" text with 4 decimal precision.
    var coordinateDisplayText: String {
        String(format: "%.4f, %.4f", lat, lng)
    }

    /// Distance from the latest known user location, if permission allows.
    func distanceFromUser(using locationService: LocationService = .shared) -> CLLocationDistance? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        let status = CLLocationManager.authorizationStatus()
        guard status.isAuthorizedForDistance else { return nil }
        guard let userLocation = locationService.lastKnownFromSystem() else { return nil }
        guard let coordinate = coordinateValue else { return nil }
        let pickupLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return userLocation.distance(from: pickupLocation)
    }

    /// Returns a localized "X.X km" string when the distance can be computed.
    func formattedDistanceFromUser(locale: Locale = .current) -> String? {
        guard let meters = distanceFromUser(), meters.isFinite else { return nil }
        let kilometers = meters / 1_000
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        guard let formatted = formatter.string(from: NSNumber(value: kilometers)) else { return nil }
        return "\(formatted) km"
    }
}

private extension CLAuthorizationStatus {
    var isAuthorizedForDistance: Bool {
        switch self {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }
}
