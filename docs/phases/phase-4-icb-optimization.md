# Phase 4: ICB Optimization

Branch: `phase-4-icb-optimization`

Status: planned

## Scope

- Add optional internal `MTLIndirectCommandBuffer` use for compatible static dispatch groups.
- Add feature detection and fallback paths.
- Add benchmarks comparing direct encoding and ICB-backed encoding.

## Constraints

- Do not expose ICBs in public headers.
- ICB must be an optimization only; semantics must match earlier phases.
- No MPSGraph, MLX, Python, or Rust work here.
