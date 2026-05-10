# Architecture Notes

Metal Graph is planned as a C-first graph execution library over Apple Metal.

## Public Shape

The stable user-facing model is:

```text
mg_graph_t -> mg_graph_exec_t -> mg_launch_t
```

- `mg_graph_t` is a mutable logical DAG.
- `mg_graph_exec_t` is a frozen execution plan produced from a graph snapshot.
- `mg_launch_t` represents one concrete in-flight or completed execution.

The executable plan must not be treated as a reusable `MTLCommandBuffer`. Metal command buffers are per-launch objects; `mg_graph_exec_t` should own reusable planning artifacts such as pipeline state, binding layouts, patch tables, memory plans, and optional indirect command data.

## Language Boundary

The core ABI should remain C-compatible. This keeps integration paths simple:

- Objective-C uses the C headers directly and can own Metal objects behind opaque handles.
- Swift imports the Clang module and can layer ergonomic wrappers on top.
- Python binds to the C ABI through an extension or FFI layer.
- Rust binds to the C ABI through generated or handwritten FFI.

Objective-C or Objective-C++ implementation files can be introduced for the Metal backend without changing the public C headers.

## Initial Backend Direction

The v0 backend should prioritize correctness and observability:

- single device;
- single queue per launch;
- explicit graph dependencies;
- external buffers plus planned transient arenas;
- structured validation errors before launch;
- asynchronous backend errors surfaced through launch completion;
- optional backend features hidden behind capability queries.

Optimizations such as indirect command buffers, argument buffers, residency sets, heap aliasing, and MPSGraph subgraphs should remain internal or optional until the core semantics are stable.
