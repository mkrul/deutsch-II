// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Translate",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "Translate",
            path: "Sources/Translate",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
