// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Runway",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Runway", targets: ["Runway"]),
        .library(name: "RunwayCore", targets: ["RunwayCore"]),
    ],
    targets: [
        .target(name: "RunwayCore"),
        .executableTarget(name: "Runway", dependencies: ["RunwayCore"]),
        .testTarget(name: "RunwayCoreTests", dependencies: ["RunwayCore"]),
    ]
)
