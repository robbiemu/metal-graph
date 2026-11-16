# Phase 1: Copy, Fill, Events, Barriers

Branch: `phase-1-copy-fill-events-barriers`

Status: implemented

This note records the original phase scope. For current behavior, use the
[API spec](../metal_graph_api_spec_v0.md); later runtime changes are noted below.

## Scope

- Add copy nodes over explicit source/destination buffer byte ranges.
- Add 8-bit fill nodes over explicit destination buffer byte ranges.
- Add timeline event creation/destruction.
- Add event wait/signal nodes.
- Add conservative barrier nodes.
- Extend unit and GPU integration tests for validation, ordering, relaunch, and resource lifetime.

## Semantics

Phase 1 remains single-device and single-queue oriented.

Copy nodes are encoded as Metal blit copies on Apple platforms. Fill nodes are encoded as Metal blit fills with an 8-bit repeated value. Event nodes are timeline-style and backed by `MTLSharedEvent` on Apple platforms. Unsupported backends return `MG_STATUS_UNSUPPORTED` for event creation and backend execution.

Barrier nodes are conservative graph ordering nodes. Phase 1 used one command buffer and queue.
The current backend may segment work and use internal fences for manual hazards; no public fence
object is exposed. See [write ordering](../metal_graph_api_spec_v0.md#write-ordering-and-manual-hazards).

Phase 1 introduced frozen node parameters. Phase 3 later added patches for fields declared
patchable before instantiation; see the [patch rules](../metal_graph_api_spec_v0.md#phase-3-semantics).

`GraphExec` retains the buffers and events needed for relaunch. The original prohibition on
in-flight exec or stream destruction was superseded in 0.2.0: accepted launches retain their
executable, queue, and resources through terminal completion after public-handle destruction.
Destruction does not wait or cancel work. Keep a live launch handle to retrieve deferred errors.
See the [native runtime contract](../metal_graph_api_spec_v0.md#native-launch-and-synchronization-contract).

## Constraints

- Keep `MTLSharedEvent` and `MTLFence` private to the Objective-C++ backend.
- Preserve the Phase 0 dispatch graph API.
- Do not add arenas, patch/update semantics, ICB optimization, MPSGraph, MLX, Python, Swift wrappers, or Rust work here.
