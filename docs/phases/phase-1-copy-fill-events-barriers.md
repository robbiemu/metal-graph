# Phase 1: Copy, Fill, Events, Barriers

Branch: `phase-1-copy-fill-events-barriers`

Status: planned

## Scope

- Add copy nodes.
- Add fill nodes.
- Add event wait/signal nodes.
- Add barrier/fence semantics.
- Extend conformance tests for ordering, synchronization, and failure propagation.

## Constraints

- Keep `MTLSharedEvent` and `MTLFence` private to the Objective-C++ backend.
- Preserve the Phase 0 dispatch graph API.
- Do not add arenas, patching, ICB, MPSGraph, MLX, Python, or Rust work here.
