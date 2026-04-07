import AppKit
import Foundation
import Virtualization

@main
struct NunuVM {
    // Non-async: we'll call NSApp.run() which drives the event loop.
    // VM boot is kicked off from the AppDelegate once the app has launched.
    static func main() {
        let args = Arguments.parse()

        switch args.command {
        case .version:
            print("nunu-vm 0.1.0")
            return

        case .boot:
            let app = NSApplication.shared
            let delegate = AppDelegate(args: args)
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()   // blocks; returns when the app quits
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private let args: Arguments
    private var androidVM: AndroidVM?

    init(args: Arguments) {
        self.args = args
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        let config = VMConfig(
            kernelPath: args.kernel,
            initrdPath: args.initrd,
            diskPaths: args.disks,
            memoryMB: args.memoryMB,
            cpuCount: args.cpuCount,
            adbPort: args.adbPort,
            display: args.display,
            kernelCmdline: args.kernelCmdline,
            snapshotPath: args.snapshotPath
        )

        let vm = AndroidVM(config: config)
        self.androidVM = vm

        Task { @MainActor in
            do {
                try await vm.start()
                await vm.waitUntilStopped()
            } catch {
                let ns = error as NSError
                fputs("nunu-vm: \(error.localizedDescription)\n", stderr)
                fputs("nunu-vm: domain=\(ns.domain) code=\(ns.code)\n", stderr)
                fputs("nunu-vm: userInfo=\(ns.userInfo)\n", stderr)
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    fputs("nunu-vm: underlying domain=\(underlying.domain) code=\(underlying.code)\n", stderr)
                    fputs("nunu-vm: underlying userInfo=\(underlying.userInfo)\n", stderr)
                }
                exit(1)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false   // don't quit just because the window closed
    }
}
