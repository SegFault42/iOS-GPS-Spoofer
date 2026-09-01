import Foundation

/// Installs SIGINT/SIGTERM handlers that flip a flag and invoke a callback,
/// so the main thread can unwind cleanly (terminate child, restore GPS).
final class ShutdownWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var _requested = false
    private var sources: [DispatchSourceSignal] = []

    var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    /// `onSignal` runs on a background queue; keep it minimal and thread-safe.
    func install(onSignal: @escaping @Sendable () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self._requested = true
                self.lock.unlock()
                onSignal()
            }
            src.resume()
            sources.append(src)
        }
    }
}
