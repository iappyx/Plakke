// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Plakke",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Plakke",
            path: "Sources/Plakke"
        )
    ]
)
