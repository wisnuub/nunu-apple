import AppKit
import Virtualization

// DisplayConfig holds resolution + DPI + optional color calibration
struct DisplayConfig {
    var widthPx: Int = 1080
    var heightPx: Int = 1920
    var ppi: Int = 420          // ~Pixel 7 density
    var refreshRate: Int = 60
    var colorCalibration: ColorCalibration = .default
}

struct ColorCalibration {
    var brightness: Float = 1.0   // 0.5 – 1.5
    var contrast: Float = 1.0     // 0.5 – 1.5
    var saturation: Float = 1.0   // 0.0 – 2.0
    var redGain: Float = 1.0      // 0.5 – 1.5
    var greenGain: Float = 1.0
    var blueGain: Float = 1.0

    static let `default` = ColorCalibration()

    // Vivid — punchy colors for action games (PUBG, CoD)
    static let vivid = ColorCalibration(
        brightness: 1.05,
        contrast: 1.1,
        saturation: 1.3,
        redGain: 1.0,
        greenGain: 1.0,
        blueGain: 0.95
    )

    // Cinema — accurate colors for RPGs (Genshin, HSR)
    static let cinema = ColorCalibration(
        brightness: 1.0,
        contrast: 1.05,
        saturation: 1.1,
        redGain: 1.0,
        greenGain: 1.0,
        blueGain: 1.02
    )
}

// Makes the VZVirtioGraphicsDeviceConfiguration for the VM
func makeGraphicsDevice(display: DisplayConfig) -> VZVirtioGraphicsDeviceConfiguration {
    let scanout = VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: display.widthPx,
        heightInPixels: display.heightPx
    )
    let device = VZVirtioGraphicsDeviceConfiguration()
    device.scanouts = [scanout]
    return device
}

// VMWindow: an NSWindow that hosts the VZVirtualMachineView + Metal calibration overlay
@MainActor
class VMWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var vmView: NunuVMView?
    private let displayConfig: DisplayConfig

    init(displayConfig: DisplayConfig) {
        self.displayConfig = displayConfig
    }

    func show(vm: VZVirtualMachine) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let logicalW = CGFloat(displayConfig.widthPx) / scale
        let logicalH = CGFloat(displayConfig.heightPx) / scale

        let rect = NSRect(x: 0, y: 0, width: logicalW, height: logicalH)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "nunu"
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        // Lock resize to the display aspect ratio — no black bars when dragging the border
        win.contentAspectRatio = NSSize(width: displayConfig.widthPx, height: displayConfig.heightPx)

        let view = NunuVMView()
        view.vmWindow = self
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.frame = rect
        view.autoresizingMask = [.width, .height]

        // Gesture recognizers for Android multi-touch equivalents
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let swipe = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(swipe)

        win.contentView = view
        win.acceptsMouseMovedEvents = true   // required for VZUSBScreenCoordinatePointingDevice
        win.makeFirstResponder(view)
        self.window = win
        self.vmView = view

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    func requestFrame() {
        vmView?.needsDisplay = true
    }

    func updateTitleForFPSMode(_ enabled: Bool) {
        window?.title = enabled
            ? "nunu  ·  FPS mode  ·  F8 or Esc to release"
            : "nunu"
    }

    // Wire up the FPS delta callback on the inner view.
    // Called by AndroidVM once ADB is ready.
    func setFPSDeltaHandler(_ handler: @escaping (_ dx: CGFloat, _ dy: CGFloat) -> Void) {
        vmView?.onFPSDelta = handler
    }

    // MARK: - Gestures

    // Pinch → Android pinch-to-zoom via ADB multi-touch
    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        // magnification: 0.0 = no change, positive = zoom in, negative = zoom out
        // Forwarded to Android via ADB input injection (see ADBInput)
        let scale = 1.0 + recognizer.magnification
        NotificationCenter.default.post(
            name: .nunuVMPinch,
            object: nil,
            userInfo: ["scale": scale, "state": recognizer.state.rawValue]
        )
    }

    // Two-finger pan → Android scroll
    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard let view = vmView else { return }
        let translation = recognizer.translation(in: view)
        let location = recognizer.location(in: view)
        NotificationCenter.default.post(
            name: .nunuVMScroll,
            object: nil,
            userInfo: [
                "dx": translation.x,
                "dy": translation.y,
                "x": location.x,
                "y": location.y,
                "state": recognizer.state.rawValue,
            ]
        )
        recognizer.setTranslation(.zero, in: view)
    }

    // NSWindowDelegate: placeholder for future window focus handling
    func windowDidResignKey(_ notification: Notification) {}
}

// NunuVMView subclasses VZVirtualMachineView to intercept input events.
//
// Normal mode (default):
//   Cursor moves freely between macOS windows. Clicks and drags inside the
//   VM window are forwarded as absolute touch coordinates — exactly like
//   BlueStacks / MeMu / GameLoop. No cursor locking.
//
// FPS mode (press F8 to toggle):
//   Cursor is locked to the centre of the VM window. macOS mouse deltas are
//   accumulated into a virtual absolute position and sent to Android via ADB
//   input injection. This gives FPS games a camera-control input. Press F8
//   or Escape to release.
@MainActor
class NunuVMView: VZVirtualMachineView {
    weak var vmWindow: VMWindow?

    private(set) var fpsModeEnabled = false

    // Called by AndroidVM to wire up FPS delta → ADB
    var onFPSDelta: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?

    // Accept first-mouse so a click into an unfocused window registers immediately
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    // ── FPS mode toggle ──────────────────────────────────────────────────────

    func enableFPSMode() {
        guard !fpsModeEnabled else { return }
        fpsModeEnabled = true
        CGAssociateMouseAndMouseCursorPosition(0)   // decouple cursor from screen position
        NSCursor.hide()
        warpToCenter()
        vmWindow?.updateTitleForFPSMode(true)
    }

    func disableFPSMode() {
        guard fpsModeEnabled else { return }
        fpsModeEnabled = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        vmWindow?.updateTitleForFPSMode(false)
    }

    private func warpToCenter() {
        guard let win = window else { return }
        let center = win.convertPoint(toScreen: NSPoint(x: bounds.midX, y: bounds.midY))
        // NSScreen uses bottom-left origin; CGWarpMouse uses top-left
        let screenH = NSScreen.main?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: center.x, y: screenH - center.y))
    }

    // ── Key events ───────────────────────────────────────────────────────────

    override func keyDown(with event: NSEvent) {
        // F8 (keyCode 100) toggles FPS mode
        if event.keyCode == 100 {
            fpsModeEnabled ? disableFPSMode() : enableFPSMode()
            return
        }
        // Escape releases FPS mode; otherwise pass to VM
        if event.keyCode == 53 && fpsModeEnabled {
            disableFPSMode()
            return
        }
        super.keyDown(with: event)
    }

    // ── Mouse events — FPS mode only ─────────────────────────────────────────

    override func mouseMoved(with event: NSEvent) {
        if fpsModeEnabled {
            onFPSDelta?(event.deltaX, event.deltaY)
            warpToCenter()
            return   // do NOT call super — prevent VZ sending locked-centre coordinates
        }
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if fpsModeEnabled {
            onFPSDelta?(event.deltaX, event.deltaY)
            warpToCenter()
            return
        }
        super.mouseDragged(with: event)
    }

    // ── Cursor rect (normal mode) ─────────────────────────────────────────────

    override func resetCursorRects() {
        if !fpsModeEnabled {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

// Notification names for gesture events
extension Notification.Name {
    static let nunuVMPinch  = Notification.Name("nunuVMPinch")
    static let nunuVMScroll = Notification.Name("nunuVMScroll")
}
