// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "listnr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // WhisperKit does not promise API stability across 0.x minors, and the
        // code compiles against 0.18 surface (TranscriptionSegment confidence
        // fields, SpeakerKit's ModelManager). Stay within the tested minor.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.18.0")),
    ],
    targets: [
        .executableTarget(
            name: "listnr",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/Listnr"
        ),
        .testTarget(
            name: "ListnrTests",
            dependencies: ["listnr"],
            path: "Tests/ListnrTests"
        ),
    ]
)
