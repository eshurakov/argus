// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArgusCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "argus", targets: ["ArgusCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        // Wire contract shared with the Argus application target, which
        // compiles the same sources directly (see project.yml).
        .target(
            name: "ArgusIPC",
            path: "ArgusIPC"
        ),
        .target(
            name: "ArgusCLICore",
            dependencies: [
                "ArgusIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "ArgusCLICore"
        ),
        .executableTarget(
            name: "ArgusCLI",
            dependencies: ["ArgusCLICore"],
            path: "ArgusCLI"
        ),
        .testTarget(
            name: "ArgusCLICoreTests",
            dependencies: ["ArgusCLICore", "ArgusIPC"],
            path: "ArgusCLICoreTests"
        )
    ]
)
