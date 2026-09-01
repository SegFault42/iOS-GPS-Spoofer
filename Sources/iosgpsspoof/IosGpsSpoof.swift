import ArgumentParser
import Foundation
import SpooferCore

extension ConnectionFilter: ExpressibleByArgument {}
extension Transport: ExpressibleByArgument {}

@main
struct IosGpsSpoof: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iosgpsspoof",
        abstract: "Spoof the GPS location of a connected iPhone (iOS 17+) for as long as the tool runs.",
        discussion: """
            Uses Apple's developer location-simulation service (the same one Xcode's
            "Simulate Location" uses), reached over the CoreDevice tunnel via
            pymobiledevice3. The fake location holds while this process runs and is
            cleared on exit. If the device disconnects and reconnects, the spoof is
            automatically re-established.

            Requirements: the iPhone must be paired/trusted and have Developer Mode
            enabled (Settings > Privacy & Security > Developer Mode).
            """,
        subcommands: [Spoof.self, Route.self, List.self, ClearCmd.self],
        defaultSubcommand: Spoof.self
    )
}

/// Options shared by every subcommand.
struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("udid"), help: "Target device UDID. Defaults to the first connected device.")
    var udid: String?

    @Option(name: .customLong("connection"), help: "Which link to use: any | usb | network.")
    var connection: ConnectionFilter = .any

    @Option(name: .customLong("transport"), help: "Tunnel transport: native | tunneld | userspace. 'native' needs no root (macOS).")
    var transport: Transport = .native

    @Option(name: .customLong("python-path"), help: "Path to the pymobiledevice3 executable.")
    var pythonPath: String?
}

extension CommonOptions {
    func makeContext() throws -> Context {
        let pmd = try Pymobiledevice3.resolve(explicit: pythonPath)
        let device = try pmd.selectDevice(udid: udid, connection: connection)
        return Context(pmd: pmd, device: device, transport: transport, connection: connection)
    }
}

struct Context {
    let pmd: Pymobiledevice3
    let device: Device
    let transport: Transport
    let connection: ConnectionFilter

    var transportFlags: [String] { transport.flags(udid: device.udid) }

    func preflight() {
        if device.majorVersion != 0 && device.majorVersion < 17 {
            warn("device is iOS \(device.productVersion); this tool targets iOS 17+. Trying anyway.")
        }
        do {
            _ = try pmd.run(["mounter", "auto-mount", "--udid", device.udid], timeout: 120)
        } catch {
            warn("could not auto-mount the DeveloperDiskImage (may already be mounted): \(error)")
        }
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}
