import Darwin
import Foundation
import Virtualization

// Module-level storage so ARC never closes the pipe or dispatch source
// while the VM is running.
nonisolated(unsafe) private var _consolePipe: Pipe?
nonisolated(unsafe) private var _consoleSource: DispatchSourceFileSystemObject?
nonisolated(unsafe) private var _nullPortPipes: [Pipe] = []

// makeSerialConsole — uses VZVirtioConsoleDeviceSerialPortConfiguration (serialPorts API,
// macOS 11+). This is the API Apple designed for Linux serial console; the framework adds
// the device to the guest DTB stdout-path so earlycon can find it before modules load.
// VZVirtioConsoleDeviceConfiguration (consoleDevices, macOS 13+) is NOT in the DTB
// stdout-path, so earlycon never finds it and early-boot output is lost.
func makeSerialConsole() -> VZVirtioConsoleDeviceSerialPortConfiguration {
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()

    let logPath = "/tmp/nunu-console.log"
    try? FileManager.default.removeItem(atPath: logPath)
    FileManager.default.createFile(atPath: logPath, contents: Data())
    let logURL = URL(fileURLWithPath: logPath)

    // Primary: VZFileSerialPortAttachment writes guest output directly to a file.
    if let att = try? VZFileSerialPortAttachment(url: logURL, append: false) {
        port.attachment = att

        // Tail the log file to stderr via kqueue (NOTE_WRITE fires on any write)
        if let tailFH = FileHandle(forReadingAtPath: logPath) {
            let q = DispatchQueue(label: "nunu.console-tail", qos: .utility)
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: tailFH.fileDescriptor,
                eventMask: .write, queue: q)
            src.setEventHandler {
                let data = tailFH.availableData
                guard !data.isEmpty else { return }
                FileHandle.standardError.write(data)
            }
            src.setCancelHandler { try? tailFH.close() }
            src.resume()
            _consoleSource = src
        }
        fputs("nunu-vm: console → \(logPath) (serialPorts/file)\n", stderr)

    } else {
        // Fallback: pipe stored globally so ARC never closes the fds.
        let pipe = Pipe()
        _consolePipe = pipe

        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null")!,
            fileHandleForWriting: pipe.fileHandleForWriting
        )

        let logFH = FileHandle(forWritingAtPath: logPath)
        let q = DispatchQueue(label: "nunu.console-pipe", qos: .utility)
        q.async {
            let rfd = pipe.fileHandleForReading.fileDescriptor
            fputs("nunu-vm: [console] pipe read thread started fd=\(rfd)\n", stderr)
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(rfd, &buf, buf.count)
                guard n > 0 else {
                    fputs("nunu-vm: [console] pipe closed (n=\(n) errno=\(errno))\n", stderr)
                    break
                }
                let data = Data(buf[..<n])
                FileHandle.standardError.write(data)
                logFH?.write(data)
            }
        }
        fputs("nunu-vm: console → \(logPath) (serialPorts/pipe fallback)\n", stderr)
    }

    return port
}

// makeNullSerialPorts — creates `count` dummy VirtIO serial ports (hvc1..hvcN).
// Each port:
//   - Discards guest writes (fileHandleForWriting → /dev/null)
//   - Blocks guest reads forever (fileHandleForReading → pipe read-end with no writer activity)
// This satisfies Cuttlefish HALs that open hvcN to "connect to the host CVD process":
// they can open the device and write their handshake, giving them time to register
// with servicemanager before blocking on the first read response.
// The pipes are stored globally so ARC never closes the write-end (which would give EOF).
func makeNullSerialPorts(count: Int) -> [VZVirtioConsoleDeviceSerialPortConfiguration] {
    // Each port has no attachment — VZ presents a connected but silent hvcN to the
    // guest (writes are discarded, reads return EOF). This is sufficient for
    // Cuttlefish HALs that just need the device to exist and be openable.
    return (0..<count).map { _ in
        VZVirtioConsoleDeviceSerialPortConfiguration()
    }
}
