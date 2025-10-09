import SwiftUI
import MapKit

/// - Shows the user location
/// - Applies region updates from an `MKCoordinateRegion` binding efficiently
/// - Disables expensive gestures (pitch/rotate)
/// - Logs map lifecycle and updates
struct CheapMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var forceUpdate: Bool = false  // Set to true for user-initiated recenter to bypass guards

    // Internal state cache (per-instance) to avoid redundant region sets
    private final class StateBox {
        var lastAppliedRegion: MKCoordinateRegion?
        var lastForceUpdate: Bool = false
    }
    private let box = StateBox()

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false

        // Log
        print("[MAP] makeUIView: userLocation=\(mapView.showsUserLocation) rotate=\(mapView.isRotateEnabled) pitch=\(mapView.isPitchEnabled)")
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Apply region from binding efficiently
        let fitted = uiView.regionThatFits(region)
        
        // CRITICAL: If forceUpdate is true (user-initiated recenter), bypass the guard
        // This ensures large jumps (continent → city) always apply
        let shouldApply = forceUpdate || shouldApplyRegion(fitted, current: uiView.region, last: box.lastAppliedRegion)
        
        if shouldApply {
            uiView.setRegion(fitted, animated: false)
            box.lastAppliedRegion = fitted
            box.lastForceUpdate = forceUpdate
            let reason = forceUpdate ? " (forced)" : ""
            print("[MAP] updateUIView: applied region center=(\(fitted.center.latitude),\(fitted.center.longitude)) span=(\(fitted.span.latitudeDelta),\(fitted.span.longitudeDelta))\(reason)")
        } else {
            print("[MAP] updateUIView: skipped region (no meaningful change)")
        }

        // If in the future we pass annotations through this view, refresh here.
        // For now, just log current annotation count.
        print("[MAP] updateUIView: annotations=#\(uiView.annotations.count)")
    }

    private func shouldApplyRegion(_ new: MKCoordinateRegion, current: MKCoordinateRegion, last: MKCoordinateRegion?) -> Bool {
        // Avoid spamming setRegion for tiny numeric differences
        func nearlyEqual(_ a: CLLocationDegrees, _ b: CLLocationDegrees, eps: CLLocationDegrees = 1e-6) -> Bool {
            abs(a - b) < eps
        }
        let ref = last ?? current
        let sameCenter = nearlyEqual(new.center.latitude, ref.center.latitude) && nearlyEqual(new.center.longitude, ref.center.longitude)
        let sameSpan = nearlyEqual(new.span.latitudeDelta, ref.span.latitudeDelta) && nearlyEqual(new.span.longitudeDelta, ref.span.longitudeDelta)
        return !(sameCenter && sameSpan)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let parent: CheapMapView

        init(_ parent: CheapMapView) { self.parent = parent }

        func mapViewRegionDidChange(_ mapView: MKMapView, animated: Bool) {
            let c = mapView.region.center, s = mapView.region.span
            print("[MAP] mapViewRegionDidChange: center=(\(c.latitude),\(c.longitude)) span=(\(s.latitudeDelta),\(s.longitudeDelta)) animated=\(animated)")
        }
    }
}

