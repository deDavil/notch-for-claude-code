// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchApp",
            path: "Sources/NotchApp",
            swiftSettings: [
                // Swift 5 language mode: AppKit + Network.framework callbacks predate
                // strict concurrency isolation; v5 keeps this pragmatic without unsafe flags.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
