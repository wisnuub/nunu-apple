import AppKit
import Foundation
import Virtualization

class AndroidVM: NSObject {
    private let config: VMConfig
    private var vm: VZVirtualMachine?
    private var vmWindow: VMWindow?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(config: VMConfig) {
        self.config = config
    }

    private var framePacer: FramePacer?
    private var adbBridge: ADBBridge?
    private var adbInput: ADBInput?
    private var gestureObservers: [NSObjectProtocol] = []

    // Accumulated FPS-mode cursor position (display pixels, origin top-left)
    @MainActor private var fpsCursorX: Double = 0
    @MainActor private var fpsCursorY: Double = 0

    @MainActor
    func start() async throws {
        // Apply all host-side performance optimisations before the VM starts
        Performance.apply()

        let vzConfig = try buildConfiguration()
        do {
            try vzConfig.validate()
        } catch {
            let ns = error as NSError
            fputs("nunu-vm: validate() failed: \(error.localizedDescription)\n", stderr)
            fputs("nunu-vm: validate userInfo: \(ns.userInfo)\n", stderr)
            throw error
        }

        let machine = VZVirtualMachine(configuration: vzConfig)
        machine.delegate = self
        self.vm = machine

        // Restore from snapshot if one exists — skips the 130s cold boot
        let snapshotURL = config.snapshotPath.isEmpty ? nil
            : URL(fileURLWithPath: config.snapshotPath)

        if let url = snapshotURL, FileManager.default.fileExists(atPath: url.path) {
            fputs("nunu-vm: restoring snapshot \(url.lastPathComponent)...\n", stderr)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                machine.restoreMachineStateFrom(url: url) { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
            try await machine.resume()
            fputs("nunu-vm: snapshot restored\n", stderr)
        } else {
            try await machine.start()
        }

        print(#"{"event":"started"}"#)
        fflush(stdout)

        // Start ADB bridge in background — uses vsock to reach adbd in the guest
        let socketDevice = machine.socketDevices.first as? VZVirtioSocketDevice

        // Start vsock debug listener on port 9999 — guest /first_stage.sh connects here
        if let sd = socketDevice {
            let debugListener = VZVirtioSocketListener()
            debugListener.delegate = DebugListenerDelegate.shared
            sd.setSocketListener(debugListener, forPort: 9999)
        }

        let bridge = ADBBridge(hostPort: config.adbPort, socketDevice: socketDevice)
        self.adbBridge = bridge
        let display = config.display
        let adbPort = config.adbPort
        Task {
            await bridge.start()
            // Once ADB is ready, wire up gesture input injection
            let input = ADBInput(
                adbAddress: "127.0.0.1:\(adbPort)",
                displayWidth: display.widthPx,
                displayHeight: display.heightPx
            )
            self.adbInput = input
            await MainActor.run { self.subscribeGestures(input: input) }

            // Auto-save snapshot once Android fully boots (only if no snapshot exists yet)
            if !config.snapshotPath.isEmpty {
                let snapURL = URL(fileURLWithPath: config.snapshotPath)
                if !FileManager.default.fileExists(atPath: snapURL.path) {
                    let booted = await self.waitForBootCompleted(adbPort: adbPort)
                    if booted { await self.saveSnapshot() }
                }
            }
        }

        // Show window and start frame pacer on main thread
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let window = VMWindow(displayConfig: display)
            self.vmWindow = window
            window.show(vm: machine)

            // FPS mode: accumulate mouse deltas into an absolute display position,
            // forwarded to Android via ADB input injection.
            // Start at display centre so the first FPS session feels natural.
            self.fpsCursorX = Double(display.widthPx) / 2
            self.fpsCursorY = Double(display.heightPx) / 2
            window.setFPSDeltaHandler { [weak self] dx, dy in
                guard let self, let input = self.adbInput else { return }
                self.fpsCursorX = (self.fpsCursorX + Double(dx))
                    .clamped(to: 0...Double(display.widthPx - 1))
                self.fpsCursorY = (self.fpsCursorY + Double(dy))
                    .clamped(to: 0...Double(display.heightPx - 1))
                let x = Int(self.fpsCursorX); let y = Int(self.fpsCursorY)
                Task { await input.mouseMoveTo(x: x, y: y) }
            }

            // Start CVDisplayLink-driven frame pacing once window is visible
            let pacer = FramePacer()
            pacer.start(screen: NSScreen.main) {
                DispatchQueue.main.async {
                    window.requestFrame()
                }
            }
            self.framePacer = pacer
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            self.stopContinuation = continuation
        }
    }

    // Save a snapshot so next launch resumes instantly instead of cold booting.
    // Call this once Android is fully booted (sys.boot_completed=1).
    // Must run on the main actor — Virtualization.framework asserts main-queue
    // ownership on pause/resume/save (enforced as a hard crash on macOS 26+).
    @MainActor
    func saveSnapshot() async {
        guard let machine = vm,
              !config.snapshotPath.isEmpty else { return }
        let url = URL(fileURLWithPath: config.snapshotPath)
        fputs("nunu-vm: saving snapshot to \(url.lastPathComponent)...\n", stderr)
        do {
            try await machine.pause()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                machine.saveMachineStateTo(url: url) { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
            try await machine.resume()
            fputs("nunu-vm: snapshot saved — next launch will resume in seconds\n", stderr)
            print(#"{"event":"snapshot-saved","path":"\#(url.path)"}"#); fflush(stdout)
        } catch {
            fputs("nunu-vm: snapshot failed: \(error)\n", stderr)
            // Make sure VM keeps running even if snapshot fails
            try? await machine.resume()
        }
    }

    // MARK: - Boot completed probe

    private func waitForBootCompleted(adbPort: Int, timeoutSeconds: Int = 300) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            let result = await runAdbShell(port: adbPort, cmd: "getprop sys.boot_completed")
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                fputs("nunu-vm: Android boot completed\n", stderr)
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        fputs("nunu-vm: warning: boot_completed not set after \(timeoutSeconds)s — skipping snapshot\n", stderr)
        return false
    }

    private func runAdbShell(port: Int, cmd: String) async -> String {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["adb", "-s", "127.0.0.1:\(port)", "shell", cmd]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            try? proc.run()
        }
    }

    // MARK: - Configuration

    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()

        c.memorySize = config.memoryBytes
        c.cpuCount = max(1, min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))

