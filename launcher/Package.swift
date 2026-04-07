// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NunuVM",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NunuVM",
            path: "Sources/NunuVM",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
    ]
)
