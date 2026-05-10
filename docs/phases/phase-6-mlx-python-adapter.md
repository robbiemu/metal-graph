# Phase 6: MLX Python Adapter

Branch: `phase-6-mlx-python-adapter`

Status: planned

## Scope

- Explore a high-level MLX/Python adapter over the stable C ABI.
- Add Python package scaffolding only after the C ABI has settled.
- Add explicit zero-copy and synchronization semantics.

## Constraints

- MLX must not become the runtime substrate.
- Python must not call Objective-C++ backend internals directly.
- Rust remains future work unless explicitly reprioritized.
