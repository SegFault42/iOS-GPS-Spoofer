import Foundation
import SpooferCore

/// Last line of defence: if the app is killed by SIGTERM (a `kill`) or SIGINT
/// (Ctrl-C when launched from a terminal) rather than a clean Cmd-Q, AppKit's
/// terminate hooks never run — so catch the signal ourselves, kill any
/// `pymobiledevice3` children, and exit. (Cmd-Q still goes through the nicer
/// `applicationShouldTerminate` path, which also clears the simulated location.
/// SIGKILL and panics can't be caught — `ChildProcessRegistry.sweepStrays()` on
/// the next launch mops those up.)
enum TerminationGuard {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func install() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                ChildProcessRegistry.shared.terminateAll(grace: 2)
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
    }
}
