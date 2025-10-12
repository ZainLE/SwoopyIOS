import SwiftUI
import MapKit
import UIKit

struct CheapMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var forceUpdate: Bool
    var annotations: [StreetPinAnnotation]
    var selectedAnnotationID: Binding<UUID?>
    var calloutAnchor: Binding<CGPoint?>
    var onAnnotationTapped: @Sendable (UUID) -> Void
    var onAnnotationDeselected: @Sendable () -> Void
    var onMapTap: @Sendable () -> Void
    var onRegionWillChange: @Sendable (Bool) -> Void
    var onRegionDidChange: @Sendable (MKCoordinateRegion, Bool) -> Void

    private final class StateBox {
        var lastAppliedRegion: MKCoordinateRegion?
        var lastForceUpdate = false
    }
    private let box = StateBox()

    init(
        region: Binding<MKCoordinateRegion>,
        forceUpdate: Bool = false,
        annotations: [StreetPinAnnotation] = [],
        selectedAnnotationID: Binding<UUID?>,
        calloutAnchor: Binding<CGPoint?>,
        onAnnotationTapped: @escaping @Sendable (UUID) -> Void = { _ in },
        onAnnotationDeselected: @escaping @Sendable () -> Void = {},
        onMapTap: @escaping @Sendable () -> Void = {},
        onRegionWillChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onRegionDidChange: @escaping @Sendable (MKCoordinateRegion, Bool) -> Void = { _, _ in }
    ) {
        _region = region
        self.forceUpdate = forceUpdate
        self.annotations = annotations
        self.selectedAnnotationID = selectedAnnotationID
        self.calloutAnchor = calloutAnchor
        self.onAnnotationTapped = onAnnotationTapped
        self.onAnnotationDeselected = onAnnotationDeselected
        self.onMapTap = onMapTap
        self.onRegionWillChange = onRegionWillChange
        self.onRegionDidChange = onRegionDidChange
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.register(StreetPostAnnotationView.self, forAnnotationViewWithReuseIdentifier: StreetPostAnnotationView.reuseIdentifier)

        context.coordinator.mapView = mapView
        context.coordinator.attachTapRecognizer(to: mapView)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.mapView = uiView
        context.coordinator.parent = self
        context.coordinator.updateAnnotations(on: uiView, models: annotations)

        let fitted = uiView.regionThatFits(region)
        let shouldApply = forceUpdate || shouldApplyRegion(fitted, current: uiView.region)
        if shouldApply {
            uiView.setRegion(fitted, animated: false)
            box.lastAppliedRegion = fitted
            box.lastForceUpdate = forceUpdate
        }

        context.coordinator.syncSelection(on: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func shouldApplyRegion(_ new: MKCoordinateRegion, current: MKCoordinateRegion) -> Bool {
        func nearlyEqual(_ a: CLLocationDegrees, _ b: CLLocationDegrees, eps: CLLocationDegrees = 1e-6) -> Bool {
            abs(a - b) < eps
        }
        let reference = box.lastAppliedRegion ?? current
        let sameCenter = nearlyEqual(new.center.latitude, reference.center.latitude) &&
            nearlyEqual(new.center.longitude, reference.center.longitude)
        let sameSpan = nearlyEqual(new.span.latitudeDelta, reference.span.latitudeDelta) &&
            nearlyEqual(new.span.longitudeDelta, reference.span.longitudeDelta)
        return !(sameCenter && sameSpan && box.lastForceUpdate == forceUpdate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: CheapMapView
        weak var mapView: MKMapView?
        private var mapTapRecognizer: UITapGestureRecognizer?
        private var lastRegionChangeWasUserInitiated = false
        private var selectedAnnotation: StreetPostMKAnnotation?

        init(_ parent: CheapMapView) {
            self.parent = parent
        }

        func attachTapRecognizer(to mapView: MKMapView) {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(handleMapTap(_:)))
            gesture.delegate = self
            mapView.addGestureRecognizer(gesture)
            mapTapRecognizer = gesture
        }

        func updateAnnotations(on mapView: MKMapView, models: [StreetPinAnnotation]) {
            let existing = mapView.annotations.compactMap { $0 as? StreetPostMKAnnotation }
            let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.model.id, $0) })
            let newMap = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })

            let toRemove = existing.filter { newMap[$0.model.id] == nil }
            if !toRemove.isEmpty {
                mapView.removeAnnotations(toRemove)
            }

            for annotation in existing {
                if let updated = newMap[annotation.model.id] {
                    annotation.update(with: updated)
                }
            }

            let toAdd = models.filter { existingMap[$0.id] == nil }.map { StreetPostMKAnnotation(model: $0) }
            if !toAdd.isEmpty {
                mapView.addAnnotations(toAdd)
            }
            if let selected = selectedAnnotation, models.contains(where: { $0.id == selected.model.id }) == false {
                selectedAnnotation = nil
            }
        }

        func syncSelection(on mapView: MKMapView) {
            let selectedId = parent.selectedAnnotationID.wrappedValue
            let selectedAnnotation = mapView.selectedAnnotations.first { annotation in
                guard let streetAnnotation = annotation as? StreetPostMKAnnotation else { return false }
                return streetAnnotation.model.id == selectedId
            } as? StreetPostMKAnnotation

            if let selectedId,
               selectedAnnotation == nil,
               let target = mapView.annotations.compactMap({ $0 as? StreetPostMKAnnotation }).first(where: { $0.model.id == selectedId }) {
                mapView.selectAnnotation(target, animated: true)
            } else if selectedId == nil, let current = selectedAnnotation {
                mapView.deselectAnnotation(current, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let streetAnnotation = annotation as? StreetPostMKAnnotation else {
                return nil
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: StreetPostAnnotationView.reuseIdentifier, for: streetAnnotation)
            view.annotation = streetAnnotation
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? StreetPostMKAnnotation else { return }
            selectedAnnotation = annotation
            let anchor = mapView.convert(annotation.coordinate, toPointTo: mapView)
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.selectedAnnotationID.wrappedValue = annotation.model.id
                parent.calloutAnchor.wrappedValue = anchor
                assert(Thread.isMainThread)
                parent.onAnnotationTapped(annotation.model.id)
                #if DEBUG
                print("[CALLOUT] anchor screenPoint=(\(String(format: "%.1f", anchor.x)),\(String(format: "%.1f", anchor.y))) id=\(annotation.model.rawId)")
                #endif
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is StreetPostMKAnnotation else { return }
            selectedAnnotation = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.selectedAnnotationID.wrappedValue = nil
                parent.calloutAnchor.wrappedValue = nil
                assert(Thread.isMainThread)
                parent.onAnnotationDeselected()
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            lastRegionChangeWasUserInitiated = mapViewWasInteractedWith(mapView)
            let isUserGesture = lastRegionChangeWasUserInitiated
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.onRegionWillChange(isUserGesture)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            let isUserGesture = lastRegionChangeWasUserInitiated
            lastRegionChangeWasUserInitiated = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.region = region
                parent.onRegionDidChange(region, isUserGesture)
                if let selected = selectedAnnotation {
                    let point = mapView.convert(selected.coordinate, toPointTo: mapView)
                    parent.calloutAnchor.wrappedValue = point
                    assert(Thread.isMainThread)
                    #if DEBUG
                    print("[CALLOUT] anchor screenPoint=(\(String(format: "%.1f", point.x)),\(String(format: "%.1f", point.y))) id=\(selected.model.rawId)")
                    #endif
                } else {
                    parent.calloutAnchor.wrappedValue = nil
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if touch.view is UIControl { return false }
            if findAnnotationView(from: touch.view) != nil { return false }
            return true
        }

        @objc
        private func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView else { return }
            let location = gesture.location(in: mapView)
            if let hitView = mapView.hitTest(location, with: nil),
               findAnnotationView(from: hitView) != nil {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.onMapTap()
            }
        }

        private func findAnnotationView(from view: UIView?) -> MKAnnotationView? {
            var current = view
            while let node = current {
                if let annotationView = node as? MKAnnotationView {
                    return annotationView
                }
                current = node.superview
            }
            return nil
        }

        private func mapViewWasInteractedWith(_ mapView: MKMapView) -> Bool {
            return mapView.gestureRecognizers?.contains { recognizer in
                switch recognizer.state {
                case .began, .changed:
                    return true
                default:
                    return false
                }
            } ?? false
        }
    }
}

