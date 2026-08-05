// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TopoExplorer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TopoExplorer", targets: ["TopoExplorer"])
    ],
    targets: [
        .executableTarget(
            name: "TopoExplorer",
            path: "Sources/TopoExplorer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SwiftUI"),
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "TopoExplorerTests",
            dependencies: ["TopoExplorer"],
            path: "Tests/TopoExplorerTests"
        )
    ]
)
