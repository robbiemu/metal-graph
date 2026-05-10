# Python Adapter

Phase 6 adds a thin Python adapter over the public C ABI. Metal Graph remains the runtime; Python is
only a client layer.

The adapter currently uses `ctypes` and a CMake-built shared library target named
`metal_graph_shared`. It supports a minimal library-owned shared-buffer workflow:

- create a device and stream;
- create shared buffers;
- build a dispatch graph from a metallib/kernel name;
- instantiate, launch, synchronize, and read shared-buffer results.

MLX array zero-copy import and arbitrary MLX program capture are intentionally unsupported in this
phase. Unsupported workflows raise clear Python exceptions rather than silently falling back.

Build and test:

```sh
make configure
make build
uv run pytest
```

If the shared library is not in `build/`, set `METAL_GRAPH_LIBRARY` to the dynamic library path.
