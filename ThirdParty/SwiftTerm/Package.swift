// swift-tools-version:6.0
// Vendored from SwiftTerm 1.20.0 (MIT). The Metal shader is excluded because
// the Command Line Tools do not ship `metal`. Aether uses the CoreGraphics renderer.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),
        .target(
            name: "AetherSpawn",
            path: "Sources/AetherSpawn"
        ),
        .target(
            name: "SwiftTerm",
            dependencies: ["AetherSpawn"],
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"],
            plugins: [
                .plugin(name: "SwiftTermBuildInfoPlugin"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
