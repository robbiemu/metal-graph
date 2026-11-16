# Phase 2: Memory Arenas And Heaps

Branch: `phase-2-memory-arenas-heaps`

Status: implemented

This note records the original phase scope. For current behavior, use the
[API spec](../metal_graph_api_spec_v0.md); later runtime changes are noted below.

## Scope

Phase 2 introduces conservative transient workspace planning without changing the core execution
model:

```text
Graph -> GraphExec -> Launch
```

Public additions are intentionally small:

- opaque `mg_arena_t`
- `mg_arena_desc_t`
- `mgArenaCreate`
- `mgArenaDestroy`
- `mgArenaSize`
- `mgArenaAlignment`
- `mgGraphSetArena`

Workspace requirements are collected during `mgGraphInstantiate`. The graph exec owns the frozen
workspace plan and the backend allocation used for relaunch. Destroying the source graph or
caller-owned arena handle after successful instantiation does not invalidate the graph exec.

Workspace requirement descriptors and workspace-only nodes remain internal in Phase 2. Public
compute or binding APIs for arena-backed temporary resources are deferred until a user-facing node
actually needs them.

Phase 2 uses monotonic, non-overlapping workspace layout. Liveness-based aliasing is deliberately
deferred until a later phase because compactness is less important than predictable correctness at
this stage.

## Backend Behavior

The Apple backend materializes transient workspace as a private Metal buffer owned by
`mg_graph_exec_t`.

`MTLHeap` is deferred. It remains an optional backend allocation strategy, not the public
abstraction and not a correctness requirement. The implementation does not depend on
`MTLResidencySet`, indirect command buffers, MPSGraph, MLX, Python, Swift wrappers, Rust bindings,
multi-GPU, or multi-queue execution.

The GPU integration test uses an internal workspace-backed fill path to prove that planned
workspace is allocated, GPU-visible, retained across launch, and reusable across relaunch. That
internal path is not part of the public C ABI.

The static archive still exposes internal `_mg_*` symbols. A public export list is deferred until a
shared-library/release build needs that boundary.

## Ownership And Lifetime

- `mg_arena_t` is caller-owned and destroyed with `mgArenaDestroy`.
- `mgGraphSetArena` makes the mutable graph retain the arena descriptor.
- `mgGraphInstantiate` makes the graph exec retain the arena descriptor and own its backend
  workspace allocation.
- Arena/workspace memory has no public host pointer and no stable public offset layout.
- Workspace layout may change across independent instantiations.
- Destroy functions do not implicitly synchronize GPU work.
- The original ban on in-flight exec destruction was superseded in 0.2.0. Accepted launches retain
  the exec and workspace through terminal completion after public-handle destruction. This does
  not authorize memory reuse when completion is unproven; see the
  [native runtime contract](../metal_graph_api_spec_v0.md#native-launch-and-synchronization-contract).

## Validation

Phase 2 validates:

- non-null arena and workspace descriptors where required;
- descriptor byte size;
- nonzero workspace byte counts;
- nonzero power-of-two alignments;
- monotonic offset calculation overflow;
- total workspace size overflow;
- attached arena capacity and alignment constraints;
- backend workspace allocation failure through structured `mg_error_t`.

Memory planning failures use `MG_ERROR_STAGE_PLAN_MEMORY`. Backend workspace allocation failures use
`MG_ERROR_STAGE_BACKEND_ALLOCATE`.

## Constraints

- No launch-time allocation/free node semantics.
- No public exposure of `MTLHeap`.
- No public access to arena-backed memory.
- No stable public workspace offsets.
- No liveness-based aliasing yet.
- No patch/update semantics.
- No ICB optimization.
- No MPSGraph.
- No MLX.
- No Python binding.
- No Swift wrapper.
- No Rust binding.
- No multi-GPU or multi-queue execution.
