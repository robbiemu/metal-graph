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

For the native Metal backend:

- macOS 15 or newer on Apple Silicon with a real Metal device
- CMake 3.20+
- Make
- A C11 compiler

Install Apple's Xcode command-line tools and SDKs. Shader-dependent tests also need the
optional Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).
Portable core tests can run without Metal. Native blit, event and lifetime tests do not need
the offline shader compiler; CMake reports when shader-dependent tests are unavailable.

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
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
cmake -S . -B build-no-adapter -DCMAKE_BUILD_TYPE=Debug -DMG_ENABLE_MLX_ADAPTER=OFF
cmake --build build-no-adapter
ctest --test-dir build-no-adapter --output-on-failure
```

## Native event handoffs and launch lifetime

The Metal extension can import and export native shared events. The runnable
[`shared_event_bridge.mm`](examples/metal/shared_event_bridge.mm) example sends work from
an ordinary Metal producer through Metal Graph to an ordinary Metal consumer. It uses only
public headers and Apple frameworks, with no MLX, external adapter, or shader compilation:

```sh
cmake --build build --target metal_graph_shared_event_example
./build/metal_graph_shared_event_example
```

Accepted launches retain their executable, queue and resources until terminal completion,
including after early public-handle destruction. Same-stream jobs execute in whole-job FIFO
order; mixed raw/MPSGraph stages advance from completion callbacks. Synchronize a live launch
to receive deferred errors. `mgLaunchGetDiagnostics` reports explicit synchronization and
requested event ordering; an event count does not prove execution or successful output.

Overlapping writes require dependency ordering inside a graph, including after patches.
Active launches also check observable native allocation ranges. Cross-stream event proofs
are deliberately narrow, and foreign writers or unobservable aliases remain caller-coordinated.
Untracked resources may require fences and direct-encoding fallback. This can reduce overlap;
no performance improvement is claimed. If MPSGraph submission cannot be accounted for, the
runtime reports an error and retains potentially live resources rather than guessing completion.
See the [native runtime contract](docs/metal_graph_api_spec_v0.md#native-launch-and-synchronization-contract).

## ABI Direction

The project starts C-first because it gives the cleanest compatibility path:

- Objective-C can include the headers directly.
- Swift can import the C module via `include/module.modulemap`.
- Python currently uses a thin ctypes adapter; cffi or generated bindings may be added later.
- Rust can bind through `bindgen` or handwritten `extern "C"` declarations later.

The C API uses opaque handles and status codes. Ownership, lifetime, thread-safety, and backend error reporting should be documented before the API is treated as stable.

Phase 10 adds an Apple/Metal-specific extension header for trusted callers that need to wrap an
externally owned `id<MTLBuffer>` as `mg_buffer_t` without copying:

```text
include/metal_graph/metal_graph_metal.h
```

The core `metal_graph.h` header remains framework-neutral. External wraps can be inspected with
`mgBufferGetOriginInfo`; MLX zero-copy remains unsupported until a later phase proves a supported
MLX storage export path or supported shim.

Phase 11 keeps MLX zero-copy in the `unsupported_public_api` state because the public MLX Python
surface does not currently document a stable Metal buffer, byte range, device identity, and lifetime
export that can feed `mgMetalBufferWrap`. The Python adapter reports this as a rejected zero-copy
path, while explicit `mode="copy"` remains available and is labeled as an adapter copy.

## License

Apache-2.0. See [LICENSE](LICENSE).
