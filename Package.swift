// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabGroups",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TabGroups", path: "Sources/TabGroups")
    ]
)
