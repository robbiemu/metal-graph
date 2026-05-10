# Phase 8: Python Adapter Ergonomics And Packaging

Branch: `phase-8-python-adapter-ergonomics`

Status: local usability improvements only

## Scope

Phase 8 improves Python adapter usability from a source checkout. It does not change the public C
ABI, core runtime semantics, Metal backend behavior, Phase 7 MLX status, or release packaging
policy.

Implemented work:

- clearer shared-library discovery;
- retained `METAL_GRAPH_LIBRARY` as the sole explicit shared-library override;
- actionable missing-library exceptions with searched paths and build commands;
- `library_search_paths()` for debugging source-checkout setup;
- source-checkout examples under `examples/python/`;
- tests for import, discovery failures, explicit override, examples, and Phase 7 MLX behavior;
- usability evidence artifact under `artifacts/phase8_python_adapter_ergonomics/`.

## Shared Library Discovery

The adapter searches in this order:

1. `METAL_GRAPH_LIBRARY`, if set.
2. repository build outputs such as `build/libmetal_graph_shared.dylib`;
3. package-adjacent directories;
4. system dynamic-loader library names.

Failure messages include searched paths and the source-checkout remediation:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

The adapter remains a thin `ctypes` wrapper over the public C ABI. It does not call backend-private
Objective-C++ or Metal internals.

## Examples

The examples are:

- `examples/python/basic_replay.py`;
- `examples/python/explicit_copy_buffer.py`;
- `examples/python/mlx_unsupported_status.py`.

They are intentionally source-checkout friendly and small. They may skip cleanly when the metallib or
a Metal device is unavailable. They do not add a graph-builder DSL, hide synchronization, or imply
that MLX zero-copy works.

## Phase 7 Compatibility

Phase 8 preserves the Phase 7 result:

```text
status = unsupported_public_api
```

`mode="zero_copy"` still rejects clearly. `mode="copy"` remains explicit and reports
`is_zero_copy == False`.

## Out Of Scope

Phase 8 does not add:

- production wheel matrices;
- PyPI release automation;
- broad packaging overhaul;
- Python-first runtime semantics;
- MLX graph capture;
- hidden synchronization;
- new C ABI features;
- Phase 9 diagnostics beyond small adapter error-message improvements.
