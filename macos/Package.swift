// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EgressAtlas",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EgressAtlas", targets: ["EgressAtlas"]),
    ],
    targets: [
        .executableTarget(
            name: "EgressAtlas",
            path: "Sources/EgressAtlas",
            resources: [
                // The MSL is compiled at launch so the same source can be
                // iterated on without a full Metal build step.
                .copy("Render/Shaders.metal"),
                // Brand-identity exports (supplied artwork, no retracing).
                .copy("Resources"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