        c.bootLoader = try makeBootLoader()
        c.storageDevices = try makeStorageDevices()
        c.networkDevices = makeNetworkDevices()
        c.graphicsDevices = [makeGraphicsDevice(display: config.display)]
        c.keyboards = makeKeyboards()
        c.pointingDevices = makePointingDevices()
        // hvc0 = Linux serial console; hvc1-hvc20 = null ports for Cuttlefish HALs
        // (light, oemlock, UWB, BT, seriallogging, etc. each need a backing hvcN device)
        c.serialPorts = [makeSerialConsole()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]   // vsock for ADB

        return c
    }

    private func makeBootLoader() throws -> VZLinuxBootLoader {
        guard !config.kernelPath.isEmpty else {
            throw VMError.missingKernel
        }
        let kernelURL = URL(fileURLWithPath: config.kernelPath)
        let loader = VZLinuxBootLoader(kernelURL: kernelURL)

        if !config.initrdPath.isEmpty {
            loader.initialRamdiskURL = URL(fileURLWithPath: config.initrdPath)
        }

        // Kernel cmdline — use custom if provided, otherwise Cuttlefish defaults
        let cmdline = config.kernelCmdline.isEmpty
            ? [
                // console_ignore_legacy makes our console= take effect even when the
                // kernel built-in cmdline already set console=ttynull.
                // Keep cmdline minimal — hardware/HAL config is in the bootconfig
                // appended to the initramfs (androidboot.* params live there)
                "console=hvc0",
                "printk.devkmsg=on",
                "audit=1",
                "panic=-1",
                "8250.nr_uarts=1",
                "binder.impl=rust",
                "cma=0",
                "firmware_class.path=/vendor/etc/",
                "loop.max_part=7",
                "init=/init",
                "loglevel=8",
                // boot_devices is set in bootconfig (arm64: 3f000000.pcie)
                // bootconfig tells the kernel to read the appended bootconfig section
                "bootconfig",
            ].joined(separator: " ")
            : config.kernelCmdline
        loader.commandLine = cmdline

        return loader
    }

    private func makeStorageDevices() throws -> [VZStorageDeviceConfiguration] {
        guard !config.diskPaths.isEmpty else {
            throw VMError.noDisk
        }

        // Read-only partitions: vbmeta* only
        // super is writable so Android can create an overlayfs scratch partition
        // (needed for `adb remount` to patch vendor .rc files without rebuilding images)
        let readOnlyNames = ["vbmeta"]
        return try config.diskPaths.map { path in
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            let ro = readOnlyNames.contains(where: { name.hasPrefix($0) })
            fputs("nunu-vm: disk [\(ro ? "ro" : "rw")] \(url.lastPathComponent) (\(url.path))\n", stderr)
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: ro)
                return VZVirtioBlockDeviceConfiguration(attachment: attachment)
            } catch {
                fputs("nunu-vm: disk FAILED \(url.lastPathComponent): \(error)\n", stderr)
                throw error
            }
        }
    }

    private func makeNetworkDevices() -> [VZNetworkDeviceConfiguration] {
        let device = VZVirtioNetworkDeviceConfiguration()
        // NAT — gives Android internet access and allows ADB over TCP (port forwarding handled by nunu)
        device.attachment = VZNATNetworkDeviceAttachment()
        return [device]
    }
}

