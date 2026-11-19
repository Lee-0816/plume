// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Plume",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Plume",
            path: "Sources/Plume"
        ),
    ]
)
