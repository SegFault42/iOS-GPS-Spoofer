import Foundation

/// What a session is doing.
public enum SpoofJob: Sendable, Equatable {
    /// Hold the device at a fixed point.
    case fixed(latitude: Double, longitude: Double)
    /// Replay a GPX track. `loop` restarts it when it finishes.
    case route(gpxPath: String, loop: Bool, summary: String)
}

public enum SpoofState: Equatable, Sendable {
    case idle
    case preparing
    case active(latitude: Double, longitude: Double)
    case routing(String)
    /// A non-looping route reached its end; the device sits at the last point.
    case completed
    /// Ended without the caller asking (device unplugged, tunnel died, …).
    case interrupted(String)
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .preparing, .active, .routing: return true
        case .idle, .completed, .interrupted, .failed: return false
        }
    }
}

/// Drives one `pymobiledevice3 developer dvt simulate-location` child (a fixed
/// `set`, or a `play` of a route) for the lifetime of a spoofing session: keeps
/// it alive while the device stays connected, re-establishes it if the device
/// drops and returns, and clears the simulated location on `stop()`.
///
/// Fully event-driven — no blocking waits on any control path, so `stop()` and
/// `start()` take effect immediately. Callbacks are delivered on `callbackQueue`
/// (default: main).
public final class SpoofSession: @unchecked Sendable {
    public var onStateChange: (@Sendable (SpoofState) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public let device: Device

    private let pmd: Pymobiledevice3
    private let transport: Transport
    private let callbackQueue: DispatchQueue
    private let ops = DispatchQueue(label: "SpoofSession.ops", qos: .userInitiated)

    private let lock = NSLock()
    private var _state: SpoofState = .idle
    private var child: Process?
    private var stopping = false
    private var runToken = 0
    private var ownedRouteFile: URL?

    public init(pmd: Pymobiledevice3, device: Device, transport: Transport = .native,
                callbackQueue: DispatchQueue = .main) {
        self.pmd = pmd
        self.device = device
        self.transport = transport
        self.callbackQueue = callbackQueue
    }

    public var state: SpoofState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    // MARK: - Control

    /// Convenience for a fixed point.
    public func start(latitude: Double, longitude: Double) {
        start(.fixed(latitude: latitude, longitude: longitude))
    }

    /// Start, or (if already running) switch to, `job`.
    public func start(_ job: SpoofJob) {
        switch job {
        case let .fixed(lat, lon):
            do { try Coordinate.validate(latitude: lat, longitude: lon) }
            catch { setState(.failed("\(error)")); return }
        case let .route(path, _, _):
            guard FileManager.default.fileExists(atPath: path) else {
                setState(.failed("route file missing: \(path)")); return
            }
        }

        lock.lock()
        stopping = false
        runToken &+= 1
        let token = runToken
        let previousChild = child
        child = nil
        let staleRouteFile = ownedRouteFile
        if case let .route(path, _, _) = job {
            ownedRouteFile = URL(fileURLWithPath: path)
        } else {
            ownedRouteFile = nil
        }
        lock.unlock()

        if let staleRouteFile, staleRouteFile.path != ownedRouteFile?.path {
            try? FileManager.default.removeItem(at: staleRouteFile)
        }

        setState(.preparing)
        emit("preparing tunnel to \(device.deviceName)…")

        ops.async { [self] in
            if let previousChild { Self.kill(previousChild, grace: 3) }
            guard isCurrent(token) else { return }

            if device.majorVersion != 0 && device.majorVersion < 17 {
                emit("note: device is iOS \(device.productVersion); this path targets iOS 17+.")
            }
            do {
                _ = try pmd.run(["mounter", "auto-mount", "--udid", device.udid], timeout: 120)
            } catch {
                emit("auto-mount skipped (\(error))")
            }
            guard isCurrent(token) else { return }
            launch(job: job, token: token)
        }
    }

    /// Stop and restore the device's real GPS. Returns immediately.
    public func stop(clearLocation: Bool = true) {
        lock.lock()
        stopping = true
        runToken &+= 1
        let c = child
        child = nil
        let routeFile = ownedRouteFile
        ownedRouteFile = nil
        lock.unlock()

        if let c { Self.kill(c, grace: 3) }
        if let routeFile { try? FileManager.default.removeItem(at: routeFile) }

        ops.async { [self] in
            if clearLocation {
                emit("restoring real GPS…")
                do {
                    _ = try pmd.run(clearArgs, timeout: 90)
                    emit("real GPS restored.")
                } catch {
                    emit("could not clear simulated location: \(error)")
                }
            }
            setState(.idle)
        }
    }

    /// Best-effort synchronous teardown for app termination.
    public func stopBlocking() {
        lock.lock()
        stopping = true
        runToken &+= 1
        let c = child
        child = nil
        let routeFile = ownedRouteFile
        ownedRouteFile = nil
        lock.unlock()

        if let c { Self.kill(c, grace: 2) }
        if let routeFile { try? FileManager.default.removeItem(at: routeFile) }
        _ = try? pmd.run(clearArgs, timeout: 15)
    }

    private static func kill(_ process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        process.interrupt()
        if waitFor(process, seconds: grace * 0.6) { return }
        process.terminate()
        if waitFor(process, seconds: grace * 0.4) { return }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private static func waitFor(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { return true }
            usleep(50_000)
        }
        return !process.isRunning
    }

    // MARK: - Internals

    private var clearArgs: [String] {
        ["developer", "dvt", "simulate-location", "clear"]
            + transport.flags(udid: device.udid) + ["--udid", device.udid]
    }

    private func childArgs(for job: SpoofJob) -> [String] {
        let base = ["developer", "dvt", "simulate-location"]
        switch job {
        case let .fixed(lat, lon):
            return base + ["set"] + transport.flags(udid: device.udid)
                + ["--udid", device.udid, "--", String(lat), String(lon)]
        case let .route(path, _, _):
            return base + ["play"] + transport.flags(udid: device.udid)
                + ["--udid", device.udid, path]
        }
    }

    private func launch(job: SpoofJob, token: Int) {
        guard isCurrent(token) else { return }

        guard pmd.isPresent(udid: device.udid) else {
            setState(.interrupted("device disconnected"))
            emit("device not connected — waiting for it to return…")
            ops.asyncAfter(deadline: .now() + 4) { [self] in
                launch(job: job, token: token)
            }
            return
        }

        let proc: Process
        do {
            proc = try pmd.spawn(childArgs(for: job)) { [weak self] line in
                if line.contains("ERROR") || line.contains("Traceback") || line.contains("Exception") {
                    self?.emit(line)
                }
            }
        } catch {
            setState(.failed("could not start pymobiledevice3: \(error)"))
            return
        }

        let registryCleanup = proc.terminationHandler
        proc.terminationHandler = { [weak self] p in
            registryCleanup?(p)
            guard let self else { return }
            self.lock.lock()
            let mine = (self.runToken == token)
            let bail = self.stopping
            if mine { self.child = nil }
            self.lock.unlock()
            guard mine, !bail else { return }
            self.handleChildExit(job: job, token: token, status: p.terminationStatus)
        }

        lock.lock()
        guard runToken == token else {
            lock.unlock()
            proc.terminationHandler = nil
            proc.interrupt()
            return
        }
        child = proc
        lock.unlock()

        switch job {
        case let .fixed(lat, lon):
            setState(.active(latitude: lat, longitude: lon))
            emit("● holding at \(lat), \(lon)")
        case let .route(_, loop, summary):
            setState(.routing(summary))
            emit("● playing route: \(summary)\(loop ? " (looping)" : "")")
        }
    }

    private func handleChildExit(job: SpoofJob, token: Int, status: Int32) {
        switch job {
        case .fixed:
            emit("session ended (status \(status)) — re-establishing…")
            ops.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.launch(job: job, token: token)
            }

        case let .route(_, loop, summary):
            if status == 0 {
                if loop {
                    emit("route finished — looping")
                    ops.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.launch(job: job, token: token)
                    }
                } else {
                    emit("route finished — device is at the destination")
                    setState(.completed)
                }
            } else if pmd.isPresent(udid: device.udid) {
                setState(.failed("route playback failed (status \(status)) — see log"))
            } else {
                setState(.interrupted("device disconnected mid-route"))
                emit("device gone — will restart the route when it returns")
                ops.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.launch(job: job, token: token)
                }
            }
            _ = summary
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runToken == token && !stopping
    }

    private func setState(_ newValue: SpoofState) {
        lock.lock()
        _state = newValue
        lock.unlock()
        callbackQueue.async { [onStateChange] in onStateChange?(newValue) }
    }

    private func emit(_ line: String) {
        callbackQueue.async { [onLog] in onLog?(line) }
    }
}
