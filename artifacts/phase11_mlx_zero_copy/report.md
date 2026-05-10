# Phase 11 MLX Zero-Copy Evidence

Status: `unsupported_public_api`

Phase 11 did not produce a positive MLX zero-copy workflow. That is intentional: the adapter did
not find a supported public MLX Python export path or maintained in-repository shim that exposes the
required Metal storage identity, byte range, device identity, lifetime owner, layout, dtype, and
synchronization facts.

## Evidence Summary

- Phase 10 external Metal wrapping is available and remains the required runtime foundation.
- `mode="zero_copy"` rejects with `UnsupportedWorkflowError`.
- Rejection diagnostics report `selected_mode = reject`, `shared_storage_verified = false`,
  `copy_bytes = 0`, and `fallback_reason = unsupported_public_api`.
- `mode="copy"` remains explicit, creates independent Metal Graph-owned storage, and reports
  `selected_mode = copy`, `is_zero_copy = false`, and `shared_storage_verified = false`.
- No private MLX internals are used.
- No hidden synchronization is added.
- No performance or Neural Accelerator claims are made.

## Claim Boundary

This artifact may support:

- the claim that Phase 11 preserves honest MLX zero-copy rejection when storage facts are
  unavailable;
- the claim that explicit copy diagnostics do not report zero-copy;
- the claim that Phase 10 remains the runtime foundation for any future supported zero-copy path.

This artifact may not support:

- a positive MLX zero-copy workflow;
- shared-storage visibility between MLX and Metal Graph;
- faster individual kernels;
- MLX graph capture or model-execution behavior.
