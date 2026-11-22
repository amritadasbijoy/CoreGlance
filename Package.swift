// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoreGlance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CoreGlance", path: "Sources/CoreGlance"),
        .testTarget(name: "CoreGlanceTests", dependencies: ["CoreGlance"], path: "Tests/CoreGlanceTests"),
    ]
)
