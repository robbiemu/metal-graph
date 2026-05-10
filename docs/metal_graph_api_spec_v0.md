# Metal Graph API Spec v0

This document captures the repository-local Phase 0-3 contract for Metal Graph. It is intentionally narrower than the broader technical specification and should be expanded as phases land.

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
- Public C functions use `mg`-prefixed camelCase names. Public types, structs, and enum values use the existing `mg_*` / `MG_*` C naming style.
- The public header must not expose duplicate snake_case aliases for public functions.
- Every fallible API returns `mg_status_t`.
- Detailed diagnostics are returned through `mg_error_t`.
- A graph with a cycle must fail validation with `MG_STATUS_INVALID_TOPOLOGY`.
- Self-dependencies fail during dependency insertion with `MG_STATUS_INVALID_TOPOLOGY`.
- Duplicate dependencies are accepted as idempotent no-ops.
- Empty graphs are valid no-op graphs.
- Instantiation freezes a snapshot of the graph.
- A launch encodes a fresh `MTLCommandBuffer`.
- Synchronization waits for completion and reports command buffer errors.
- Metal resources referenced by an instantiated graph or launch must remain retained until no longer needed.

## Phase 1 Public Surface

Phase 1 adds:

- copy nodes;
- 8-bit fill nodes;
- timeline event creation/destruction;
- event wait/signal nodes;
- conservative barrier nodes.

Phase 1 remains single-device and single-queue oriented. Events are backed by `MTLSharedEvent` on Apple platforms. Barrier nodes preserve graph ordering but do not claim full multi-queue or cross-encoder hazard semantics.

Phase 1 does not add arenas/heaps, patch/update semantics, indirect command buffer optimization, MPSGraph nodes, MLX, Python bindings, Swift wrappers, or Rust bindings.

## Phase 1 Semantics

- Copy and fill ranges must be bounds-checked without relying on wrapping `offset + size` arithmetic.
- Event creation returns `MG_STATUS_UNSUPPORTED` on unsupported backends.
- Phase 1 node parameters are frozen at instantiation and are not patchable.
- `mg_graph_exec_t` retains buffers and events required for relaunch.
- Destroying the source graph, source buffer handles, or source event handles after successful instantiation must not invalidate the graph exec.
- Destroying a graph exec or stream while a launch using it is in flight remains invalid v1 caller behavior.

## Phase 2 Public Surface

Phase 2 adds conservative memory planning:

- opaque `mg_arena_t` handles;
- `mg_arena_desc_t` for arena capacity/alignment;
- `mgArenaCreate`, `mgArenaDestroy`, `mgArenaSize`, and `mgArenaAlignment`;
- `mgGraphSetArena` for attaching an optional caller-owned arena descriptor to a graph.

Workspace requirement descriptors and workspace-only nodes are internal in Phase 2. Public compute or binding APIs for arena-backed temporary resources are deferred until a user-facing node actually needs them.

Arena descriptors use the same public naming convention as prior phases: `mgCamelCase` functions, `mg_*_t` public types/descriptors, and `MG_UPPER_SNAKE_CASE` enums/constants.

Phase 2 does not expose Objective-C, Swift, C++, Metal framework types, `MTLHeap`, `MTLResidencySet`, ICBs, MPSGraph, MLX, Python, or Rust types in public headers.

## Phase 2 Semantics

- Workspace requirements are planned during `mgGraphInstantiate`.
- Phase 2 uses monotonic, non-overlapping workspace layout. Liveness-based aliasing is reserved for a future optimization.
- Arena layout and workspace offsets are not public and are not stable across instantiations.
- Arena-backed memory has no caller-visible host pointer and cannot be accessed directly through the public C ABI.
- Workspace-only nodes encode no public compute operation and are not public API in Phase 2.
- `mg_graph_exec_t` owns or retains the workspace plan, arena descriptor reference, and backend workspace allocation required for relaunch.
- Destroying the source graph or caller-owned arena handle after successful instantiation must not invalidate the graph exec.
- Memory planning errors use `MG_ERROR_STAGE_PLAN_MEMORY`; backend workspace allocation failures use `MG_ERROR_STAGE_BACKEND_ALLOCATE`.
- Launch-time alloc/free node semantics are not implemented.
- `MTLHeap` is an optional backend allocation strategy. The Phase 2 implementation may use regular `MTLBuffer` allocations, and correctness must not depend on `MTLHeap` or `MTLResidencySet`.
- Patch/update semantics, ICB optimization, MPSGraph nodes, MLX integration, Python bindings, Swift wrappers, Rust bindings, multi-GPU, and multi-queue execution remain out of scope.

