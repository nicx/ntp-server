// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NTPServer",
    platforms: [.macOS(.v13)],
    targets: [
        // C-Shim: liest den Kernel-NTP-Sync-Status (ntp_adjtime).
        .target(name: "CNTPSync"),
        .executableTarget(
            name: "NTPServer",
            dependencies: ["CNTPSync"],
            path: "Sources/NTPServer"
        )
    ]
)
