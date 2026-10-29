// swift-tools-version:6.0
// Vendored from SwiftTerm 1.20.0 (MIT). The Command Line Tools do not ship `metal`,
// so Shaders.metal lives in ShaderSource.swift as a string compiled at runtime.

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
            exclude: ["Mac/README.md"],
            plugins: [
                .plugin(name: "SwiftTermBuildInfoPlugin"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
