"""Show the current Phase 7/8 MLX zero-copy status without requiring MLX."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bindings" / "python"))

import metal_graph as mg  # noqa: E402


def main() -> int:
    support = mg.can_import_mlx_array(object(), mode="zero_copy")
    print(f"supported={support.supported} mode={support.mode}")
    print(support.reason)

    try:
        mg.import_mlx_array(object(), mode="zero_copy")
    except mg.UnsupportedWorkflowError as exc:
        print(type(exc).__name__)
        return 0

    raise RuntimeError("zero-copy import unexpectedly succeeded")


if __name__ == "__main__":
    raise SystemExit(main())
