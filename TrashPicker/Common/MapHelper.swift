import MapKit

enum MapHelper {
    static func openAppleMaps(coordinate: CLLocationCoordinate2D, name: String? = nil) {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name ?? "Pickup location"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    static func openAppleMaps(lat: Double, lng: Double, name: String? = nil) {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        openAppleMaps(coordinate: coordinate, name: name)
    }
}
