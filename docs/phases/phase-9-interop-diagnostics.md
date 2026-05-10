# Phase 9: Interop Synchronization And Diagnostics

Branch: `phase-9-interop-diagnostics`

Status: adapter-level diagnostics and existing backend diagnostic wrappers

## Scope

Phase 9 improves observability for Python, MLX, MPSGraph, ICB, and Metal Graph workflows without
changing execution semantics. It does not add hidden synchronization, true MLX zero-copy, new C ABI
features, multi-queue scheduling, or new backend instrumentation.

Implemented work:

- `InteropDiagnostic`, a small Python dataclass for optional interop paths;
- diagnostic fields on `MlxImportSupport`;
- diagnostic payloads on `UnsupportedWorkflowError` for rejected zero-copy/copy workflows;
- copy-path diagnostics on returned `Buffer` wrappers;
- `GraphExecDiagnostics`, a Python wrapper over existing `mgGraphExecGetDiagnostics`;
- `examples/python/interop_diagnostics.py`;
- tests covering MLX unsupported status, zero-copy rejection, explicit copy diagnostics, rejected
  copy inputs, and existing ICB diagnostics.

## Diagnostic Shape

Adapter diagnostics use these stable fields:

```text
path
source
reason
requires_synchronization
is_zero_copy
is_optional
message
copy_fallback_available
synchronization
resource_retention
```

The current paths are `copy`, `unsupported`, `reject`, `skipped`, `fallback`, `selected`,
`disabled`, `unavailable`, and `not_applicable`.

## MLX Status

Phase 9 preserves the Phase 7 result:

```text
status = unsupported_public_api
```

`mode="zero_copy"` still raises `UnsupportedWorkflowError`. The exception carries a diagnostic with:

```text
path = unsupported
source = mlx
reason = unsupported_public_api
is_zero_copy = false
```

`mode="copy"` remains explicit. It creates independent Metal Graph-owned storage, reports
`is_zero_copy == False`, and does not promise MLX-visible results.

## Synchronization Guidance

Phase 9 does not add hidden synchronization.

For current copy-only MLX adapter paths:

```text
mode="copy" produces independent Metal Graph storage.
No MLX-visible result is promised.
No zero-copy synchronization contract applies.
Metal Graph launches must still be synchronized before reading Metal Graph host-visible buffers.
```

For future true zero-copy support:

```text
MLX writes before Metal Graph reads require explicit synchronization.
Metal Graph writes before MLX reads require explicit launch synchronization.
Overlapping MLX and Metal Graph work must be ordered by documented stream/queue rules.
```

## ICB And MPSGraph

The C runtime already exposes ICB diagnostics through `mgGraphExecGetDiagnostics`. Phase 9 adds a
thin Python `GraphExec.diagnostics()` wrapper and `GraphExecDiagnostics.icb_diagnostic()` helper.
The helper reports selected, fallback, disabled, unavailable, and not-applicable states from the
existing C diagnostic fields.

MPSGraph fallback diagnostics remain limited to existing structured errors and ICB fallback fields.
Phase 9 does not add a new MPSGraph diagnostic ABI.

## Resource Retention

Diagnostics document the existing ownership contract:

```text
GraphExec and Launch retain bound mg_buffer_t resources according to the C runtime contract.
```

Phase 9 does not expose private retained Metal resource counts or launch internals.

## Out Of Scope

Phase 9 does not add:

- hidden synchronization;
- true MLX zero-copy;
- MLX graph capture;
- multi-queue scheduling;
- new C ABI features;
- broad backend instrumentation;
- performance claims.
