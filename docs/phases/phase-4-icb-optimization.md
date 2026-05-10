# Phase 4: Dispatch Resource Contracts And ICB Optimization

Branch: `phase-4-icb-optimization`

Status: implemented

## Scope

Phase 4 has two parts:

```text
Phase 4A: dispatch resource contract prework
Phase 4B: optional ICB optimization
```

Phase 4A is required. Phase 4B is an optional backend optimization that must fall back to direct
encoding without changing public behavior.

## Phase 4A: Dispatch Resource Contracts

Phase 4 resolves the dispatch buffer patch range compatibility question.

`mg_buffer_binding_t` remains the concrete binding record:

```text
binding index + buffer + binding offset
```

Dispatch resource requirements are separate metadata:

```text
binding index + access mode + shader-visible byte range + alignment
```

The public descriptor additions are:

- `mg_resource_access_t`
- `mg_dispatch_resource_desc_t`

Dispatch resource requirements are keyed by buffer binding index. They are copied during graph
construction and cloned into `mg_graph_exec_t` during instantiation.

Dispatch buffer binding indices are unique within a dispatch node. Because dispatch resource
contracts are keyed by binding index, allowing duplicate bindings would make the resource contract
ambiguous and could cause patch validation and backend encoding to reason about different effective
bindings. `mgGraphAddDispatchNode` rejects duplicate binding indices.

A dispatch resource descriptor must refer to exactly one existing binding index. Duplicate dispatch
resource descriptors for the same binding index are invalid.

Patchable dispatch buffer bindings require a declared nonzero resource range. Dispatch buffer
patches now validate:

- binding index exists;
- binding was declared patchable;
- replacement buffer is non-null;
- replacement buffer belongs to the same device when device identity is available;
- replacement offset plus declared resource range does not overflow;
- replacement offset plus declared resource range fits inside the replacement buffer;
- replacement offset satisfies the declared alignment.

Non-patchable dispatch bindings may omit resource requirements. Unknown access is allowed, but it
forces conservative ICB fallback.

## Phase 4B: Optional ICB Optimization

Phase 4 adds a narrow internal ICB path for eligible static single-dispatch graph execs.

Earlier design language about dispatch-only groups is reserved for a future extension.
Multi-dispatch execs fall back to direct encoding until dependency-aware grouping and
resource-hazard analysis can prove that indirect command execution preserves direct-encoding
semantics.

ICB is used only when:

- ICB is available on the backend;
- `MG_OPTIMIZATION_ICB` is enabled on the exec;
- the graph exec contains exactly one dispatch node;
- the dispatch has known resource requirements for its buffer bindings;
- the dispatch has no scalar bindings;
- the dispatch has no patchable fields;
- no copy, fill, event, barrier, workspace, MPSGraph, host callback, or other unsupported node
  interrupts the group.

If any requirement is not met, the exec uses direct encoding. A `GraphExec` remains a reusable
host-side execution plan, not a reused `MTLCommandBuffer`; launches still create fresh command
buffers.

## Diagnostics

Phase 4 exposes lightweight diagnostics without exposing Metal objects:

- `mg_optimization_flags_t`
- `MG_OPTIMIZATION_ICB`
- `mg_icb_fallback_reason_t`
- `mg_graph_exec_diagnostics_t`
- `mgGraphExecSetOptimizationFlags`
- `mgGraphExecGetDiagnostics`

Diagnostics report whether ICB is available/enabled, how many groups were planned, how many used
ICB, how many fell back, and the last fallback reason.

## Deferred

- Public exposure of `MTLIndirectCommandBuffer`.
- Per-launch overlays.
- Topology mutation.
- Workspace replanning or liveness-changing updates.
- MPSGraph.
- MLX.
- Python bindings.
- Swift wrappers.
- Rust bindings.
- Multi-queue execution.
- Device-side graph launch.
- Dependency-aware ICB grouping.
- Resource-hazard-aware multi-dispatch ICB eligibility.
- Per-group diagnostics instead of last/global fallback reason.
- Broader dispatch resource contracts for hazard analysis.
