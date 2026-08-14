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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.5")
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
        .target(
            name: "OrbitMacAppSupport",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "OrbitMenuBar",
            dependencies: ["OrbitCore", "OrbitMacAppSupport"],
            path: "Sources/OrbitMenuBar",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "OrbitCoreTests",
            dependencies: ["OrbitCore"]
        ),
        .testTarget(
            name: "OrbitMacAppSupportTests",
            dependencies: ["OrbitMacAppSupport"]
        )
    ]
)
