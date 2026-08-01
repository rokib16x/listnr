// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "listnr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "listnr", targets: ["listnr"]),
        // The CLI logic lives in a library so it can be imported. The test
        // target needs that, and so will the menubar app on the roadmap: an
        // executable target cannot be a dependency of anything.
        .library(name: "ListnrCore", targets: ["ListnrCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // WhisperKit does not promise API stability across 0.x minors, and the
        // code compiles against 0.18 surface (TranscriptionSegment confidence
        // fields, SpeakerKit's ModelManager). Stay within the tested minor.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.18.0")),
    ],
    targets: [
        .target(
            name: "ListnrCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/ListnrCore"
        ),
        // Deliberately just `Listnr.main()`. Everything testable stays in the
        // library; nothing here can be reached by a test.
        .executableTarget(
            name: "listnr",
            dependencies: ["ListnrCore"],
            path: "Sources/listnr"
        ),
        .testTarget(
            name: "ListnrTests",
            dependencies: ["ListnrCore"],
            path: "Tests/ListnrTests"
        ),
    ]
)
