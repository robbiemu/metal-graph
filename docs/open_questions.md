# Open Questions

This file tracks unresolved design questions first, then records resolved decisions and lessons learned so future phases do not reopen settled choices by accident.

## Current Open Questions

There are no currently tracked open questions for Phase 0, Phase 1, or Phase 2.

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
