import Foundation

/// One sampled position along a route: a coordinate and how many seconds into
/// the trip the device should be there.
public struct RoutePoint: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let offset: TimeInterval
}

/// Turns a handful of user-placed waypoints + a total duration into a dense,
/// time-stamped track that `pymobiledevice3 … simulate-location play` can replay
/// as smooth constant-speed movement.
public enum RouteBuilder {

    /// Great-circle distance in metres.
    public static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let la1 = a.lat * .pi / 180
        let la2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    public static func totalDistance(_ waypoints: [(lat: Double, lon: Double)]) -> Double {
        guard waypoints.count > 1 else { return 0 }
        return zip(waypoints, waypoints.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Resample the polyline through `waypoints` into points spaced ~`sampleInterval`
    /// seconds apart, moving at constant speed so the whole route takes `duration`.
    public static func interpolate(
        waypoints: [(lat: Double, lon: Double)],
        duration: TimeInterval,
        sampleInterval: TimeInterval = 0.5
    ) throws -> [RoutePoint] {
        guard waypoints.count >= 2 else {
            throw SpoofError("a route needs at least 2 points")
        }
        guard duration > 0 else {
            throw SpoofError("route duration must be greater than 0")
        }

        // Cumulative distance at each waypoint.
        var cumulative: [Double] = [0]
        for i in 1..<waypoints.count {
            cumulative.append(cumulative[i - 1] + distance(waypoints[i - 1], waypoints[i]))
        }
        let total = cumulative.last ?? 0

        let steps = max(2, min(3000, Int((duration / max(0.05, sampleInterval)).rounded(.up))))

        // Degenerate: all waypoints coincide — just sit there for the duration.
        guard total > 0 else {
            return [
                RoutePoint(latitude: waypoints[0].lat, longitude: waypoints[0].lon, offset: 0),
                RoutePoint(latitude: waypoints[0].lat, longitude: waypoints[0].lon, offset: duration),
            ]
        }

        var points: [RoutePoint] = []
        points.reserveCapacity(steps + 1)
        var segment = 0
        for k in 0...steps {
            let frac = Double(k) / Double(steps)
            let target = frac * total
            while segment < waypoints.count - 2 && cumulative[segment + 1] < target {
                segment += 1
            }
            let segStart = cumulative[segment]
            let segEnd = cumulative[segment + 1]
            let t = segEnd > segStart ? (target - segStart) / (segEnd - segStart) : 0
            let a = waypoints[segment]
            let b = waypoints[segment + 1]
            points.append(RoutePoint(
                latitude: a.lat + (b.lat - a.lat) * t,
                longitude: a.lon + (b.lon - a.lon) * t,
                offset: frac * duration
            ))
        }
        return points
    }

    /// GPX 1.1 document. `pymobiledevice3` paces between points using the gaps
    /// between their `<time>` stamps, so the absolute base time is irrelevant.
    public static func gpx(_ points: [RoutePoint],
                           base: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> String {
        let iso = ISO8601DateFormatter()
        // Fractional seconds so sub-second point spacing paces smoothly in
        // pymobiledevice3 (gpxpy parses `…T…:20.500Z` fine).
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var body = ""
        for p in points {
            let time = iso.string(from: base.addingTimeInterval(p.offset))
            body += "   <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><time>\(time)</time></trkpt>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="iosgpsspoof" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><name>iosgpsspoof route</name><trkseg>
        \(body) </trkseg></trk>
        </gpx>
        """
    }

    /// Write a route GPX to a temp file, returning its URL. Caller deletes it.
    public static func writeGPX(
        waypoints: [(lat: Double, lon: Double)],
        duration: TimeInterval
    ) throws -> URL {
        let points = try interpolate(waypoints: waypoints, duration: duration)
        let xml = gpx(points)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosgpsspoof-route-\(UUID().uuidString).gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
