# Phase 7: MLX Zero-Copy Buffer Interop

Branch: `phase-7-mlx-zero-copy`

Status: unsupported by current public MLX Python storage visibility

## Scope

Phase 7 evaluates MLX array interop as an optional Python adapter feature above the Metal Graph C
ABI. The core C runtime remains independent of Python and MLX, and the public C header does not
expose MLX, Python, Objective-C, Swift, C++, or private backend types.

The intended zero-copy path is:

```text
MLX array -> shared backing storage -> mg_buffer_t wrapper -> GraphExec launch -> explicit sync ->
MLX/Python observation
```

The repository does not currently claim this path is implemented.

## Storage Decision

The evaluated public MLX Python surface exposes array metadata such as `dtype`, `shape`, `itemsize`,
`nbytes`, and conversion through the Python buffer protocol and DLPack. That is enough to make an
explicit copy, but it is not enough to safely construct an `mg_buffer_t` that shares MLX storage.

The missing public information is:

- a stable underlying `MTLBuffer` or equivalent retained storage handle;
- byte offset and byte range into that storage;
- Metal device identity compatible with `mg_device_t`;
- storage mutability and lifetime ownership rules suitable for an in-flight Metal Graph launch.

Because those facts cannot be proven through public MLX Python APIs, `mode="zero_copy"` rejects with
`UnsupportedWorkflowError`. The adapter must not use private MLX internals to fake this path.

## Adapter API

The Python adapter exposes:

```python
mg.can_import_mlx_array(array, mode="zero_copy")
mg.import_mlx_array(array, mode="zero_copy")
mg.import_mlx_array(array, mode="copy", device=device)
mg.from_mlx_array(array, mode="zero_copy")
```

`can_import_mlx_array(..., mode="zero_copy")` returns a structured negative result with a reason.
`import_mlx_array(..., mode="zero_copy")` raises `UnsupportedWorkflowError`.

`mode="copy"` is an explicit fallback. It accepts a contiguous Python buffer-protocol source, creates
a Metal Graph-owned shared buffer, copies the source bytes into that buffer, and returns the existing
`Buffer` wrapper. The returned buffer reports:

```python
buffer.import_mode == "copy"
buffer.is_zero_copy is False
```

This path does not share storage with MLX and must not be described as zero-copy.

## Lifetime

For future zero-copy support, the adapter rule is:

```text
The Python adapter must retain the source MLX array for at least as long as the mg_buffer_t wrapper
exists.
```

The current explicit copy path also retains the source owner while the returned `Buffer` wrapper is
alive. That retention is conservative and does not change the storage semantics: copied buffers are
independent Metal Graph-owned buffers.

For launches, the existing C runtime retains `mg_buffer_t` resources needed by an in-flight launch.
Future zero-copy support must ensure the adapter-owned MLX source object remains alive for the same
period through the buffer wrapper.

## Synchronization

Zero-copy does not imply automatic synchronization.

The Phase 7 rule is conservative:

```text
After Metal Graph writes to an imported MLX buffer, the user must explicitly synchronize the Metal
Graph launch before reading the result from MLX/Python.
```

The adapter does not inject hidden synchronization between MLX streams and Metal Graph streams.
Future real zero-copy support must document:

- MLX writes before Metal Graph reads;
- Metal Graph writes before MLX reads;
- overlapping MLX and Metal Graph work;
- stream or queue assumptions;
- when `Launch.synchronize()` or `mgLaunchSynchronize` is required.

## Tests

The Phase 7 tests cover:

- Python adapter import when MLX is absent;
- clear zero-copy unsupported status and exception;
- optional MLX-present status checks, skipped when MLX is unavailable;
- contiguous-source validation for explicit copy mode;
- explicit copy mode never claiming zero-copy;
- source-owner retention while the returned buffer wrapper is alive;
- existing Python dispatch workflow remains unchanged.

Core C builds continue to work with:

```sh
cmake -S . -B /private/tmp/metal-graph-no-adapter-build -DCMAKE_BUILD_TYPE=Debug -DMG_ENABLE_MLX_ADAPTER=OFF
cmake --build /private/tmp/metal-graph-no-adapter-build
ctest --test-dir /private/tmp/metal-graph-no-adapter-build --output-on-failure
```

## Evidence Status

The Phase 7 evidence artifact under `artifacts/phase7_mlx_interop/` records:

```text
status = unsupported_public_api
```

This is an intentional result. The repository should add the positive zero-copy workflow only after
MLX exposes a stable public storage handle that can be retained, range-checked, device-checked, and
synchronized honestly.

## Phase 10 Relationship

Phase 10 adds the Metal Graph runtime foundation for external Metal storage wrapping through a
Metal-specific extension header. That proves Metal Graph can use externally owned `MTLBuffer`
storage as `mg_buffer_t` without copying.

Phase 10 does not, by itself, make MLX zero-copy supported. The MLX adapter must continue to reject
`mode="zero_copy"` unless Phase 11 obtains a supported public MLX export path or supported shim that
proves storage identity, byte range, device identity, lifetime ownership, layout, dtype, and
synchronization safety. Explicit `mode="copy"` remains a copy path and must report
`is_zero_copy == False`.
