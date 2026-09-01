import Foundation

/// Tracks every `pymobiledevice3` child spawned via `Pymobiledevice3.spawn`, so
/// a front-end can guarantee cleanup on termination (SIGTERM, crash, Cmd-Q)
/// even if the normal `stop()` path didn't run. Without this, a killed parent
/// leaves the child holding the device's location simulation open.
public final class ChildProcessRegistry: @unchecked Sendable {
    public static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    private init() {}

    func add(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = nil; lock.unlock()
    }

    /// Signal every tracked child (SIGINT, then SIGKILL after `grace`s). Safe to
    /// call from a dispatch signal-source handler.
    public func terminateAll(grace: TimeInterval = 2) {
        lock.lock()
        let all = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for p in all where p.isRunning { p.interrupt() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, all.contains(where: { $0.isRunning }) { usleep(50_000) }
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    public var hasRunningChildren: Bool {
        lock.lock(); defer { lock.unlock() }
        return processes.values.contains { $0.isRunning }
    }

    /// Kill `pymobiledevice3` location-simulation processes left over from a
    /// previous run that was force-killed (SIGKILL / panic), which this process
    /// therefore doesn't track. Returns the number reaped.
    @discardableResult
    public static func sweepStrays() -> Int {
        let pattern = "pymobiledevice3 developer dvt simulate-location"
        guard let out = try? shell("/usr/bin/pgrep", ["-f", pattern]), !out.isEmpty else { return 0 }
        let mine = getpid()
        let pids = out.split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
            .filter { $0 != mine }
        for pid in pids { kill(pid, SIGINT) }
        usleep(400_000)
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return pids.count
    }

    private static func shell(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
