import Foundation

// ADBInput handles input events that can't go through virtio-input:
// primarily multi-touch gestures (pinch-to-zoom, two-finger scroll).
//
// Single touch and keyboard go through VZUSBScreenCoordinatePointingDevice
// and VZUSBKeyboardConfiguration directly — zero latency, no ADB overhead.
// Multi-touch gestures use ADB because virtio-input multitouch
// is not exposed by Virtualization.framework's current API.

actor ADBInput {
    private let adbAddress: String  // e.g. "127.0.0.1:5555"
    private let displayWidth: Int
    private let displayHeight: Int

    init(adbAddress: String, displayWidth: Int, displayHeight: Int) {
        self.adbAddress = adbAddress
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    // Pinch-to-zoom: simulates two fingers moving apart or together
    // centerX/centerY are in display pixels
    func pinch(scale: Double, centerX: Int, centerY: Int) async {
        // Finger spread: half the diagonal of the screen, scaled
        let spread = Int(Double(min(displayWidth, displayHeight)) * 0.2 * abs(scale - 1.0) * 10)
        guard spread > 2 else { return }

        let x1 = centerX - spread; let y1 = centerY
        let x2 = centerX + spread; let y2 = centerY

        if scale > 1.0 {
            // Zoom in: fingers start close, move apart
            await runAdb(["shell", "input", "swipe",
                String(centerX - 5), String(centerY),
                String(x1), String(y1), "150"])
            await runAdb(["shell", "input", "swipe",
                String(centerX + 5), String(centerY),
                String(x2), String(y2), "150"])
        } else {
            // Zoom out: fingers start apart, move together
            await runAdb(["shell", "input", "swipe",
                String(x1), String(y1),
                String(centerX - 5), String(centerY), "150"])
            await runAdb(["shell", "input", "swipe",
                String(x2), String(y2),
                String(centerX + 5), String(centerY), "150"])
        }
    }

    // Tap at absolute position — simulates a finger touch (touchscreen source).
    func tap(x: Int, y: Int) async {
        await runAdb(["shell", "input", "touchscreen", "tap",
            String(x.clamped(to: 0...(displayWidth - 1))),
            String(y.clamped(to: 0...(displayHeight - 1)))])
    }

    // Drag from one point to another — simulates a finger swipe.
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int = 200) async {
        await runAdb(["shell", "input", "touchscreen", "swipe",
            String(fromX.clamped(to: 0...(displayWidth - 1))),
            String(fromY.clamped(to: 0...(displayHeight - 1))),
            String(toX.clamped(to: 0...(displayWidth - 1))),
            String(toY.clamped(to: 0...(displayHeight - 1))),
            String(durationMs)])
    }

    // Mouse move: sends absolute pointer position to Android.
    // Used for FPS mode — the caller accumulates deltas into an absolute position.
    func mouseMoveTo(x: Int, y: Int) async {
        await runAdb(["shell", "input", "mouse", "move",
            String(x.clamped(to: 0...(displayWidth - 1))),
            String(y.clamped(to: 0...(displayHeight - 1)))])
    }

    // Scroll: simulates a single-finger swipe in the given direction
    func scroll(fromX: Int, fromY: Int, dx: Double, dy: Double) async {
        let toX = (fromX + Int(dx)).clamped(to: 0...(displayWidth - 1))
        let toY = (fromY + Int(dy)).clamped(to: 0...(displayHeight - 1))
        await runAdb(["shell", "input", "swipe",
            String(fromX), String(fromY),
            String(toX), String(toY), "80"])
    }

    // MARK: - ADB runner

    private static let adbPath: String = {
        // Search common install locations; fall back to PATH lookup via /usr/bin/env
        let candidates = [
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/bin/env"   // fallback: let env resolve it
    }()

    private func runAdb(_ args: [String]) async {
        let (exe, fullArgs): (String, [String]) = {
            let adb = Self.adbPath
            let base = ["-s", adbAddress] + args
            if adb == "/usr/bin/env" {
                return (adb, ["adb"] + base)
            }
            return (adb, base)
        }()
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = fullArgs
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { _ in cont.resume() }
            try? proc.run()
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
