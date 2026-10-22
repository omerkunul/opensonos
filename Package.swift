// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "opensonos",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SonosKit", targets: ["SonosKit"]),
        .executable(name: "opensonos", targets: ["OpenSonosCLI"]),
        .executable(name: "opensonos-mcp", targets: ["OpenSonosMCP"]),
    ],
    targets: [
        // Vendored fixed-point MP3 encoder (shine, LGPL v2). Apple platforms can't encode MP3
        // themselves, and gen-1 Sonos only plays Streaming MP3 over x-rincon-mp3radio.
        .target(name: "CShine"),
        .target(name: "SonosKit", dependencies: ["CShine"]),
        .executableTarget(name: "OpenSonosCLI", dependencies: ["SonosKit"]),
        .executableTarget(name: "OpenSonosMCP", dependencies: ["SonosKit"]),
        .testTarget(
            name: "SonosKitTests",
            dependencies: ["SonosKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "OpenSonosMCPTests", dependencies: ["OpenSonosMCP"]),
    ]
)
