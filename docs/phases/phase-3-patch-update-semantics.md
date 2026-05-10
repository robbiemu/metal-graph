# Phase 3: Patch And Update Semantics

Branch: `phase-3-patch-update-semantics`

Status: implemented

## Scope

Phase 3 implements default exec patching:

```text
build graph
instantiate graph once
launch
synchronize
patch compatible default exec state
launch same exec again
```

The public patch model is node ID-based. Patchability is declared during graph construction with
`mgGraphSetNodePatchFlags`, cloned into each `mg_graph_exec_t` during instantiation, and checked
before any exec state is mutated. Changing graph patch flags after instantiation only affects
future execs created from that graph; it does not mutate existing execs.

## Public Additions

- `mg_patch_flags_t`
- `MG_PATCH_DISPATCH_GRID`
- `MG_PATCH_DISPATCH_BUFFER`
- `MG_PATCH_DISPATCH_SCALAR`
- `MG_PATCH_COPY_BUFFER`
- `MG_PATCH_COPY_RANGE`
- `MG_PATCH_FILL_BUFFER`
- `MG_PATCH_FILL_RANGE`
- `MG_PATCH_FILL_VALUE`
- `MG_PATCH_EVENT_VALUE`
- `mg_scalar_binding_t`
- `mgGraphSetNodePatchFlags`
- `mgGraphExecPatchDispatchGrid`
- `mgGraphExecPatchDispatchBuffer`
- `mgGraphExecPatchDispatchScalar`
- `mgGraphExecPatchCopyNode`
- `mgGraphExecPatchFillNode`
- `mgGraphExecPatchEventValue`

## Semantics

- Patches mutate exec default state, not the source graph.
- Patches affect future launches only.
- Patches are rejected while a launch using the exec is in flight.
- Failed patches leave prior exec state intact and usable.
- Dispatch grid patches must stay within the dispatch descriptor's declared `max_grid_size`.
- Dispatch scalar patches must match an existing scalar binding index and byte size.
- Dispatch buffer patches may replace an existing binding buffer and offset when declared patchable.
- Copy patches may update buffers and/or ranges only when the corresponding flags were declared.
- Fill patches may update buffer, range, and/or fill value only when declared.
- Event patches update wait/signal timeline values only.
- Launches still freshly encode `MTLCommandBuffer` objects.

## Deferred

- Per-launch overlays.
- Topology mutation.
- Workspace replanning or liveness-changing updates.
- ICB optimization.
- MPSGraph.
- MLX.
- Python bindings.
- Swift wrappers.
- Rust bindings.
