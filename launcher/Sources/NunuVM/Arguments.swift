import Foundation

enum Command {
    case boot
    case version
}

struct Arguments {
    var command: Command = .boot
    var kernel: String = ""
    var initrd: String = ""
    var disks: [String] = []
    var memoryMB: UInt64 = 4096
    var cpuCount: Int = 4
    var adbPort: Int = 5555
    var displayWidth: Int = 1080
    var displayHeight: Int = 1920
    var displayPPI: Int = 420
    var colorProfile: String = "default"  // default | vivid | cinema
    var kernelCmdline: String = ""
    var snapshotPath: String = ""

    var display: DisplayConfig {
        let cal: ColorCalibration
        switch colorProfile {
        case "vivid":  cal = .vivid
        case "cinema": cal = .cinema
        default:       cal = .default
        }
        return DisplayConfig(
            widthPx: displayWidth,
            heightPx: displayHeight,
            ppi: displayPPI,
            colorCalibration: cal
        )
    }

    static func parse() -> Arguments {
        var args = Arguments()
        let raw = Array(CommandLine.arguments.dropFirst())
        var i = 0

        while i < raw.count {
            switch raw[i] {
            case "--version":
                args.command = .version
            case "--kernel":
                i += 1; if i < raw.count { args.kernel = raw[i] }
            case "--initrd":
                i += 1; if i < raw.count { args.initrd = raw[i] }
            case "--disk":
                i += 1; if i < raw.count { args.disks.append(raw[i]) }
            case "--memory":
                i += 1; if i < raw.count { args.memoryMB = UInt64(raw[i]) ?? 4096 }
            case "--cores":
                i += 1; if i < raw.count { args.cpuCount = Int(raw[i]) ?? 4 }
            case "--adb-port":
                i += 1; if i < raw.count { args.adbPort = Int(raw[i]) ?? 5555 }
            case "--display-width":
                i += 1; if i < raw.count { args.displayWidth = Int(raw[i]) ?? 1080 }
            case "--display-height":
                i += 1; if i < raw.count { args.displayHeight = Int(raw[i]) ?? 1920 }
            case "--display-ppi":
                i += 1; if i < raw.count { args.displayPPI = Int(raw[i]) ?? 420 }
            case "--color-profile":
                i += 1; if i < raw.count { args.colorProfile = raw[i] }
            case "--cmdline":
                i += 1; if i < raw.count { args.kernelCmdline = raw[i] }
            case "--snapshot":
                i += 1; if i < raw.count { args.snapshotPath = raw[i] }
            default:
                break
            }
            i += 1
        }

        return args
    }
}