// MARK: - VZVirtualMachineDelegate

extension AndroidVM: VZVirtualMachineDelegate {
    // MARK: - Gesture → ADB wiring

    @MainActor
    private func subscribeGestures(input: ADBInput) {
        let center = NotificationCenter.default

        let w = config.display.widthPx
        let h = config.display.heightPx

        let pinchObs = center.addObserver(forName: .nunuVMPinch, object: nil, queue: .main) { note in
            guard let scale = note.userInfo?["scale"] as? Double else { return }
            Task { await input.pinch(scale: scale, centerX: w / 2, centerY: h / 2) }
        }

        let scrollObs = center.addObserver(forName: .nunuVMScroll, object: nil, queue: .main) { note in
            guard let dx = note.userInfo?["dx"] as? CGFloat,
                  let dy = note.userInfo?["dy"] as? CGFloat,
                  let x  = note.userInfo?["x"]  as? CGFloat,
                  let y  = note.userInfo?["y"]  as? CGFloat else { return }
            let conv = TouchCoordinateConverter(
                viewSize: CGSize(width: w, height: h),
                displayWidth: w, displayHeight: h
            )
            let (px, py) = conv.convert(NSPoint(x: x, y: y))
            Task { await input.scroll(fromX: px, fromY: py, dx: Double(dx), dy: Double(-dy)) }
        }

        gestureObservers = [pinchObs, scrollObs]
    }

    @MainActor
    private func unsubscribeGestures() {
        gestureObservers.forEach { NotificationCenter.default.removeObserver($0) }
        gestureObservers.removeAll()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print(#"{"event":"stopped"}"#); fflush(stdout)
        framePacer?.stop()
        Task { await adbBridge?.stop() }
        Task { await MainActor.run { self.unsubscribeGestures() } }
        Performance.teardown()
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let msg = error.localizedDescription
        print(#"{"event":"error","message":"\#(msg)"}"#); fflush(stdout)
        framePacer?.stop()
        Task { await adbBridge?.stop() }
        Task { await MainActor.run { self.unsubscribeGestures() } }
        Performance.teardown()
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

// MARK: - Vsock debug listener (port 9999, receives output from /first_stage.sh)

class DebugListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    static let shared = DebugListenerDelegate()
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        fputs("nunu-vm: [DEBUG] guest connected on vsock:9999\n", stderr)
        let fd = connection.fileDescriptor
        DispatchQueue.global().async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                guard n > 0 else { break }
                let s = String(bytes: buf[..<n], encoding: .utf8) ?? String(bytes: buf[..<n], encoding: .isoLatin1) ?? "<?>"
                fputs("[guest] \(s)", stderr)
            }
            Darwin.close(fd)
            fputs("nunu-vm: [DEBUG] guest disconnected\n", stderr)
        }
        return true
    }
}

// MARK: - Errors

enum VMError: LocalizedError {
    case missingKernel
    case noDisk

    var errorDescription: String? {
        switch self {
        case .missingKernel: return "No kernel specified. Pass --kernel <path>"
        case .noDisk:        return "No disk image specified. Pass --disk <path>"
        }
    }
}
