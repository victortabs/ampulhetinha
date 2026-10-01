// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ampulhetinha",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ampulhetinha",
            path: "Sources/Ampulhetinha"
        )
    ]
)
