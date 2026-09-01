import AppKit
import SwiftUI
import SpooferCore

@main
struct SpooferGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("iOS GPS Spoofer") {
            ContentView()
                .environment(AppModel.shared)
                .frame(minWidth: 820, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminationGuard.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Mop up children orphaned by a previous force-kill. Off-main: the
        // subprocess wait pumps a run loop, which must not be the main one.
        DispatchQueue.global(qos: .utility).async {
            let reaped = ChildProcessRegistry.sweepStrays()
            Task { @MainActor in AppModel.shared.completeStartupSweep(reaped: reaped) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // AppKit calls these on the main thread.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = MainActor.assumeIsolated { AppModel.shared.activeSession }
        guard let session else { return .terminateNow }

        DispatchQueue.global(qos: .userInitiated).async {
            session.stopBlocking()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.activeSession }?.stopBlocking()
    }
}
