# Phase 5: MPSGraph Node

Branch: `phase-5-mpsgraph-node`

Status: planned

## Scope

- Add optional MPSGraph tensor-subgraph island support.
- Define feature gates and validation failures for unsupported platforms.
- Add integration tests for dependency, event, command-buffer, and fallback interaction.

Phase 5 is interoperability between MPSGraph and the Metal Graph runtime. Metal Graph remains the
outer execution-orchestration layer:

```text
Graph -> GraphExec -> Launch
```

An MPSGraph node is one kind of node inside that execution plan. It is not the public graph object,
and MPSGraph is not the runtime substrate.

Metal Graph owns:

- graph topology;
- dependencies;
- launch lifecycle;
- resource retention;
- errors;
- fallback behavior.

MPSGraph owns:

- tensor subgraph internals;
- tensor execution details;
- shape, dtype, and layout requirements.

## Constraints

- MPSGraph remains optional.
- The public graph model remains Metal Graph, not MPSGraph.
- MPSGraph nodes represent tensor-subgraph islands inside a Metal Graph execution plan.
- Pure tensor workloads may use MPSGraph directly.
- Mixed workloads may use Metal Graph to orchestrate raw Metal nodes and MPSGraph nodes together.
- Do not reimplement MPSGraph tensor compilation.
- Do not expose MPSGraph as the required public runtime.
- Do not expose native MPSGraph objects from the core public C header.
- No MLX, Python, or Rust work here.

## Done When

- A graph can schedule raw Metal dispatch/copy/fill/event/barrier work and an MPSGraph node through
  one Metal Graph execution plan.
- MPSGraph availability is feature-gated and reports `MG_STATUS_UNSUPPORTED` when unavailable and
  no safe fallback exists.
- Shape, dtype, layout, and buffer compatibility failures are reported through structured
  `mg_error_t` diagnostics.
- MPSGraph node execution respects Metal Graph dependency ordering and launch/synchronize
  lifecycle.
- MPSGraph nodes force direct encoding/ICB fallback where required and do not disturb raw Metal
  direct execution.

## Implemented Interface

Phase 5 uses a package-path based C descriptor:

- `mg_mpsgraph_desc_t` names an MPSGraphExecutable package path.
- `mg_mpsgraph_tensor_desc_t` describes ordered feed and target buffers.
- Phase 5 supports fixed-shape contiguous `MG_TENSOR_DATA_TYPE_FLOAT32` tensors.
- `byte_offset` must be zero in Phase 5 because the private MPSGraph bridge binds whole
  `MTLBuffer` objects.
- Feed and target descriptor arrays are ordered to match the executable's feed and target tensor
  order.

The Metal backend loads the executable package privately during instantiation. The resulting
GraphExec owns the copied package path, tensor metadata, retained buffers, and backend executable
object.

## Backend Boundary

MPSGraph support is controlled by the `MG_ENABLE_MPSGRAPH` CMake option and by framework
availability. When MPSGraph is unavailable, MPSGraph-node instantiation returns structured
`MG_STATUS_UNSUPPORTED`.

The Phase 5 backend uses conservative command-buffer segmentation around MPSGraph nodes. If raw
Metal work has already been encoded before an MPSGraph node, that segment is committed and
synchronized before encoding the MPSGraph executable. This is intentionally conservative until
deeper MPSGraph hazard and command-buffer integration is specified.

## Future Work

- Define the minimal C ABI boundary for importing or describing MPSGraph executables.
- Decide whether native MPSGraph objects live behind an Objective-C extension header rather than
  the core public C header.
- Clarify supported shape/dtype/layout compatibility rules.
- Document how MPSGraph node errors map into Metal Graph error reporting.
