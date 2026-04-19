// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPorter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaPorterCore", targets: ["MediaPorterCore"]),
        .executable(name: "mediaporterctl", targets: ["mediaporterctl"]),
        .executable(name: "MediaPorter", targets: ["MediaPorter"]),
    ],
    targets: [
        .target(
            name: "MediaPorterCore",
            path: "MediaPorter/Sources",
            resources: [
                .copy("../Resources/libcig.dylib"),
                .copy("../Resources/grappa.bin"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "mediaporterctl",
            dependencies: ["MediaPorterCore"],
            path: "CLI/Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "MediaPorter",
            dependencies: ["MediaPorterCore"],
            path: "App/Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "MediaPorterCoreTests",
            dependencies: ["MediaPorterCore"],
            path: "Tests/MediaPorterCoreTests"
        ),
    ]
)
