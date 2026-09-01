import AppKit
import MapKit
import SwiftUI

/// One pin on the map. `label` becomes the marker glyph (e.g. "1"); nil shows a
/// location icon.
struct MapPin: Identifiable, Equatable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D
    var label: String?

    static func == (a: MapPin, b: MapPin) -> Bool {
        a.id == b.id && a.label == b.label
            && abs(a.coordinate.latitude - b.coordinate.latitude) < 1e-9
            && abs(a.coordinate.longitude - b.coordinate.longitude) < 1e-9
    }
}

/// An `MKMapView` wrapper for picking coordinates. SwiftUI's `Map` on macOS
/// doesn't reliably deliver taps, so this uses `NSClickGestureRecognizer`.
/// Supports one draggable pin (fixed mode) or many + a connecting line (route).
struct MapPicker: NSViewRepresentable {
    var pins: [MapPin]
    var route: [CLLocationCoordinate2D] = []
    var recenterToken: Int = 0
    /// Click on empty map → new coordinate.
    var onClick: (CLLocationCoordinate2D) -> Void
    /// A pin was dragged to a new coordinate.
    var onDragPin: (UUID, CLLocationCoordinate2D) -> Void = { _, _ in }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        let click = NSClickGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        map.addGestureRecognizer(click)
        context.coordinator.mapView = map
        context.coordinator.sync(pins: pins, route: route)
        if let first = pins.first {
            map.setRegion(Coordinator.region(around: first.coordinate), animated: false)
        }
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.onClick = onClick
        c.onDragPin = onDragPin
        c.sync(pins: pins, route: route)

        if c.lastRecenterToken != recenterToken {
            c.lastRecenterToken = recenterToken
            c.recenter(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class WaypointAnnotation: NSObject, MKAnnotation {
        let id: UUID
        @objc dynamic var coordinate: CLLocationCoordinate2D
        var glyph: String?
        init(id: UUID, coordinate: CLLocationCoordinate2D, glyph: String?) {
            self.id = id; self.coordinate = coordinate; self.glyph = glyph
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var onClick: ((CLLocationCoordinate2D) -> Void)?
        var onDragPin: ((UUID, CLLocationCoordinate2D) -> Void)?
        var lastRecenterToken = Int.min

        private var annotations: [UUID: WaypointAnnotation] = [:]
        private var polyline: MKPolyline?
        private var dragging: Set<UUID> = []

        static func region(around c: CLLocationCoordinate2D) -> MKCoordinateRegion {
            MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = mapView else { return }
            let point = gesture.location(in: map)
            // Ignore clicks that land on a marker (that's a drag/selection).
            if map.subviews.contains(where: { ($0 as? MKAnnotationView)?.frame.contains(point) == true }) {
                return
            }
            onClick?(map.convert(point, toCoordinateFrom: map))
        }

        func sync(pins: [MapPin], route: [CLLocationCoordinate2D]) {
            guard let map = mapView else { return }

            let wanted = Set(pins.map(\.id))
            for (id, ann) in annotations where !wanted.contains(id) {
                map.removeAnnotation(ann)
                annotations[id] = nil
            }
            for pin in pins {
                if let ann = annotations[pin.id] {
                    if !dragging.contains(pin.id),
                       abs(ann.coordinate.latitude - pin.coordinate.latitude) > 1e-9
                        || abs(ann.coordinate.longitude - pin.coordinate.longitude) > 1e-9 {
                        ann.coordinate = pin.coordinate
                    }
                    if ann.glyph != pin.label {
                        ann.glyph = pin.label
                        if let v = map.view(for: ann) as? MKMarkerAnnotationView {
                            v.glyphText = pin.label
                        }
                    }
                } else {
                    let ann = WaypointAnnotation(id: pin.id, coordinate: pin.coordinate, glyph: pin.label)
                    annotations[pin.id] = ann
                    map.addAnnotation(ann)
                }
            }

            if let existing = polyline { map.removeOverlay(existing) }
            polyline = nil
            if route.count >= 2 {
                let line = MKPolyline(coordinates: route, count: route.count)
                polyline = line
                map.addOverlay(line, level: .aboveRoads)
            }
        }

        func recenter(animated: Bool) {
            guard let map = mapView else { return }
            let coords = annotations.values.map(\.coordinate)
            if coords.count > 1 {
                let rect = coords.reduce(MKMapRect.null) { acc, c in
                    acc.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 0.01, height: 0.01)))
                }
                map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60), animated: animated)
            } else if let c = coords.first {
                map.setRegion(Self.region(around: c), animated: animated)
            }
        }

        // Rendering

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = .controlAccentColor
            r.lineWidth = 3
            r.lineDashPattern = nil
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let wp = annotation as? WaypointAnnotation else { return nil }
            let id = "wp"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: wp, reuseIdentifier: id)
            view.annotation = wp
            view.markerTintColor = .systemRed
            view.glyphText = wp.glyph
            if wp.glyph == nil {
                view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
            }
            view.isDraggable = true
            view.animatesWhenAdded = false
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            guard let wp = view.annotation as? WaypointAnnotation else { return }
            switch newState {
            case .starting:
                dragging.insert(wp.id)
            case .ending, .canceling:
                view.dragState = .none
                dragging.remove(wp.id)
                onDragPin?(wp.id, wp.coordinate)
            default:
                break
            }
        }
    }
}
