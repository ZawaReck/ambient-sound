// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AmbientSound",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AmbientSound",
            path: "Sources/AmbientSound"
        )
    ],
    swiftLanguageVersions: [.v5]
)
