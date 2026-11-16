# Metal Graph

When a GPU workload repeats, the application has to manage the same operations, dependencies,
and resources again. Metal Graph lets you describe that work once, prepare an execution plan,
and launch it again over Apple Metal. It keeps the plan and the resources each run needs.
You choose the operations, their order, and when the CPU or another GPU queue may use the result.

<div align="center">
<img width="50%" alt="metalgraph" src="https://github.com/user-attachments/assets/417217a6-048b-4907-ba96-dead3d069642" />
</div>

## Start here

1. [Build and run a small C example](#first-run) that fills and copies a buffer twice.
2. [Learn what the plan reuses](#reuse-the-plan) and when to wait for results.
3. [Connect existing Metal work](#hand-work-to-another-queue) when you need a GPU event handoff.

## Requirements

The native backend targets macOS 15 or newer on Apple Silicon with a real Metal device.
For a CMake build, use:

- CMake 3.20 or newer and a build tool such as Make or Ninja;
- Apple Clang with C11, C++, and Objective-C++ support;
- an Apple macOS SDK with Foundation and Metal, selected through `xcode-select`.

Shader-dependent tests also need Apple's Metal Toolchain. Check it with
`xcrun -sdk macosx metal -v`; with Xcode selected, a missing component can be installed with
`xcodebuild -downloadComponent MetalToolchain`. The examples below use fill and copy commands and need no
shader compiler. CMake reports when it omits shader-dependent tests. Portable core tests
can build without Metal; they do not establish native backend support.

## First run

Start with [fill_copy_replay.c](examples/c/fill_copy_replay.c). It creates two shared buffers,
fills one with the byte `0x2A`, and copies it to the other. An explicit dependency makes the
copy follow the fill. No shader source or external package is needed.

From the repository root:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target metal_graph_fill_copy_example
./build/metal_graph_fill_copy_example
```

Expected output:

```text
Replay 1: all 32 bytes are 0x2A.
Replay 2: all 32 bytes are 0x2A.
```

The example checks every byte after each launch. It clears the destination before replay,
so the second check also needs the GPU work to run.

## Reuse the plan

The example runs twice because preparing work and running it are separate steps:

```text
Graph -> GraphExec -> Launch
```

The **graph** describes operations and dependencies. Instantiation validates it and prepares
an executable snapshot, the **GraphExec**. Each **launch** runs that plan with fresh Metal
command buffers. Reusing the exec avoids rebuilding and planning the graph each time; it
does not promise faster kernels or a speedup for every workload.

Keep the exec when the structure stays the same. For compatible parameter changes, declare
patchable fields before instantiation and patch them between launches. See the
[patch rules](docs/metal_graph_api_spec_v0.md#phase-3-semantics) for supported changes.
Changing the topology requires a new instantiation.

## Wait before using the result

Reuse makes completion matter: the next CPU read or update must not race the previous run.
`mgGraphLaunch` returning `MG_STATUS_OK` means the job was accepted. Encoding, submission,
or GPU execution can still fail later. The example calls `mgLaunchSynchronize` and checks
its result before reading the shared buffer or replaying the exec. Only one launch per exec
may be in flight; callers must serialize operations on the exec and its launches.

Once the plan is ready, you can release the graph used to build it. The exec keeps what it needs.
Accepted work also retains its executable, queue, and resources through terminal completion,
even if their public handles are destroyed early. Destruction does not wait or cancel work.
Keep a launch handle long enough to synchronize and retrieve deferred errors.

For stream order, diagnostics, and failure details, read the
[native runtime contract](docs/metal_graph_api_spec_v0.md#native-launch-and-synchronization-contract).
If you later add optional MPSGraph tensor work, completion that cannot be proven can retain
resources and block later jobs on that stream indefinitely. An error alone does not permit
memory reuse.

## Hand work to another queue

A CPU wait is useful when the CPU needs the result. When another GPU queue needs it, event
nodes can order that handoff. The [shared-event example](examples/metal/shared_event_bridge.mm)
connects an ordinary Metal producer, a Metal Graph plan, and an ordinary Metal consumer:

```sh
cmake --build build --target metal_graph_shared_event_example
./build/metal_graph_shared_event_example
```

The [Metal extension](include/metal_graph/metal_graph_metal.h) wraps a native shared event or
returns the native event behind a Metal Graph event. You assign increasing values for new
producer work and place waits and signals around the work they order. A signal orders the
work before it; it does not report the success of the whole launch.

Before adapting this example, read the
[event ownership and storage rules](docs/metal_graph_api_spec_v0.md#native-metal-shared-event-interoperability)
and [write-ordering limits](docs/metal_graph_api_spec_v0.md#write-ordering-and-manual-hazards).
These explain what the runtime checks and what you must coordinate, including foreign
writers, aliases it cannot observe, and storage-mode transfers.

## Build further

Once the examples work, you can run the wider tests or use another language. The current 0.2.0
library has a C API, a native Metal backend, optional MPSGraph nodes, and a Python adapter. The [API spec](docs/metal_graph_api_spec_v0.md) holds the detailed contracts;
[phase notes](docs/phases/) record how the implementation grew. The API is still evolving.

Build all configured targets and run their tests with:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
```

CMake enables optional MPSGraph support when its frameworks are found. Set
`-DMG_ENABLE_MPSGRAPH=OFF` to build without it. `-DMG_ENABLE_MLX_ADAPTER=OFF` omits the shared
library used by the Python adapter; neither Python nor MLX is needed for the native build.
The [Python guide](bindings/python/README.md) covers adapter setup and examples. MLX zero-copy
import is currently unsupported; explicit `mode="copy"` creates an independent buffer.

[SwiftPM](Package.swift) builds the C/Objective-C++ target as the `MetalGraph` Clang module,
with a Swift import smoke test. The manifest requires Swift tools 5.9 and declares macOS 15
as its floor. Run `swift build` and `swift test` from the repository root. This package does
not enable the optional MPSGraph backend. Ergonomic Swift wrappers and Rust bindings remain
future work.

## License

Apache-2.0. See [LICENSE](LICENSE).
