// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DisplayTuner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DisplayTunerCore", targets: ["DisplayTunerCore"])
    ],
    targets: [
        .target(
            name: "DisplayTunerCore",
            path: "Sources/DisplayTunerCore"
        ),
        .testTarget(
            name: "DisplayTunerCoreTests",
            dependencies: ["DisplayTunerCore"],
            path: "Tests/DisplayTunerCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
