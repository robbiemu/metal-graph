# Phase 8 Python Adapter Ergonomics Evidence

Status: `passed`

Phase 8 is a usability and packaging-locality phase. It does not claim runtime performance gains.

Implemented behavior:

- the adapter documents and exposes its shared-library search order;
- `METAL_GRAPH_LIBRARY` remains the sole explicit shared-library override;
- missing-library errors include searched paths and local build remediation commands;
- source-checkout examples run directly and skip cleanly when optional runtime prerequisites are
  absent;
- Phase 7 MLX behavior remains explicit: zero-copy is unsupported, copy mode is independent and
  non-zero-copy.

Validation should include:

```sh
uv run ruff check .
uv run pytest
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
cmake -S . -B build-no-mlx -DCMAKE_BUILD_TYPE=Debug -DMG_ENABLE_MLX_ADAPTER=OFF
cmake --build build-no-mlx
ctest --test-dir build-no-mlx --output-on-failure
```

No benchmark data is produced or implied by this artifact.
