// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabGroups",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "TabGroups",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/TabGroups",
            resources: [.process("Resources")],
            // Sparkle.framework: in Contents/Frameworks of the app bundle,
            // next to the binary for `swift run`.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
