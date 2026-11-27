// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Runway",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Runway", targets: ["Runway"]),
        .library(name: "RunwayCore", targets: ["RunwayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .target(name: "RunwayCore"),
        .executableTarget(
            name: "Runway",
            dependencies: ["RunwayCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "RunwayCoreTests", dependencies: ["RunwayCore"]),
    ]
)
