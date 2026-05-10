# Phase 11: MLX Zero-Copy Unsupported Public API Result

Branch: `phase-11-mlx-zero-copy-completion`

Status: `unsupported_public_api`

## Outcome

Phase 11 evaluated whether Phase 10 external Metal storage wrapping can be connected to MLX arrays
through a supported public MLX export path or a deliberately maintained shim.

The current result is valid completion state B:

```text
MLX zero-copy remains unsupported.
```

The adapter continues to reject `mode="zero_copy"` with `UnsupportedWorkflowError` and
`unsupported_public_api`. Explicit `mode="copy"` remains supported when the source object exposes a
contiguous Python buffer, and it is reported as an adapter copy, not zero-copy.

## Storage Export Investigation

Phase 10 provides the Metal Graph runtime foundation:

```text
id<MTLBuffer> + byte range + owner retention -> mgMetalBufferWrap -> mg_buffer_t
```

Phase 11 requires MLX to provide all storage facts needed to call that API safely:

- underlying Metal buffer or equivalent stable handle;
- byte offset and byte length;
- device identity compatible with `mg_device_t`;
- dtype, shape, layout, and strides;
- mutability and write intent;
- owner/lifetime token that can be retained;
- explicit synchronization requirements.

The evaluated public MLX Python documentation exposes array metadata, lazy evaluation, device and
stream controls, unified memory behavior, and conversion interfaces. It does not document a stable
public `MTLBuffer` export, byte-range export, Metal device identity export, or owner token suitable
for `mgMetalBufferWrap`.

No maintained shim exists in this repository. Phase 11 therefore does not use private MLX internals
and does not claim a positive zero-copy workflow.

## Adapter Behavior

The Python adapter preserves explicit modes:

```python
mg.import_mlx_array(array, mode="zero_copy")  # raises UnsupportedWorkflowError
mg.import_mlx_array(array, mode="copy", device=device)  # explicit independent copy
```

`can_import_mlx_array(..., mode="zero_copy")` returns:

```text
supported = false
status = unsupported_public_api
shared_storage = false
diagnostic.path = unsupported
diagnostic.selected_mode = reject
diagnostic.shared_storage_verified = false
diagnostic.copy_bytes = 0
```

`mode="copy"` returns a `Buffer` with:

```text
import_mode = copy
is_zero_copy = false
diagnostic.selected_mode = copy
diagnostic.shared_storage_verified = false
diagnostic.copy_bytes > 0
```

The copy path uses independent Metal Graph-owned storage. It does not promise MLX-visible results.

## Synchronization

No hidden synchronization is added.

If future MLX zero-copy becomes supportable:

- MLX writes before Metal Graph reads must be completed and made visible before graph launch;
- Metal Graph writes before MLX reads require `Launch.synchronize()`, `mgLaunchSynchronize`, or a
  documented equivalent;
- overlapping MLX and Metal Graph access must be explicitly ordered by the caller.

For the current copy-only path, no shared-storage synchronization contract applies because MLX and
Metal Graph do not share storage.

## Diagnostics

Phase 11 extends Python diagnostics with adapter-level fields for:

- requested and selected mode;
- shared-storage verification;
- copy byte count;
- fallback reason for rejected paths;

These diagnostics are adapter-level. Core C runtime diagnostics remain framework-neutral, and the
core runtime remains independent of Python and MLX.

## Non-Goals Preserved

Phase 11 does not add:

- MLX private/internal storage extraction;
- MLX graph capture;
- automatic MLX-to-MetalGraph conversion;
- hidden copy fallback labeled zero-copy;
- hidden synchronization;
- Core ML or Metal ML inference nodes;
- ANE/Neural Accelerator optimization flags;
- a mandatory MLX dependency for the C runtime.

## Evidence

The Phase 11 evidence artifact under `artifacts/phase11_mlx_zero_copy/` records:

```text
mlx_zero_copy_supported = false
shared_storage_verified = false
positive_zero_copy_workflow_ran = false
zero_copy_reject_reason = unsupported_public_api
explicit_copy_supported = true
copy_path_is_zero_copy = false
phase10_external_metal_wrap_supported = true
```
