# Metal Graph

Metal Graph is an early-stage reusable explicit graph execution API over Apple Metal.

The intended public model is:

```text
Graph -> GraphExec -> Launch
```

Applications build a logical graph, instantiate it into a reusable execution plan, patch compatible runtime parameters, and launch that plan repeatedly on a Metal-backed stream.

<div align="center">
<img width="50%" alt="metalgraph" src="https://github.com/user-attachments/assets/417217a6-048b-4907-ba96-dead3d069642" />
</div>

## Current Status

This repository is in early implementation. The core remains centered on a stable C ABI foundation
that Objective-C, Swift, Python, and future Rust layers can build on without reaching into backend
internals.

The first implementation target is a raw Metal backend with:

- opaque C handles for graph/runtime objects;
- Objective-C friendly ownership boundaries;
- Swift import through Clang modules;
- an optional Python adapter over the same C ABI;
- future Rust bindings over the same C ABI;
- command buffers created per launch, not reused as graph executables.

## Repository Layout

```text
include/metal_graph/    Public C headers
src/                    Core implementation
tests/                  Smoke and unit tests
docs/                   Design notes and project decisions
bindings/swift/         Reserved for future Swift package/adapters
bindings/python/        Optional Python adapter over the public C ABI
bindings/rust/          Reserved for future Rust bindings
```

## Requirements

For the current skeleton:

- macOS or another Clang/CMake-capable environment
- CMake 3.20+
- Make
- A C11 compiler

Future Metal work will require Apple platform SDKs and the Metal framework.

## Build

```sh
make configure
make build
make test
```

SwiftPM can also build the C target:

```sh
swift build
swift test
```

Useful maintenance targets:

```sh
make clean
make distclean
```

The optional Python adapter uses a CMake-built shared library and can be tested with:

```sh
uv run pytest
```

Core CMake builds do not require the adapter:

```sh
cmake -S . -B /private/tmp/metal-graph-no-adapter-build -DCMAKE_BUILD_TYPE=Debug -DMG_ENABLE_MLX_ADAPTER=OFF
cmake --build /private/tmp/metal-graph-no-adapter-build
ctest --test-dir /private/tmp/metal-graph-no-adapter-build --output-on-failure
```

## ABI Direction

The project starts C-first because it gives the cleanest compatibility path:

- Objective-C can include the headers directly.
- Swift can import the C module via `include/module.modulemap`.
- Python currently uses a thin ctypes adapter; cffi or generated bindings may be added later.
- Rust can bind through `bindgen` or handwritten `extern "C"` declarations later.

The C API uses opaque handles and status codes. Ownership, lifetime, thread-safety, and backend error reporting should be documented before the API is treated as stable.

## License

Apache-2.0. See [LICENSE](LICENSE).
