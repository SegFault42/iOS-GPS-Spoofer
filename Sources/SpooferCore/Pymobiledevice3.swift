import Foundation

public struct SpoofError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Thin wrapper around the `pymobiledevice3` executable.
///
/// The heavy lifting of talking to iOS 17+ developer services (the encrypted
/// CoreDevice RemoteXPC tunnel, DVT / Instruments channels) lives in
/// pymobiledevice3. This type just locates the binary and shells out to it.
public struct Pymobiledevice3: Sendable {
    public let executableURL: URL
    /// Prepended to every invocation — used to run `python3 -m pymobiledevice3`
    /// when only an interpreter (e.g. a bundled venv) is available.
    public let argPrefix: [String]

    public init(executableURL: URL, argPrefix: [String] = []) {
        self.executableURL = executableURL
        self.argPrefix = argPrefix
    }

    /// Locate `pymobiledevice3`.
    ///
    /// Order: explicit path, `$PYMOBILEDEVICE3`, a venv bundled in the .app,
    /// a `.venv` beside the cwd / running binary / repo root, then `$PATH`.
    public static func resolve(explicit: String? = nil) throws -> Pymobiledevice3 {
        if let explicit {
            let url = URL(fileURLWithPath: explicit)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SpoofError("not an executable file: \(explicit)")
            }
            return Pymobiledevice3(executableURL: url)
        }

        let fm = FileManager.default

        if let env = ProcessInfo.processInfo.environment["PYMOBILEDEVICE3"],
           fm.isExecutableFile(atPath: env) {
            return Pymobiledevice3(executableURL: URL(fileURLWithPath: env))
        }

        // Bundled venv inside a packaged .app: run it as `python3 -m pymobiledevice3`
        // so a broken script shebang doesn't matter.
        if let resources = Bundle.main.resourceURL {
            let py = resources.appendingPathComponent("venv/bin/python3")
            if fm.isExecutableFile(atPath: py.path) {
                return Pymobiledevice3(executableURL: py, argPrefix: ["-m", "pymobiledevice3"])
            }
        }

        var candidates: [URL] = []
        let cwd = fm.currentDirectoryPath
        candidates.append(URL(fileURLWithPath: cwd).appendingPathComponent(".venv/bin/pymobiledevice3"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent(".venv/bin/pymobiledevice3"))
            candidates.append(exeDir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".venv/bin/pymobiledevice3"))
        }
        for c in candidates where fm.isExecutableFile(atPath: c.path) {
            return Pymobiledevice3(executableURL: c)
        }
        if let onPath = which("pymobiledevice3") {
            return Pymobiledevice3(executableURL: URL(fileURLWithPath: onPath))
        }
        throw SpoofError("""
            could not find `pymobiledevice3`.
            Install it with:  python3 -m venv .venv && .venv/bin/pip install pymobiledevice3
            or set $PYMOBILEDEVICE3 to its path.
            """)
    }

    /// Run to completion, capturing stdout. Throws on non-zero exit.
    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argPrefix + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(100_000) }
            if process.isRunning {
                process.terminate()
                throw SpoofError("`pymobiledevice3 \(args.joined(separator: " "))` timed out after \(Int(timeout))s")
            }
        }
        process.waitUntilExit()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SpoofError("`pymobiledevice3 \(args.joined(separator: " "))` failed (\(process.terminationStatus))\n\(msg)")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Async wrapper for `run`, so callers on the main actor don't block.
    public func runAsync(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
        try await Task.detached(priority: .utility) { try self.run(args, timeout: timeout) }.value
    }

    /// Spawn a long-running process (e.g. `simulate-location set`, which holds
    /// the channel open until it receives SIGINT/SIGTERM). `stderr` is streamed
    /// line-by-line to `onOutput`; `stdout` goes to the parent. The caller owns
    /// the returned `Process`.
    public func spawn(_ args: [String], onOutput: (@Sendable (String) -> Void)? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argPrefix + args

        if let onOutput {
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {   // EOF — process gone; detach to avoid a leak
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    onOutput(String(line))
                }
            }
        } else {
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
        }
        try process.run()
        ChildProcessRegistry.shared.add(process)
        let existing = process.terminationHandler
        process.terminationHandler = { p in
            ChildProcessRegistry.shared.remove(p)
            existing?(p)
        }
        return process
    }
}

/// `which`, without shelling out to a shell.
public func which(_ name: String) -> String? {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
