# Phase 0: Raw Metal Dispatch Graph

Branch: `phase-0-raw-metal-dispatch-graph`

Status: implemented

## Scope

- C ABI skeleton
- opaque public handles
- raw Metal backend behind Objective-C++
- device creation
- stream/queue creation
- shared buffer creation for Phase 0 dispatch tests
- graph creation/destruction
- dispatch node creation
- dependency insertion
- topology validation
- empty graph no-op behavior
- duplicate dependency idempotence
- graph instantiation
- launch by freshly encoding `MTLCommandBuffer`
- synchronization
- structured errors
- unit tests for graph construction and invalid topology
- real Metal integration test for a simple compute kernel on Apple Silicon

## Explicit Non-Scope

- copy/fill nodes
- event wait/signal nodes
- barrier/fence semantics beyond single-command-buffer dispatch ordering
- memory arenas and heaps
- patch/update semantics
- `MTLIndirectCommandBuffer`
- MPSGraph
- MLX
- Python or Rust bindings

## Exit Criteria

- CMake build succeeds.
- C unit tests pass.
- Metal integration test builds a metallib and launches a compute kernel.
- SwiftPM still builds and imports the public C target.
- Public headers remain free of Objective-C++ and Metal types.