## Phase 3 Public Surface

Phase 3 adds default exec patching for compatible runtime updates:

- `mg_patch_flags_t` and `MG_PATCH_*` flags;
- `mg_scalar_binding_t` for small dispatch scalar arguments copied into graph/exec state;
- `mgGraphSetNodePatchFlags` to declare patchability during graph construction;
- node ID-based patch APIs for dispatch grid, dispatch buffer bindings, dispatch scalars, copy nodes, fill nodes, and event values.

Patch APIs use `mgCamelCase` public function names and do not expose Metal, Objective-C, Swift, C++, MPSGraph, MLX, Python, Rust, or ICB types.

## Phase 3 Semantics

- Patches mutate `mg_graph_exec_t` default state, not source `mg_graph_t` state.
- Successful patches affect future launches only.
- Patches are rejected while a launch using the exec is in flight.
- Failed patches leave the previous exec state usable.
- Patchability must be declared with `mgGraphSetNodePatchFlags` before the target exec is
  instantiated. Changing graph patch flags later affects future instantiations only.
- Patch APIs address instantiated nodes by `mg_node_id_t`.
- Dispatch grid patches must stay within the descriptor's declared `max_grid_size`.
- Dispatch scalar patches must use an existing scalar binding index and exactly the original scalar byte size.
- Buffer and range patches must remain compatible with existing node kind semantics and buffer bounds.
- Copy/fill range checks avoid wrapping `offset + size` arithmetic.
- Event patching updates timeline wait/signal values only, not the event object.
- Topology-changing updates require reinstantiation.
- Workspace/liveness-changing updates require reinstantiation.
- Per-launch overlays are deferred and have no public API in Phase 3.
- ICB optimization, MPSGraph nodes, MLX integration, Python bindings, Swift wrappers, Rust bindings, multi-GPU, and multi-queue execution remain out of scope.

## Phase 4 Public Surface

Phase 4 adds dispatch resource contracts and optional ICB diagnostics:

- `mg_resource_access_t` with read, write, read-write, and unknown access modes;
- `mg_dispatch_resource_desc_t` for dispatch resource requirements keyed by buffer binding index;
- `mg_optimization_flags_t` and `MG_OPTIMIZATION_ICB`;
- `mg_graph_exec_diagnostics_t` and ICB fallback reason values;
- `mgGraphExecSetOptimizationFlags`;
- `mgGraphExecGetDiagnostics`.

`mg_buffer_binding_t` remains a lightweight concrete buffer-plus-offset binding record. Dispatch
resource requirements are separate metadata that describe shader-visible byte ranges, access modes,
and alignment constraints.

Dispatch buffer binding indices are unique within one dispatch node. Because dispatch resource
contracts are keyed by binding index, duplicate bindings would make resource contracts, patch
validation, and backend encoding ambiguous. `mgGraphAddDispatchNode` rejects duplicate dispatch
buffer binding indices.

## Phase 4 Semantics

- Dispatch resource contracts are copied into graph nodes and cloned into graph execs during
  instantiation.
- A dispatch resource descriptor must refer to exactly one existing dispatch buffer binding index.
  Duplicate dispatch resource descriptors for the same binding index are invalid.
- Non-patchable dispatch bindings may omit resource requirements, but unknown or missing
  requirements force conservative backend behavior.
- Patchable dispatch buffer bindings require a declared nonzero resource range.
- Dispatch buffer patches must use an existing binding index, a non-null replacement buffer, the
  same device, an aligned binding offset, and a replacement buffer large enough for the declared
  resource range.
- Unknown access is valid metadata, but it is conservative and makes ICB eligibility fail.
- ICB is optional. If ICB is disabled, unsupported, or unsafe, the exec remains valid and launches
  through direct encoding.
