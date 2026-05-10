# Phase 10: External Metal Storage Import/Wrap Foundation

Branch: `phase-10-external-metal-storage-wrap`

Status: external Metal buffer wrapping foundation

## Scope

Phase 10 adds the Metal Graph runtime capability required before true MLX zero-copy can be
implemented: wrapping externally owned Metal-backed storage as `mg_buffer_t` without copying.

This phase adds:

- `include/metal_graph/metal_graph_metal.h`, a Metal-specific extension header;
- `mgMetalBufferWrap`, which wraps a caller-provided `id<MTLBuffer>`;
- framework-neutral `mgBufferGetOriginInfo` diagnostics in the core C API;
- backend range handling for wrapped buffers with nonzero base offsets;
- tests for dispatch, copy, fill, diagnostics, range rejection, and exec/launch retention.

Phase 10 does not implement MLX zero-copy success. The Python MLX adapter may still report
`unsupported_public_api` for `mode="zero_copy"` until Phase 11 can prove a supported public MLX
storage export path or supported shim.

## API Boundary

The core public C header remains free of Objective-C and Metal types. Metal-specific wrapping lives
in:

```text
include/metal_graph/metal_graph_metal.h
```

That header is for Apple/Metal callers and may expose `id<MTLBuffer>`. Plain C users that include
only `metal_graph.h` do not need Objective-C, Metal, Python, MLX, MPSGraph, Core ML, or evidence
tooling.

## External Wrap Semantics

`mgMetalBufferWrap` accepts a trusted caller-provided Metal buffer, byte range, access intent,
lifetime flags, optional owner retain/release callbacks, and an optional label.

For a successful external wrap:

```text
origin_kind = MG_BUFFER_ORIGIN_EXTERNAL_METAL
is_zero_copy = true
is_external = true
source_framework = Metal
copy bytes = 0
```

Metal Graph exposes the descriptor byte range as the logical `mg_buffer_t` length. Dispatch, copy,
fill, and launch encoding add the wrapper's base byte offset when binding the underlying
`MTLBuffer`.

## Validation

The wrapper rejects invalid or unsafe descriptors, including:

- missing device, descriptor, Metal buffer, or output pointer;
- descriptor size mismatch;
- zero-length ranges;
- offset/length overflow;
- ranges outside the backing `MTLBuffer`;
- device mismatch between `mg_device_t` and `MTLBuffer.device`;
- invalid access enum or flags;
- write access without `MG_METAL_BUFFER_WRAP_MUTABLE`;
- requested host visibility for non-host-visible storage;
- owner callback mismatch;
- descriptors that retain neither the buffer nor an owner token.

## Lifetime

The wrapper must retain either the `id<MTLBuffer>` or a caller-provided owner token. The current
positive path uses `MG_METAL_BUFFER_WRAP_RETAIN_BUFFER`.

Existing Metal Graph ownership continues to apply:

```text
Graph construction retains buffers used by graph nodes.
GraphExec retains its frozen buffer snapshot for relaunch.
Launch retains buffers needed by committed command buffers until synchronization/destruction.
```

The Phase 10 GPU test releases the public `mg_buffer_t` wrapper and local Objective-C buffer
reference after instantiation, then launches and relaunches from the retained `GraphExec`.

## Synchronization

Phase 10 adds no hidden synchronization.

The contract is:

```text
External producer writes -> Metal Graph reads:
  the producer must complete and make writes visible before graph launch.

Metal Graph writes -> external consumer reads:
  the caller must wait for mgLaunchSynchronize, an event signal, or a documented equivalent.

Overlapping external access:
  callers must order access explicitly; Metal Graph does not make unsafe overlap safe.
```

## MLX Boundary

Phase 10 is necessary for MLX zero-copy, but not sufficient. MLX zero-copy remains unsupported
unless Phase 11 can obtain these facts through a supported public API or supported shim:

- Metal-backed storage identity;
- byte offset and byte length;
- device identity;
- layout and dtype compatibility;
- lifetime ownership;
- synchronization contract.

Until then, `mode="zero_copy"` rejection remains correct and explicit copy remains labeled copy.

## Phase 11 Follow-Up

Phase 11 confirms that the Phase 10 external Metal wrapper is still blocked from MLX zero-copy by
MLX storage visibility, not by Metal Graph runtime capability. The current public MLX Python surface
does not document a stable `MTLBuffer` plus byte-range/device/lifetime export, and this repository
does not include a maintained shim.

Therefore MLX `mode="zero_copy"` still rejects with `unsupported_public_api`. Phase 10 remains the
required runtime foundation for any future supported MLX zero-copy path.
