// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Baud",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BaudCore"),
        .executableTarget(name: "Baud", dependencies: ["BaudCore"]),
        .executableTarget(name: "BaudChecks", dependencies: ["BaudCore"]),
    ]
)
