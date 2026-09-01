import Foundation

/// How to reach the iOS 17+ developer services tunnel.
public enum Transport: String, CaseIterable, Sendable {
    /// macOS only, no root: piggybacks Apple's `remotepairingd` tunnel.
    case native
    /// Uses a running `pymobiledevice3 remote tunneld` (usually started with sudo).
    case tunneld
    /// In-process pure-Python userspace tunnel, no root, slower.
    case userspace

    /// Flags to append to a `pymobiledevice3 developer …` invocation.
    public func flags(udid: String) -> [String] {
        switch self {
        case .native: return ["--native"]
        case .userspace: return ["--userspace"]
        case .tunneld: return ["--tunnel", udid]
        }
    }

    public var label: String {
        switch self {
        case .native: return "Native (no root)"
        case .tunneld: return "tunneld daemon"
        case .userspace: return "Userspace (no root, slow)"
        }
    }
}

/// Coordinate helpers shared by the CLI and GUI.
public enum Coordinate {
    public static func validate(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90...90).contains(latitude) else {
            throw SpoofError("latitude out of range: \(latitude)")
        }
        guard longitude.isFinite, (-180...180).contains(longitude) else {
            throw SpoofError("longitude out of range: \(longitude)")
        }
    }

    /// Parse `"lat,lon"` / `"lat lon"` (also tolerates a trailing/leading space).
    public static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return (lat, lon)
    }
}

/// A few well-known spots for the GUI's quick-pick menu.
public struct NamedLocation: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let name: String
    public let latitude: Double
    public let longitude: Double

    public init(_ name: String, _ latitude: Double, _ longitude: Double) {
        self.name = name; self.latitude = latitude; self.longitude = longitude
    }

    public static let presets: [NamedLocation] = [
        .init("Apple Park, Cupertino", 37.334_9, -122.009_0),
        .init("Eiffel Tower, Paris", 48.858_4, 2.294_5),
        .init("Times Square, New York", 40.758_0, -73.985_5),
        .init("Big Ben, London", 51.500_7, -0.124_6),
        .init("Shibuya Crossing, Tokyo", 35.659_5, 139.700_5),
        .init("Sydney Opera House", -33.856_8, 151.215_3),
    ]
}
