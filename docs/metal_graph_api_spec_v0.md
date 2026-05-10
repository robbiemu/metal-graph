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
- Every fallible API returns `mg_status_t`.
- Detailed diagnostics are returned through `mg_error_t`.
- A graph with a cycle must fail validation with `MG_STATUS_INVALID_TOPOLOGY`.
- Instantiation freezes a snapshot of the graph.
- A launch encodes a fresh `MTLCommandBuffer`.
- Synchronization waits for completion and reports command buffer errors.
- Metal resources referenced by an instantiated graph or launch must remain retained until no longer needed.

## Future Phases

Later phases may add copy/fill/event/barrier nodes, arenas/heaps, patch/update semantics, indirect command buffer optimization, MPSGraph nodes, and MLX/Python adapters. Those capabilities must remain out of the Phase 0 public API.
