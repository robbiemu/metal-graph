# Phase 1: Copy, Fill, Events, Barriers

Branch: `phase-1-copy-fill-events-barriers`

Status: implemented

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

Barrier nodes are conservative graph ordering nodes in Phase 1. The current single-command-buffer, single-queue backend does not need to encode a public fence command for them; dependency ordering is preserved by the topologically ordered command encoding. This leaves room for `MTLFence`-backed behavior in later phases without exposing Metal types.

All Phase 1 node parameters are frozen at graph instantiation and are not patchable.

`GraphExec` retains all buffers and events needed for relaunch. `mg_launch_t` also retains resources referenced by an in-flight launch so destroying the source graph, exec, or caller-owned event/buffer handles does not invalidate submitted command buffers.

## Constraints

- Keep `MTLSharedEvent` and `MTLFence` private to the Objective-C++ backend.
- Preserve the Phase 0 dispatch graph API.
- Do not add arenas, patch/update semantics, ICB optimization, MPSGraph, MLX, Python, Swift wrappers, or Rust work here.
