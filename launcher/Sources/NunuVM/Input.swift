import AppKit
import Virtualization

// Keyboard configuration — USB HID keyboard routed directly to Android
func makeKeyboards() -> [VZKeyboardConfiguration] {
    [VZUSBKeyboardConfiguration()]
}

// Pointing device — absolute screen coordinates.
// Android sees this as a digitizer/touchscreen device.
// Mouse cursor overlay is handled via ADB input injection (see ADBInput).
func makePointingDevices() -> [VZPointingDeviceConfiguration] {
    [VZUSBScreenCoordinatePointingDeviceConfiguration()]
}

// TouchCoordinateConverter maps a macOS view point (origin bottom-left, points)
// to Android screen coordinates (origin top-left, pixels).
struct TouchCoordinateConverter {
    let viewSize: CGSize
    let displayWidth: Int
    let displayHeight: Int

    func convert(_ point: NSPoint) -> (x: Int, y: Int) {
        // NSView origin is bottom-left; Android origin is top-left
        let normX = point.x / viewSize.width
        let normY = 1.0 - (point.y / viewSize.height)  // flip Y

        let x = Int((normX * CGFloat(displayWidth)).clamped(to: 0...CGFloat(displayWidth - 1)))
        let y = Int((normY * CGFloat(displayHeight)).clamped(to: 0...CGFloat(displayHeight - 1)))
        return (x, y)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// CursorState manages cursor capture for gaming.
// When captured: cursor is hidden and locked, mouse delta drives game camera.
// Press Cmd+Escape to release (standard convention, same as virtual machines).
@MainActor
class CursorState {
    private(set) var captured = false
    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }

    func capture() {
        guard !captured else { return }
        captured = true
        CGAssociateMouseAndMouseCursorPosition(0)  // decouple cursor from position
        NSCursor.hide()
    }

    func release() {
        guard captured else { return }
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    // Returns true if the event was consumed (cursor toggle)
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Cmd+Escape releases cursor capture
        if event.modifierFlags.contains(.command) && event.keyCode == 53 {
            release()
            return true
        }
        return false
    }
}
