// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "nobeachballs",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "nobeachballs", targets: ["NoBeachballs"]),
    ],
    targets: [
        .target(name: "NoBeachballsCore"),
        .executableTarget(name: "NoBeachballs", dependencies: ["NoBeachballsCore"]),
        .testTarget(name: "NoBeachballsCoreTests", dependencies: ["NoBeachballsCore"]),
        .testTarget(name: "NoBeachballsTests", dependencies: ["NoBeachballs"]),
    ]
)
