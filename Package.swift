// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
        .executable(name: "orbit", targets: ["OrbitCLI"]),
        .executable(name: "orbit-menubar", targets: ["OrbitMenuBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "OrbitCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "OrbitCLI",
            dependencies: ["OrbitCore"],
            path: "Sources/OrbitCLI"
        ),
        .executableTarget(
            name: "OrbitMenuBar",
            dependencies: ["OrbitCore"],
            path: "Sources/OrbitMenuBar"
        ),
        .testTarget(
            name: "OrbitCoreTests",
            dependencies: ["OrbitCore"]
        )
    ]
)