- ICB eligibility is conservative: Phase 4 intentionally limits ICB use to execs containing one
  eligible static dispatch node with known resource ranges, known access modes, no scalar bindings,
  and no patchable dispatch fields. Earlier design language about dispatch-only groups is reserved
  for a future extension. Multi-dispatch ICB groups are deferred until dependency-aware grouping and
  resource-hazard analysis can prove they preserve direct-encoding semantics.
- Public behavior must be identical with ICB enabled or disabled. Launches still create fresh Metal
  command buffers.
- Phase 4 does not expose `MTLIndirectCommandBuffer`, MPSGraph, MLX, Python, Swift wrappers, Rust,
  per-launch overlays, topology mutation, workspace replanning, multi-queue execution, or
  device-side graph launch.

## v1 Intent

v1 targets macOS 15.0+ on Apple Silicon. The required backend path is raw Metal compute/blit execution with freshly encoded command buffers and `MTLSharedEvent` timeline events. Optional features such as residency sets, ICBs, MPSGraph, Metal 4 APIs, iOS/iPadOS, and Python/MLX adapters must remain optional unless a future API explicitly requires them.

v1 uses caller-side synchronization. Graphs are mutable and not thread-safe. Graph execs are immutable and reusable after completion, but only one in-flight launch per exec is valid in v1. Destroying an exec or stream while a launch using it is in flight is invalid.

Public ownership is create/destroy. Graph execs must retain/copy the buffers, events, arena descriptors, workspace plans, patch tables, descriptors, scalar values, and backend objects needed for relaunch after source graph, descriptor, buffer handle, event handle, or arena handle destruction. Descriptors are borrowed only for the duration of API calls.

## Future Phases

Later phases may add broader patch overlays, fuller hazard analysis, MPSGraph nodes, Python/MLX
adapters, Swift convenience wrappers, and Rust bindings. Future phases must preserve the Phase 0-4
naming convention and behavior unless an explicit API version change says otherwise.

Future ICB work includes dependency-aware grouping, resource-hazard-aware multi-dispatch
eligibility, per-group diagnostics, and broader dispatch resource contracts for hazard analysis.

## Phase 5 Direction

Phase 5 integrates MPSGraph as an optional tensor-subgraph island inside a Metal Graph execution
plan. Metal Graph remains the outer orchestration layer for topology, dependencies, launch
lifecycle, resource retention, synchronization boundaries, errors, diagnostics, and fallback
behavior. MPSGraph owns tensor subgraph representation, tensor operation lowering, shape/dtype/layout
constraints, and execution details internal to the MPSGraph executable.

The public model remains:

```text
Graph -> GraphExec -> Launch
```

Phase 5 must prove that Metal Graph can safely schedule an MPSGraph island alongside raw Metal
dispatch/copy/fill/event/barrier work. It must not reimplement MPSGraph, convert arbitrary MLX
programs, optimize tensor graphs, or make MPSGraph the public runtime substrate.

MPSGraph support is optional and feature-gated. Pure tensor workloads may use MPSGraph directly.
Mixed workloads may use Metal Graph to orchestrate raw Metal nodes and MPSGraph nodes together.
Native MPSGraph objects must not appear in the core public C header; if native-object interop is
needed, it should live behind an explicit Objective-C extension boundary or another deliberately
separate adapter.

The Phase 5 C ABI uses descriptor metadata rather than native objects. `mg_mpsgraph_desc_t` names
an MPSGraphExecutable package path, and ordered `mg_mpsgraph_tensor_desc_t` arrays describe feed and
target buffers. Phase 5 supports fixed-shape contiguous float32 tensors with zero byte offset. The
backend loads the package privately during instantiation and clones/retains tensor metadata and
buffers into GraphExec state.

MPSGraph nodes force direct encoding/ICB fallback. The initial backend may conservatively segment
command buffers around MPSGraph nodes and synchronize prior raw Metal work before encoding an
MPSGraph executable. This is a correctness choice for Phase 5, not a long-term performance claim.

Future Phase 5 design work includes defining the minimal C ABI boundary for importing or describing
MPSGraph executables, shape/dtype/layout compatibility rules, MPSGraph-to-`mg_error_t` error
mapping, and tests proving MPSGraph nodes force ICB fallback without disturbing direct raw Metal
execution.
