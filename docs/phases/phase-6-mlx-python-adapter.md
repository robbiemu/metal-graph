# Phase 6: MLX Python Adapter

Branch: `phase-6-mlx-python-adapter`

Status: implemented

## Scope

- Add a high-level Python adapter over the stable C ABI.
- Keep MLX integration as an optional adapter concern, not the runtime substrate.
- Prove one library-owned shared-buffer workflow end to end.
- Add explicit unsupported errors for MLX zero-copy/import workflows that are not safe yet.

## Constraints

- MLX must not become the runtime substrate.
- Python must not call Objective-C++ backend internals directly.
- Rust remains future work unless explicitly reprioritized.
- The core C library must build and test with `MG_ENABLE_MLX_ADAPTER=OFF`.
- Adapter-only types must not appear in the core public C header.

## Implemented Interface

Phase 6 adds a pure Python `ctypes` adapter under `bindings/python/metal_graph`.

The adapter supports:

- loading the C ABI from `METAL_GRAPH_LIBRARY` or `build/libmetal_graph_shared.dylib`;
- `version()` and `status_string()` helpers;
- RAII-style `Device`, `Stream`, `Buffer`, `Graph`, `GraphExec`, and `Launch` wrappers;
- shared buffer read/write helpers for simple `uint32_t` workflows;
- adding a single-buffer dispatch node with explicit resource metadata;
- launch and synchronization through the existing Metal Graph runtime;
- Python exceptions carrying Metal Graph status, stage, node id, and backend message.

The CMake option `MG_ENABLE_MLX_ADAPTER` controls whether the shared library target used by the
Python adapter is built. Disabling it does not affect the core static C library or C tests.

## Supported Workflow

The Phase 6 workflow is intentionally narrow:

```text
Python creates Metal Graph-owned shared buffers
Python builds an explicit dispatch graph through the C ABI
Metal Graph instantiates and launches the graph
Python reads results from the shared buffer after explicit synchronization
```

## Unsupported Workflows

Phase 6 does not implement:

- zero-copy MLX array import;
- automatic conversion of MLX programs;
- MLX graph capture;
- dynamic-shape tensor compilation;
- Python-owned definitions of graph, exec, launch, or synchronization semantics.

Unsupported MLX workflows fail with adapter-level exceptions instead of falling back silently.
