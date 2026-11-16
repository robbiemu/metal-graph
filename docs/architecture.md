# Architecture Notes

Metal Graph is a C-first graph execution library over Apple Metal. These notes explain its
structure; the [API spec](metal_graph_api_spec_v0.md) defines current behavior.

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
- Python uses a thin `ctypes` adapter over the C ABI.
- Future Rust bindings can use generated or handwritten FFI over the C ABI.

The Metal backend lives in Objective-C++ under `src/metal`. The core C header stays independent
of Metal types; native buffer and event interop use a separate Objective-C extension header.

## Backend

The backend centers on:

- single device;
- single queue per launch;
- explicit graph dependencies;
- external buffers plus planned transient arenas;
- structured validation errors before launch;
- asynchronous backend errors surfaced through launch completion;
- optional backend features with explicit availability checks and fallback diagnostics.

ICB optimization and MPSGraph nodes are implemented as optional paths. Broader ICB grouping,
residency sets, and workspace aliasing remain future work. Accepted jobs advance through completion
callbacks in whole-job FIFO order on each stream; separate streams may progress independently.
