# Phase 7 MLX Interop Evidence

Status: `unsupported_public_api`

The Phase 7 implementation does not claim real MLX zero-copy. The public MLX Python API evaluated
for this phase exposes array metadata and conversion through the Python buffer protocol and DLPack,
but it does not expose a stable Metal storage handle, byte range, and device identity that Metal
Graph can safely retain and validate.

Implemented behavior:

- `mode="zero_copy"` returns a clear unsupported status or raises `UnsupportedWorkflowError`.
- `mode="copy"` is explicit and creates an independent Metal Graph-owned shared buffer.
- copied buffers report `is_zero_copy == False`.
- adapter tests are discoverable without MLX and optional MLX checks skip when MLX is absent.

No performance or positive zero-copy benchmark was run because shared storage cannot be proven
through the public API surface.
