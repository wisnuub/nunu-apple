import Foundation

struct VMConfig {
    let kernelPath: String
    let initrdPath: String
    let diskPaths: [String]
    let memoryMB: UInt64
    let cpuCount: Int
    let adbPort: Int
    let display: DisplayConfig
    let kernelCmdline: String
    let snapshotPath: String   // path to save/restore VM state; empty = disabled

    var memoryBytes: UInt64 { memoryMB * 1024 * 1024 }
}
