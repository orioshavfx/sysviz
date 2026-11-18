// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sysviz",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "sysviz", path: "Sources/sysviz")
    ]
)
