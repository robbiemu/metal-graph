# Open Questions

This file tracks unresolved design questions first, then records resolved decisions and lessons learned so future phases do not reopen settled choices by accident.

## Current Open Questions

There are no currently tracked open questions for Phase 0 through Phase 4.

When new questions arise, add them here with:

- the phase or API area affected;
- the decision needed;
- options under consideration;
- the owner or next action, if known.

## Resolved Decisions And Lessons Learned

These notes resolve the initial project open questions for v1 intent. They are direction-setting rather than permanent constraints; future phases may revise them deliberately, but should not drift accidentally.

### Platform Floor

v1 targets macOS 15.0+ on Apple Silicon with real Apple Silicon GPU execution as the conformance target.

Intel macOS, iOS, and iPadOS are not v1 targets. The public C ABI should still avoid macOS-only public types so an iOS backend remains possible later.

The required v1 backend path is raw Metal compute/blit execution using command queues, freshly encoded command buffers, buffers, compute encoders, blit encoders, runtime pipeline creation, command-buffer completion/error reporting, and `MTLSharedEvent` for `mg_event_t`.

Optional backend capabilities include `MTLResidencySet`, `MTLIndirectCommandBuffer`, indirect compute commands, MPSGraph / `MPSGraphExecutable`, Metal 4 APIs, and future iOS/iPadOS support. Correctness must not depend on optional capabilities unless the public API explicitly says so. If an optional capability is unavailable, the backend must either fall back to the required raw Metal path or return `MG_STATUS_UNSUPPORTED`.

`MTLResidencySet` is an optimization for large stable resource sets, not a correctness mechanism. `MTLIndirectCommandBuffer` is an optimization for eligible static dispatch groups, not the public graph abstraction. MPSGraph is an optional tensor-subgraph backend, not part of the v1 core runtime.

### Thread Safety

v1 uses caller-side synchronization.

- `mg_graph_t` is mutable and not thread-safe.
- `mg_graph_exec_t` is immutable and reusable after instantiation, but v1 allows only one in-flight launch per exec.
- `mg_stream_t` is one-thread-at-a-time.
- `mg_buffer_t` is shareable, but callers synchronize host access.
- `mg_event_t` is shareable, but callers synchronize host-side event use unless an API says otherwise.
- Destruction is caller-synchronized.

A graph must not be mutated while `mgGraphInstantiate()` is running. Launching the same `mg_graph_exec_t` concurrently from multiple threads or streams is invalid in v1. Destroying a graph exec or stream while a launch using it is in flight is invalid in v1.

Future versions may allow concurrent launches of the same immutable exec using independent per-launch state.

### Ownership And Lifetime

v1 uses public create/destroy ownership. Public retain/release APIs are intentionally deferred.

`mg_graph_t` owns nodes and dependency records. `mg_node_t` is a non-owning graph-owned reference that remains valid until its parent graph is destroyed.

After successful instantiation, `mg_graph_exec_t` owns a frozen executable copy and must not depend on mutable graph storage, caller-owned descriptor memory, temporary arrays, or user-facing handle objects that may be destroyed after instantiation.

Graph execs must retain or copy resources needed for relaunch, including cloned node descriptors, backend pipelines/plans, buffers, events, arena descriptors, and workspace allocations. Destroying a graph after successful instantiation must not invalidate the exec. Destroying user-facing buffer, event, or arena handles after successful instantiation must not invalidate the exec.

Launches must retain backend resources required by submitted command buffers until completion, but this does not make destroying an in-flight exec or stream valid in v1. Callers must synchronize before destroying graph execs or streams involved in a launch.

Descriptors passed to graph construction functions are borrowed only for the duration of the call. Callers may stack-allocate descriptors and temporary arrays.

### Serialization

Serialization is optional for v1. If added before API stabilization, it should serialize portable graph descriptions only.

Serialized data may include schema/library/API versions, graph metadata, node IDs and kinds, dependency edges, symbolic kernel names, dispatch dimensions, buffer binding slots, copy/fill ranges, event wait/signal metadata, barrier nodes, declared resource requirements, and optional debug labels.

Serialized data must not include backend executable artifacts, live handles, raw pointers, Objective-C references, command queues/buffers, pipeline states, ICBs, heaps, residency sets, shared events, MPSGraph executables, or completion state.

Loading serialized data should produce a mutable graph or graph-builder representation. Backend executable plans must be rebuilt by instantiation. Serialization must not become a disguised binary cache.

### Future Bindings

The C ABI remains the source of truth.

Python is the first real high-level consumer because the motivating use case is a Python/MLX-facing graph runtime for CUDA Graph dependent TTS workloads in the MLX/mlx-audio ecosystem. Python bindings should live in this repository early, remain thin, wrap only the public C ABI, and avoid private Objective-C++, Metal, MPSGraph, and MLX internals.

MLX integration should be an adapter above the Python binding, not the runtime substrate. The first Python milestone should work with library-owned buffers before attempting MLX array interop.

Swift remains useful as an Apple-platform smoke test and ergonomic check, but it is not the primary v1 binding target. Rust is deferred until the C ABI and ownership model are more stable.

### Dispatch Buffer Patch Range Compatibility

Phase 3 introduced default exec patching for dispatch buffer bindings. During review, we confirmed
that the current patch validation could verify the binding index, replacement buffer, device
compatibility, and offset shape, but it could not fully prove the shader-visible byte range for a
patched dispatch buffer.

