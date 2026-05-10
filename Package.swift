// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MetalGraph",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(
            name: "MetalGraph",
            targets: ["MetalGraph"]
        ),
    ],
    targets: [
        .target(
            name: "MetalGraph",
            path: ".",
            exclude: [
                ".gitignore",
                "CMakeLists.txt",
                "LICENSE",
                "Makefile",
                "README.md",
                "bindings",
                "build",
                "docs",
                "src/shaders",
                "src/metal/unsupported_backend.c",
                "tests",
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "MetalGraphSwiftSmokeTests",
            dependencies: ["MetalGraph"],
            path: "tests/swift"
        ),
    ]
)
