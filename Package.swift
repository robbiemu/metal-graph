// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MetalGraph",
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
                "tests",
            ],
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MetalGraphSwiftSmokeTests",
            dependencies: ["MetalGraph"],
            path: "tests/swift"
        ),
    ]
)
