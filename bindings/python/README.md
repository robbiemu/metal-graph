# Python Adapter

The Python adapter is a thin `ctypes` layer over the public C ABI. Metal Graph remains the runtime;
Python is only a client layer.

The adapter uses a CMake-built shared library target named `metal_graph_shared`. It supports a
minimal library-owned shared-buffer workflow:

- create a device and stream;
- create shared buffers;
- build a dispatch graph from a metallib/kernel name;
- instantiate, launch, synchronize, and read shared-buffer results.

## Local Source Checkout

Build the shared library before running adapter workflows:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
uv run pytest tests/python
```

From a source checkout, the project `pyproject.toml` configures pytest to add `bindings/python` to
`PYTHONPATH`. For ad hoc scripts, either run one of the examples under `examples/python/`, or set:

```sh
PYTHONPATH="$PWD/bindings/python" python examples/python/mlx_unsupported_status.py
```

## Shared Library Discovery

The adapter searches for the shared library in this order:

1. `METAL_GRAPH_LIBRARY`, if set.
2. Source-checkout build outputs such as `build/libmetal_graph_shared.dylib`.
3. Package-adjacent library paths.
4. System dynamic-loader names as a final fallback.

The explicit override is:

```sh
METAL_GRAPH_LIBRARY="$PWD/build/libmetal_graph_shared.dylib" uv run pytest tests/python
```

If discovery fails, the exception lists searched paths and these remediation commands:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

You can inspect the current search order from Python:

```python
import metal_graph as mg

for path in mg.library_search_paths():
    print(path)
```

MLX array zero-copy import is still rejected unless the adapter can prove shared storage through a
stable public MLX API. Current MLX Python APIs expose metadata and buffer/DLPack conversion, but not
a public Metal storage handle, byte range, and device identity that Metal Graph can retain and
validate. Unsupported workflows raise clear Python exceptions rather than silently falling back.

Phase 7 adds the explicit interop checks:

```python
support = mg.can_import_mlx_array(array, mode="zero_copy")
assert not support

mg.import_mlx_array(array, mode="zero_copy")  # raises UnsupportedWorkflowError
```

An explicit copy fallback is available when the caller asks for it:

```python
device = mg.Device.system_default()
buffer = mg.import_mlx_array(array, mode="copy", device=device)
assert buffer.import_mode == "copy"
assert not buffer.is_zero_copy
```

`mode="copy"` creates an independent Metal Graph-owned shared buffer. It does not share storage with
MLX and must not be described as zero-copy.

Future real zero-copy support must retain the source MLX array for as long as the returned
`mg_buffer_t` wrapper is alive. Users must still synchronize explicitly; after Metal Graph writes to
an imported MLX buffer, read from MLX/Python only after `Launch.synchronize()` or the C
`mgLaunchSynchronize` equivalent has completed.

## Interop Diagnostics

Phase 9 adds small, stable Python diagnostics for optional interop paths. Diagnostics identify the
path (`copy`, `unsupported`, `reject`, `skipped`, `fallback`, `selected`, `disabled`,
`unavailable`, or `not_applicable`), source (`mlx`, `python`, `icb`, or `metal_graph`), reason,
zero-copy status, and synchronization guidance.

Current MLX status remains:

```python
status = mg.mlx_zero_copy_status()
assert status.status == "unsupported_public_api"
assert status.diagnostic.path == "unsupported"
assert not status.diagnostic.is_zero_copy
```

Explicit copy mode reports independent Metal Graph storage:

```python
support = mg.can_import_mlx_array(array, mode="copy")
assert support.status == "explicit_copy"
assert support.diagnostic.path == "copy"
assert not support.diagnostic.is_zero_copy
```

Existing graph-exec ICB diagnostics are exposed through `GraphExec.diagnostics()`. This wraps the
existing C ABI diagnostics only; Phase 9 does not add new backend instrumentation. MPSGraph fallback
details remain limited to existing structured errors and ICB fallback fields when an MPSGraph node
makes ICB ineligible.

Phase 11 adds narrow adapter diagnostics without changing MLX semantics:

```python
status = mg.mlx_zero_copy_status()
assert status.diagnostic.selected_mode == "reject"
assert not status.diagnostic.shared_storage_verified
assert status.diagnostic.copy_bytes == 0

support = mg.can_import_mlx_array(bytearray((1, 0, 0, 0)), mode="copy")
assert support.diagnostic.selected_mode == "copy"
assert support.diagnostic.copy_bytes == 4
assert not support.diagnostic.shared_storage_verified
```

## Examples

Source-checkout examples live under `examples/python/`:

```sh
python examples/python/basic_replay.py
python examples/python/explicit_copy_buffer.py
python examples/python/interop_diagnostics.py
python examples/python/mlx_unsupported_status.py
```

The examples are intentionally small. They do not add a Python graph-builder DSL, hide
synchronization, or change C runtime ownership rules.

## Out Of Scope

The adapter does not provide production wheel release automation, PyPI publishing, MLX graph
capture, a tensor compiler frontend, hidden synchronization, implicit large-buffer copies, or a
Python-first replacement for the C API.
