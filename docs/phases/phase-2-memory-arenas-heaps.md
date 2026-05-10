# Phase 2: Memory Arenas And Heaps

Branch: `phase-2-memory-arenas-heaps`

Status: planned

## Scope

- Add transient arena descriptors.
- Add instantiation-time liveness planning.
- Add heap-backed allocation where supported.
- Add conservative fallbacks when heaps are unavailable or inappropriate.
- Add tests for alignment, liveness, and resource lifetime.

## Constraints

- No launch-time allocation/free node semantics.
- No public exposure of `MTLHeap`.
- No ICB, MPSGraph, MLX, Python, or Rust work here.
