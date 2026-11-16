# Swift support

The root [Swift package](../../Package.swift) builds the C/Objective-C++ implementation as the
`MetalGraph` Clang module. Swift callers can `import MetalGraph` and use the public C functions.
The package includes a Swift import/version smoke test, not an ergonomic Swift wrapper.

The manifest requires Swift tools 5.9 and declares macOS 15 as its floor. From the repository root:

```sh
swift build
swift test
```

SwiftPM links Foundation and Metal. It does not enable the optional MPSGraph backend; use CMake
for that configuration. Python is not required. See the [README](../../README.md) for native
build requirements and the graph/exec/launch workflow. Convenience Swift wrappers remain future
work and must preserve the C API's explicit ownership and synchronization rules.
