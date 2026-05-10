# Python Adapter

Phase 6 adds a thin Python adapter over the public C ABI. Metal Graph remains the runtime; Python is
only a client layer.

The adapter currently uses `ctypes` and a CMake-built shared library target named
`metal_graph_shared`. It supports a minimal library-owned shared-buffer workflow:

- create a device and stream;
- create shared buffers;
- build a dispatch graph from a metallib/kernel name;
- instantiate, launch, synchronize, and read shared-buffer results.

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

Build and test:

```sh
make configure
make build
uv run pytest
```

If the shared library is not in `build/`, set `METAL_GRAPH_LIBRARY` to the dynamic library path.
