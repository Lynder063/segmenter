// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Segmenter",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "Segmenter",
            targets: ["Segmenter"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Segmenter",
            dependencies: [],
            path: "Sources/Segmenter",
            resources: []
        )
    ]
)
