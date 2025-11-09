import MapKit
import UIKit

enum MapHelper {
    static func openAppleMaps(coordinate: CLLocationCoordinate2D, name: String? = nil) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name ?? "Pickup location"
        let opened = item.openInMaps(
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
        if !opened {
            openUsingURLFallback(coordinate: coordinate)
        }
    }

    static func openAppleMaps(lat: Double, lng: Double, name: String? = nil) {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        openAppleMaps(coordinate: coordinate, name: name)
    }

    private static func openUsingURLFallback(coordinate: CLLocationCoordinate2D) {
        let urlString = String(
            format: "maps://?daddr=%.6f,%.6f",
            coordinate.latitude,
            coordinate.longitude
        )
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
