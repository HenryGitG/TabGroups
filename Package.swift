// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabGroups",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "TabGroups",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/TabGroups",
            // The app bundle keeps Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