private final class StreetPostMKAnnotation: NSObject, MKAnnotation {
    private(set) var model: StreetPinAnnotation
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(model: StreetPinAnnotation) {
        self.model = model
        self.coordinate = model.coordinate
        super.init()
    }

    func update(with model: StreetPinAnnotation) {
        self.model = model
        if coordinate.latitude != model.coordinate.latitude || coordinate.longitude != model.coordinate.longitude {
            coordinate = model.coordinate
        }
    }

    var title: String? { model.title }
}

private final class StreetPostAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "street.pin"
    private let normalScale: CGFloat = 1.0
    private let selectedScale: CGFloat = 1.1

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        configure()
    }

    private func configure() {
        canShowCallout = false
        clusteringIdentifier = nil
        image = Self.pinImage
        displayPriority = .required
        centerOffset = CGPoint(x: 0, y: -Self.pinImage.size.height / 2)
        transform = CGAffineTransform(scaleX: normalScale, y: normalScale)
    }

    override var annotation: MKAnnotation? {
        didSet {
            image = Self.pinImage
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        let updates = {
            let scale = selected ? self.selectedScale : self.normalScale
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.layer.zPosition = selected ? 10 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: updates, completion: nil)
        } else {
            updates()
        }
    }

    private static let pinImage: UIImage = {
        let size = CGSize(width: 30, height: 38)
        let circleDiameter: CGFloat = 24
        let circleRect = CGRect(x: (size.width - circleDiameter) / 2, y: 0, width: circleDiameter, height: circleDiameter)
        let tailPath = UIBezierPath()
        let tailTopY = circleRect.maxY - 2
        tailPath.move(to: CGPoint(x: size.width / 2, y: size.height))
        tailPath.addLine(to: CGPoint(x: circleRect.maxX - 4, y: tailTopY))
        tailPath.addLine(to: CGPoint(x: circleRect.minX + 4, y: tailTopY))
        tailPath.close()

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let brand = UIColor(AppTheme.ColorToken.brandDark)
            brand.setFill()
            UIBezierPath(ovalIn: circleRect).fill()
            tailPath.fill()

            if let glyph = UIImage(systemName: "paperplane.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let targetSize = CGSize(width: 14, height: 14)
                let glyphOrigin = CGPoint(
                    x: circleRect.midX - targetSize.width / 2,
                    y: circleRect.midY - targetSize.height / 2
                )
                glyph.draw(in: CGRect(origin: glyphOrigin, size: targetSize))
            }
        }
        return image
    }()
}
