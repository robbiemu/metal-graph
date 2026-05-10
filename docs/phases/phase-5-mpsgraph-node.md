# Phase 5: MPSGraph Node

Branch: `phase-5-mpsgraph-node`

Status: planned

## Scope

- Add optional MPSGraph tensor-subgraph node support.
- Define feature gates and validation failures for unsupported platforms.
- Add integration tests for event and command-buffer interaction.

## Constraints

- MPSGraph remains optional.
- The public graph model remains Metal Graph, not MPSGraph.
- No MLX, Python, or Rust work here.
