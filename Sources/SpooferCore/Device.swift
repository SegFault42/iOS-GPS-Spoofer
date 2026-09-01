import Foundation

/// A paired iOS device as reported by `pymobiledevice3 usbmux list`.
public struct Device: Decodable, Identifiable, Hashable, Sendable {
    public let deviceName: String
    public let identifier: String
    public let connectionType: String
    public let productType: String
    public let productVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "DeviceName"
        case identifier = "Identifier"
        case connectionType = "ConnectionType"
        case productType = "ProductType"
        case productVersion = "ProductVersion"
    }

    public var id: String { identifier }
    public var udid: String { identifier }

    /// Major iOS version, e.g. `18` for `"18.5"`.
    public var majorVersion: Int {
        Int(productVersion.split(separator: ".").first ?? "") ?? 0
    }

    public var connectionLabel: String { connectionType.lowercased() }

    public var summary: String {
        "\(deviceName) — iOS \(productVersion) (\(productType), \(connectionLabel))"
    }

    /// Marketing-ish model name from the identifier (best effort).
    public var modelName: String { productType }
}

public enum ConnectionFilter: String, CaseIterable, Sendable {
    case any, usb, network

    public func matches(_ device: Device) -> Bool {
        switch self {
        case .any: return true
        case .usb: return device.connectionType.lowercased() == "usb"
        case .network: return device.connectionType.lowercased() == "network"
        }
    }
}

extension Pymobiledevice3 {
    /// All currently reachable paired devices, de-duplicated by UDID (a device
    /// paired over both USB and Wi-Fi is listed once, preferring the USB link).
    public func listDevices() throws -> [Device] {
        let json = try run(["usbmux", "list"], timeout: 15)
        guard let data = json.data(using: .utf8) else { return [] }
        let raw = try JSONDecoder().decode([Device].self, from: data)

        var byUDID: [String: Device] = [:]
        for device in raw {
            if let existing = byUDID[device.udid] {
                if existing.connectionLabel != "usb" && device.connectionLabel == "usb" {
                    byUDID[device.udid] = device
                }
            } else {
                byUDID[device.udid] = device
            }
        }
        // Preserve first-seen order.
        var seen = Set<String>()
        return raw.compactMap { d in
            guard !seen.contains(d.udid) else { return nil }
            seen.insert(d.udid)
            return byUDID[d.udid]
        }
    }

    public func listDevicesAsync() async throws -> [Device] {
        try await Task.detached(priority: .utility) { try self.listDevices() }.value
    }

    /// Pick the target device: the one matching `udid` if given, otherwise the
    /// first that satisfies `connection`.
    public func selectDevice(udid: String?, connection: ConnectionFilter) throws -> Device {
        let devices = try listDevices()
        guard !devices.isEmpty else {
            throw SpoofError("no paired iOS devices found. Connect an iPhone and trust this computer.")
        }
        if let udid {
            guard let match = devices.first(where: { $0.udid == udid }) else {
                let known = devices.map { "  \($0.udid)  \($0.summary)" }.joined(separator: "\n")
                throw SpoofError("no device with UDID \(udid). Known devices:\n\(known)")
            }
            return match
        }
        let filtered = devices.filter { connection.matches($0) }
        guard let chosen = filtered.first else {
            throw SpoofError("no device matches connection filter '\(connection.rawValue)'.")
        }
        return chosen
    }

    /// Is a device with this UDID currently reachable?
    public func isPresent(udid: String, connection: ConnectionFilter = .any) -> Bool {
        guard let devices = try? listDevices() else { return false }
        return devices.contains { $0.udid == udid && connection.matches($0) }
    }
}
