import ArgumentParser
import Foundation
import SpooferCore

// MARK: - spoof

struct Spoof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hold the device at a fixed latitude/longitude until stopped."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "Latitude in decimal degrees, e.g. 48.8584. Also accepts a single \"lat,lon\" token.")
    var latitude: String

    @Argument(help: "Longitude in decimal degrees, e.g. 2.2945.")
    var longitude: String?

    @Option(name: .customLong("retry-interval"), help: "Seconds to wait before re-establishing after a drop.")
    var retryInterval: Double = 5

    @Flag(name: .customLong("no-clear-on-exit"),
          help: "Leave the simulated location in place when the tool exits.")
    var noClearOnExit: Bool = false

    func run() throws {
        let (lat, lon) = try parseCoordinate(latitude, longitude)
        let ctx = try common.makeContext()
        let args = ["developer", "dvt", "simulate-location", "set"]
            + ctx.transportFlags
            + ["--udid", ctx.device.udid, "--", String(lat), String(lon)]
        try Supervisor(
            ctx: ctx,
            childArgs: args,
            describe: "\(lat), \(lon)",
            retryInterval: retryInterval,
            clearOnExit: !noClearOnExit
        ).run()
    }
}

// MARK: - route

struct Route: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replay a GPX track, moving the device along it, until stopped."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "Path to a .gpx file.")
    var gpx: String

    @Flag(name: .customLong("loop"), help: "Restart the track from the beginning when it finishes.")
    var loop: Bool = false

    @Option(name: .customLong("timing-randomness"), help: "Jitter (ms) added between GPX points for realism.")
    var timingRandomness: Int = 0

    @Flag(name: .customLong("no-clear-on-exit"),
          help: "Leave the simulated location in place when the tool exits.")
    var noClearOnExit: Bool = false

    func run() throws {
        let path = URL(fileURLWithPath: gpx).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SpoofError("no such file: \(gpx)")
        }
        let ctx = try common.makeContext()
        var args = ["developer", "dvt", "simulate-location", "play"]
            + ctx.transportFlags
            + ["--udid", ctx.device.udid]
        if timingRandomness > 0 {
            args += ["--timing-randomness-range", String(timingRandomness)]
        }
        args += [path]

        // `loop` maps onto the supervisor's relaunch behaviour: when `play`
        // exits normally we simply start it again.
        try Supervisor(
            ctx: ctx,
            childArgs: args,
            describe: "route \(URL(fileURLWithPath: path).lastPathComponent)",
            retryInterval: loop ? 1 : 5,
            clearOnExit: !noClearOnExit
        ).run()
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired iOS devices.")

    @Option(name: .customLong("python-path"), help: "Path to the pymobiledevice3 executable.")
    var pythonPath: String?

    func run() throws {
        let pmd = try Pymobiledevice3.resolve(explicit: pythonPath)
        let devices = try pmd.listDevices()
        if devices.isEmpty {
            print("No paired devices found.")
            return
        }
        for d in devices {
            print("\(d.udid)  \(d.summary)")
        }
    }
}

// MARK: - clear

struct ClearCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear any simulated location and restore the device's real GPS."
    )

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = try common.makeContext()
        _ = try ctx.pmd.run(
            ["developer", "dvt", "simulate-location", "clear"] + ctx.transportFlags + ["--udid", ctx.device.udid],
            timeout: 90
        )
        log("real GPS restored on \(ctx.device.deviceName).")
    }
}

// MARK: - helpers

func parseCoordinate(_ first: String, _ second: String?) throws -> (Double, Double) {
    let lat: Double
    let lon: Double
    if let second {
        guard let a = Double(first), let b = Double(second) else {
            throw SpoofError("could not parse coordinates: \(first) \(second)")
        }
        (lat, lon) = (a, b)
    } else {
        guard let parsed = Coordinate.parse(first) else {
            throw SpoofError("expected `LAT LON` or `\"LAT,LON\"`, got: \(first)")
        }
        (lat, lon) = (parsed.latitude, parsed.longitude)
    }
    try Coordinate.validate(latitude: lat, longitude: lon)
    return (lat, lon)
}
