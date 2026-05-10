# Phase 3: Patch And Update Semantics

Branch: `phase-3-patch-update-semantics`

Status: planned

## Scope

- Define patchable dispatch parameters.
- Add patch table construction during instantiation.
- Validate compatible and incompatible updates.
- Add tests for repeated launch after patching.

## Constraints

- Topology changes require reinstantiation.
- Patches must not silently change memory liveness.
- No ICB, MPSGraph, MLX, Python, or Rust work here.
