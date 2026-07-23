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
    dependencies: [
        .package(url: "https://github.com/virtualox/vlckit-spm", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Segmenter",
            dependencies: [
                .product(name: "VLCKitSPM", package: "vlckit-spm")
            ],
            path: "Sources/Segmenter",
            resources: []
        )
    ]
)




