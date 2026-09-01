import CoreLocation
import Foundation
import MapKit
import Observation
import SpooferCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Tooling
    private(set) var pmd: Pymobiledevice3?
    private(set) var setupError: String?

    // Devices
    private(set) var devices: [Device] = []
    var selectedUDID: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    // Spoof configuration
    enum EditMode: String, CaseIterable, Identifiable { case point = "Fixed point", route = "Route"; var id: String { rawValue } }
    var editMode: EditMode = .point

    var transport: Transport = .native
    var latitudeText: String = "37.3349"
    var longitudeText: String = "-122.0090"
    /// The coordinates the running session was last started with (fixed mode).
    private(set) var activeCoordinate: (lat: Double, lon: Double)?

    // Route mode
    struct Waypoint: Identifiable, Equatable {
        let id = UUID()
        var latitude: Double
        var longitude: Double
    }
    var waypoints: [Waypoint] = []
    var routeLoop: Bool = false

    /// How the trip is timed: a total time, or a target speed.
    enum RoutePacing: String, CaseIterable, Identifiable { case time = "Time", speed = "Speed"; var id: String { rawValue } }
    var routePacing: RoutePacing = .time
    var routeHoursText = "0"
    var routeMinutesText = "2"
    var routeSecondsText = "0"
    var routeSpeedText = "30"   // km/h
    /// Signature of the route the running session was started with.
    private var activeRouteSignature: String?
    let fixedPinID = UUID()

    /// Human-readable name of the currently-entered coordinate (reverse geocoded).
    private(set) var placeName: String?
    private let geocoder = CLGeocoder()
    private var geocodeTask: Task<Void, Never>?

    // Session
    private(set) var sessionState: SpoofState = .idle
    private(set) var logLines: [String] = []
    /// Exposed (thread-safe, `@unchecked Sendable`) so the app-terminate hook can
    /// tear it down from a background queue.
    private(set) var activeSession: SpoofSession?
    private var refreshTask: Task<Void, Never>?

    /// Optional automation via environment: `SPOOF_UDID`, `SPOOF_START="lat,lon"`.
    private let autoStart: (lat: Double, lon: Double)?
    private var didAutoStart = false
    private var startupSweepDone = false

    private init() {
        // Keep this trivial: it runs inside dispatch_once during the first
        // SwiftUI body evaluation. No blocking / run-loop-pumping work here.
        let env = ProcessInfo.processInfo.environment
        if let s = env["SPOOF_START"], let c = Coordinate.parse(s) {
            autoStart = (c.latitude, c.longitude)
        } else {
            autoStart = nil
        }
        resolveTool()
        if let udid = env["SPOOF_UDID"] { selectedUDID = udid }
        if let a = autoStart {
            latitudeText = String(a.lat)
            longitudeText = String(a.lon)
        }
    }

    /// Called from `applicationDidFinishLaunching` (off the main thread).
    func completeStartupSweep(reaped: Int) {
        startupSweepDone = true
        if reaped > 0 {
            appendLog("reaped \(reaped) stray pymobiledevice3 process(es) from a previous run")
        }
    }

    // MARK: - Tooling

    func resolveTool() {
        do {
            pmd = try Pymobiledevice3.resolve()
            setupError = nil
        } catch {
            pmd = nil
            setupError = "\(error)"
        }
    }

    // MARK: - Device discovery

    var selectedDevice: Device? {
        devices.first { $0.udid == selectedUDID }
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard let pmd else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        do {
            let list = try await pmd.listDevicesAsync()
            devices = list
            if selectedUDID == nil || !list.contains(where: { $0.udid == selectedUDID }) {
                selectedUDID = list.first?.udid
            }
        } catch {
            appendLog("device refresh failed: \(error)")
        }

        if autoStart != nil, startupSweepDone, !didAutoStart, !isSpoofing, selectedDevice != nil {
            didAutoStart = true
            startSpoof()
        }
    }

    // MARK: - Spoof control

    /// Something is running (or a finished route is still held on the device).
    var hasActiveSession: Bool { activeSession != nil }
    var isSpoofing: Bool { sessionState.isRunning }

    /// True when the fixed-point fields differ from what the running session uses.
    var hasPendingCoordinateChange: Bool {
        guard let active = activeCoordinate, let entered = enteredCoordinate else { return false }
        return abs(active.lat - entered.lat) > 1e-9 || abs(active.lon - entered.lon) > 1e-9
    }

    /// True when the route was edited after the running session started.
    var hasPendingRouteChange: Bool {
        guard let sig = activeRouteSignature else { return false }
        return sig != routeSignature
    }

    var enteredCoordinate: (lat: Double, lon: Double)? {
        guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitudeText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (lat, lon)
    }

    func setCoordinate(lat: Double, lon: Double) {
        latitudeText = trimmed(lat)
        longitudeText = trimmed(lon)
        scheduleGeocode()
        // While spoofing, the pinned "Move to new coordinates" button commits it
        // (see hasPendingCoordinateChange) — don't restart the tunnel on every tap.
    }

    // MARK: - Route editing

    var routeCoordinates: [(lat: Double, lon: Double)] {
        waypoints.map { ($0.latitude, $0.longitude) }
    }
    var routeDistanceMeters: Double { RouteBuilder.totalDistance(routeCoordinates) }

    /// Total trip time, derived from whichever pacing the user chose.
    var routeDuration: TimeInterval? {
        switch routePacing {
        case .time:
            let h = Double(routeHoursText.trimmingCharacters(in: .whitespaces)) ?? 0
            let m = Double(routeMinutesText.trimmingCharacters(in: .whitespaces)) ?? 0
            let s = Double(routeSecondsText.trimmingCharacters(in: .whitespaces)) ?? 0
            let total = h * 3600 + m * 60 + s
            return total > 0 ? total : nil
        case .speed:
            guard let kmh = Double(routeSpeedText.trimmingCharacters(in: .whitespaces)),
                  kmh > 0, routeDistanceMeters > 0 else { return nil }
            return routeDistanceMeters / (kmh / 3.6)
        }
    }

    /// Target/effective speed in km/h.
    var routeSpeedKmh: Double? {
        switch routePacing {
        case .speed:
            return Double(routeSpeedText.trimmingCharacters(in: .whitespaces))
        case .time:
            guard let d = routeDuration, routeDistanceMeters > 0 else { return nil }
            return routeDistanceMeters / d * 3.6
        }
    }

    var routeSummary: String {
        let km = routeDistanceMeters / 1000
        var s = String(format: "%.2f km", km)
        if let dur = routeDuration { s += " · \(Self.durationLabel(dur))" }
        if let v = routeSpeedKmh { s += String(format: " · %.0f km/h", v) }
        return s
    }
    private var routeSignature: String {
        waypoints.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
            .joined(separator: ";")
            + "|\(routePacing.rawValue)|\(routeHoursText):\(routeMinutesText):\(routeSecondsText)|\(routeSpeedText)|\(routeLoop)"
    }

    func addWaypoint(lat: Double, lon: Double) {
        waypoints.append(Waypoint(latitude: lat, longitude: lon))
    }
    func moveWaypoint(id: UUID, lat: Double, lon: Double) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[i].latitude = lat
        waypoints[i].longitude = lon
    }
    func removeWaypoint(id: UUID) {
        waypoints.removeAll { $0.id == id }
    }
    func reorderWaypoints(from offsets: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: offsets, toOffset: destination)
    }
    /// Insert a point halfway between waypoint `id` and the next one (or the
    /// previous one, if `id` is last).
    func insertMidpointAfter(id: UUID) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let a = waypoints[i]
        let b = i + 1 < waypoints.count ? waypoints[i + 1] : (i > 0 ? waypoints[i - 1] : a)
        let mid = Waypoint(latitude: (a.latitude + b.latitude) / 2,
                           longitude: (a.longitude + b.longitude) / 2)
        waypoints.insert(mid, at: min(i + 1, waypoints.count))
    }
    func clearWaypoints() { waypoints.removeAll() }

    // MARK: - Map interaction (routes to the right handler for the current mode)

    func handleMapClick(lat: Double, lon: Double) {
        switch editMode {
        case .point: setCoordinate(lat: lat, lon: lon)
        case .route: addWaypoint(lat: lat, lon: lon)
        }
    }
    func handleMapPinDrag(id: UUID, lat: Double, lon: Double) {
        switch editMode {
        case .point: setCoordinate(lat: lat, lon: lon)
        case .route: moveWaypoint(id: id, lat: lat, lon: lon)
        }
    }

    var mapPins: [MapPin] {
        switch editMode {
        case .point:
            guard let c = enteredCoordinate else { return [] }
            return [MapPin(id: fixedPinID,
                           coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon),
                           label: nil)]
        case .route:
            return waypoints.enumerated().map { index, w in
                MapPin(id: w.id,
                       coordinate: CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude),
                       label: "\(index + 1)")
            }
        }
    }

    var mapRoute: [CLLocationCoordinate2D] {
        guard editMode == .route else { return [] }
        return waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Reverse-geocode the entered coordinate into a place name (debounced).
    func scheduleGeocode() {
        geocodeTask?.cancel()
        guard let c = enteredCoordinate else { placeName = nil; return }
        geocodeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reverseGeocode(lat: c.lat, lon: c.lon)
        }
    }

    private func reverseGeocode(lat: Double, lon: Double) async {
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: lat, longitude: lon))
            guard !Task.isCancelled, let p = placemarks.first else { return }
            var seen = Set<String>()
            let parts = [p.name, p.locality, p.administrativeArea, p.country]
                .compactMap { $0 }
                .filter { seen.insert($0).inserted }
            placeName = parts.prefix(3).joined(separator: ", ")
        } catch {
            placeName = nil   // over water, no network, or rate-limited
        }
    }

    func applyPreset(_ preset: NamedLocation) {
        setCoordinate(lat: preset.latitude, lon: preset.longitude)
    }

    func pasteCoordinate(_ text: String) {
        if let c = Coordinate.parse(text) {
            setCoordinate(lat: c.latitude, lon: c.longitude)
        }
    }

    func toggleSpoof() {
        if hasActiveSession {
            stopSpoof()
        } else if editMode == .point {
            startSpoof()
        } else {
            startRoute()
        }
    }

    private func makeSession(_ device: Device) -> SpoofSession? {
        guard let pmd else { appendLog("pymobiledevice3 not found"); return nil }
        let s = SpoofSession(pmd: pmd, device: device, transport: transport)
        s.onLog = { line in Task { @MainActor in AppModel.shared.appendLog(line) } }
        s.onStateChange = { state in
            Task { @MainActor in
                let m = AppModel.shared
                m.sessionState = state
                if case .idle = state { m.activeSession = nil }
            }
        }
        return s
    }

    func startSpoof() {
        guard let device = selectedDevice else { appendLog("select a device first"); return }
        guard let c = enteredCoordinate else { appendLog("enter valid coordinates"); return }
        do { try Coordinate.validate(latitude: c.lat, longitude: c.lon) }
        catch { appendLog("\(error)"); return }
        guard let s = makeSession(device) else { return }

        logLines.removeAll()
        activeSession = s
        activeCoordinate = c
        activeRouteSignature = nil
        sessionState = .preparing
        s.start(.fixed(latitude: c.lat, longitude: c.lon))
    }

    /// Push the currently-entered coordinates to the running fixed-point session.
    func applyCoordinate() {
        guard hasActiveSession, let s = activeSession, let c = enteredCoordinate else { return }
        do { try Coordinate.validate(latitude: c.lat, longitude: c.lon) } catch { appendLog("\(error)"); return }
        activeCoordinate = c
        s.start(.fixed(latitude: c.lat, longitude: c.lon))
    }

    func startRoute() {
        guard let device = selectedDevice else { appendLog("select a device first"); return }
        guard waypoints.count >= 2 else { appendLog("add at least 2 waypoints (click the map)"); return }
        guard let duration = routeDuration else { appendLog("enter a valid duration in seconds"); return }
        guard let s = makeSession(device) else { return }

        let url: URL
        do {
            url = try RouteBuilder.writeGPX(waypoints: routeCoordinates, duration: duration)
        } catch {
            appendLog("\(error)")
            return
        }

        logLines.removeAll()
        activeSession = s
        activeCoordinate = nil
        activeRouteSignature = routeSignature
        sessionState = .preparing
        s.start(.route(gpxPath: url.path, loop: routeLoop, summary: routeSummary))
    }

    /// Rebuild the route GPX and restart playback with the edited waypoints.
    func applyRoute() {
        guard hasActiveSession else { return }
        startRoute()
    }

    func stopSpoof() {
        activeSession?.stop()
        activeCoordinate = nil
        activeRouteSignature = nil
        // Keep `activeSession` until it reports `.idle` so its async clear can run.
    }

    // MARK: - Log

    func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 600 {
            logLines.removeFirst(logLines.count - 600)
        }
    }

    private func trimmed(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 && h == 0 { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
