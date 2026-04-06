// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPorter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MediaPorter",
            path: "MediaPorter/Sources",
            resources: [
                .copy("../Resources/libcig.dylib"),
                .copy("../Resources/grappa.bin"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
