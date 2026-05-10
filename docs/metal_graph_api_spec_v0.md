# Metal Graph API Spec v0

This document captures the repository-local Phase 0 contract for Metal Graph. It is intentionally narrower than the broader research/specification notes and should be expanded as phases land.

## Model

The public execution model is:

```text
Graph -> GraphExec -> Launch
```

- `mg_graph_t` is a mutable logical DAG.
- `mg_graph_exec_t` is an instantiated, topologically frozen execution plan.
- `mg_launch_t` is one concrete launch using fresh Metal command buffers.

`mg_graph_exec_t` is not a reusable `MTLCommandBuffer`.

## Phase 0 Public Surface

Phase 0 exposes only the minimum C ABI needed for raw Metal dispatch graphs:

- version and status helpers;
- structured error handles;
- opaque device, stream, buffer, graph, node, graph exec, and launch handles;
- system default Metal device creation;
- stream creation over a Metal command queue;
- shared Metal buffer creation for tests and simple host-visible data paths;
- graph creation and destruction;
- dispatch node creation from a metallib path and kernel name;
- dependency insertion;
- topology validation;
- graph instantiation;
- graph launch and synchronization.

Phase 0 must not expose Objective-C, Swift, C++ STL, Metal framework types, indirect command buffers, MPSGraph, MLX, Python, or Rust types in public headers.

## Phase 0 Semantics

- Public headers must compile as C and C++.
- Public C functions use `mg`-prefixed camelCase names. Public types, structs, and enum values use the existing `mg_*` / `MG_*` C naming style.
- Every fallible API returns `mg_status_t`.
- Detailed diagnostics are returned through `mg_error_t`.
- A graph with a cycle must fail validation with `MG_STATUS_INVALID_TOPOLOGY`.
- Self-dependencies fail during dependency insertion with `MG_STATUS_INVALID_TOPOLOGY`.
- Duplicate dependencies are accepted as idempotent no-ops.
- Empty graphs are valid no-op graphs.
- Instantiation freezes a snapshot of the graph.
- A launch encodes a fresh `MTLCommandBuffer`.
- Synchronization waits for completion and reports command buffer errors.
- Metal resources referenced by an instantiated graph or launch must remain retained until no longer needed.

## Future Phases

## Phase 1 Public Surface

Phase 1 adds:

- copy nodes;
- 8-bit fill nodes;
- timeline event creation/destruction;
- event wait/signal nodes;
- conservative barrier nodes.

Phase 1 remains single-device and single-queue oriented. Events are backed by `MTLSharedEvent` on Apple platforms. Barrier nodes preserve graph ordering but do not claim full multi-queue or cross-encoder hazard semantics.

Phase 1 does not add arenas/heaps, patch/update semantics, indirect command buffer optimization, MPSGraph nodes, MLX, Python bindings, Swift wrappers, or Rust bindings.

## v1 Intent

v1 targets macOS 15.0+ on Apple Silicon. The required backend path is raw Metal compute/blit execution with freshly encoded command buffers and `MTLSharedEvent` timeline events. Optional features such as residency sets, ICBs, MPSGraph, Metal 4 APIs, iOS/iPadOS, and Python/MLX adapters must remain optional unless a future API explicitly requires them.

v1 uses caller-side synchronization. Graphs are mutable and not thread-safe. Graph execs are immutable and reusable after completion, but only one in-flight launch per exec is valid in v1. Destroying an exec or stream while a launch using it is in flight is invalid.

Public ownership is create/destroy. Graph execs must retain/copy the buffers, events, descriptors, and backend objects needed for relaunch after source graph, descriptor, buffer handle, or event handle destruction. Descriptors are borrowed only for the duration of API calls.

## Future Phases

Later phases may add arenas/heaps, patch/update semantics, indirect command buffer optimization, MPSGraph nodes, and MLX/Python adapters.
