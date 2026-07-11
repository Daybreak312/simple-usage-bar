// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SimpleUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "usagebar",
            path: "Sources/UsageBar"
        )
    ]
)
