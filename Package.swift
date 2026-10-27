// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Aether",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Aether", targets: ["Aether"]),
    ],
    dependencies: [
        // Vendored so the app builds with Command Line Tools, which do not ship the Metal compiler.
        // The terminal uses SwiftTerm's CoreGraphics renderer. See ThirdParty/SwiftTerm.
        .package(path: "ThirdParty/SwiftTerm"),
    ],
    targets: [
        .target(
            name: "AetherKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "Aether",
            dependencies: ["AetherKit"]
        ),
        .testTarget(
            name: "AetherTests",
            dependencies: [
                "AetherKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)