The important design lesson is that a dispatch buffer binding and a dispatch resource contract are
related but distinct concepts.

A binding answers:

```text
Which buffer is bound at this slot, and at what offset?
```

A resource contract answers:

```text
What range and access pattern is this node allowed to use through that binding?
```

Keeping those concepts separate is the cleaner long-term model. `mg_buffer_binding_t` remains a
lightweight concrete binding record. It does not grow into the full resource-usage declaration for
dispatch nodes.

Phase 4 adds separate dispatch resource requirement metadata keyed by binding index. That metadata
describes the declared shader-visible range, access mode, and compatibility constraints needed for
validation, hazard reasoning, memory planning, and future backend optimizations.

Dispatch buffer binding indices are unique within a dispatch node. Because dispatch resource
contracts are keyed by binding index, allowing duplicate bindings would make the resource contract
ambiguous and could cause patch validation and backend encoding to reason about different effective
bindings. `mgGraphAddDispatchNode` rejects duplicate binding indices.

A dispatch resource descriptor must refer to exactly one existing binding index. Duplicate dispatch
resource descriptors for the same binding index are invalid.

This decision keeps Phase 3 valid while acknowledging a deliberate limitation: Phase 3 dispatch
buffer patch compatibility was not range-complete. Phase 4 resolves that limitation for dispatch
nodes that declare resource requirements.

Decision:

- `mg_buffer_binding_t` remains the concrete buffer-plus-offset binding record.
- Dispatch resource requirements are modeled separately.
- Dispatch buffer patch validation uses those requirements to prove replacement-buffer range
  compatibility.
- If a dispatch buffer binding is patchable, it must have a declared nonzero resource range.

### Phase 4 ICB Scope

The first ICB implementation is intentionally narrower than general "dispatch-only graph"
eligibility. A dispatch-only graph can still contain dependencies and resource hazards between
dispatches. Without dependency-aware ICB grouping and explicit hazard handling, treating multiple
dispatches as one ICB-eligible group is too broad.

Phase 4 therefore supports only one static dispatch node in the ICB path. Multi-dispatch execs fall
back to direct encoding until the planner can prove that indirect command execution preserves
direct-encoding semantics.

Future work:

- dependency-aware ICB grouping;
- resource-hazard-aware multi-dispatch ICB eligibility;
- per-group diagnostics instead of last/global fallback reason;
- broader dispatch resource contracts for hazard analysis.

### MPSGraph Integration Direction

Phase 5 raises an apparent layering question: MPSGraph is a higher-level tensor graph API, while
Metal Graph is a lower-level explicit execution graph. At first glance, this suggests MPSGraph
should wrap Metal Graph rather than Metal Graph hosting an MPSGraph node.

The decision is that Metal Graph remains the outer orchestration layer, and MPSGraph is treated as
an optional tensor-subgraph island.

This is intentional. Metal Graph is not trying to replace MPSGraph as a tensor compiler. It owns a
different layer of the problem:

- explicit graph topology;
- raw Metal dispatch/copy/fill/event/barrier nodes;
- launch lifecycle;
- resource retention;
- patch/update policy;
- synchronization boundaries;
- backend diagnostics and fallback behavior.

MPSGraph owns a different set of concerns:

- tensor subgraph representation;
- tensor operation lowering;
- tensor shape, dtype, and layout constraints;
- execution details internal to the MPSGraph executable.

The important learning is that "higher level" does not automatically mean "outer layer." For pure
tensor workloads, MPSGraph should remain the natural top-level API. But Metal Graph targets
workloads that mix tensor execution with explicit raw Metal work, event ordering, patchable
resources, transient memory planning, and CUDA-Graph-like repeated launches. In that setting, Metal
Graph must remain the conductor.

Phase 5 therefore integrates MPSGraph as an optional node type rather than making MPSGraph the
runtime substrate.

This keeps the core model stable:

```text
Graph -> GraphExec -> Launch
```

and allows one graph execution plan to coordinate both raw Metal work and MPSGraph work without
exposing MPSGraph as the public graph object.

Decision:

- Metal Graph remains the outer execution-orchestration layer.
- MPSGraph support is optional and feature-gated.
- MPSGraph nodes represent tensor-subgraph islands inside a Metal Graph execution plan.
- Pure tensor workloads may use MPSGraph directly.
- Mixed workloads may use Metal Graph to orchestrate raw Metal nodes and MPSGraph nodes together.
- Metal Graph should not attempt to reimplement MPSGraph tensor compilation.
- MPSGraph should not become a required dependency of raw Metal Graph execution.
- Phase 5 uses MPSGraphExecutable package paths and fixed feed/target tensor metadata in the core C
  ABI, rather than native MPSGraph object handles.
- GraphExec owns an exec-private copy of the package after successful instantiation.
- The initial backend uses conservative command-buffer segmentation around MPSGraph nodes and may
  synchronize prior raw Metal work before MPSGraph encoding.

Future work:

- define the minimal C ABI boundary for importing or describing MPSGraph executables;
- decide whether native MPSGraph objects live behind an Objective-C extension header rather than
  the core public C header;
- clarify supported shape/dtype/layout compatibility rules;
- document how MPSGraph node errors map into Metal Graph error reporting;
- test that MPSGraph nodes force ICB fallback and do not disturb direct raw Metal execution.
