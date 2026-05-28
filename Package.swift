// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuickTranscript",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "quick-transcript", targets: ["QuickTranscript"])
    ],
    targets: [
        .executableTarget(
            name: "QuickTranscript",
            path: "QuickTranscript/Sources/QuickTranscript"
        )
    ]
)
