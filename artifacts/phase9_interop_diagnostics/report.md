# Phase 9 Interop Diagnostics Evidence

Status: `passed`

Phase 9 is a diagnostics phase. It does not claim runtime performance gains and does not change
execution semantics.

Implemented behavior:

- adapter-level diagnostics distinguish unsupported, skipped, reject, copy, fallback, selected, and
  not-applicable paths;
- MLX zero-copy remains `unsupported_public_api`;
- zero-copy rejection carries a structured diagnostic;
- explicit copy mode reports independent non-zero-copy storage;
- synchronization guidance is surfaced in diagnostics and docs;
- existing ICB selected, fallback, disabled, unavailable, and not-applicable diagnostics are exposed
  through the Python adapter;
- MPSGraph fallback reporting limits are documented honestly.

Validation should include:

```sh
uv run ruff check .
uv run pytest
find examples/python -maxdepth 1 -name "*.py" -print -exec uv run python {} \;
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
cmake -S . -B build-no-mlx -DCMAKE_BUILD_TYPE=Debug -DMG_ENABLE_MLX_ADAPTER=OFF
cmake --build build-no-mlx
ctest --test-dir build-no-mlx --output-on-failure
```

No benchmark data is produced or implied by this artifact.
