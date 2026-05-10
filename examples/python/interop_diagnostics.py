"""Print adapter-level interop diagnostics without requiring MLX."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bindings" / "python"))

import metal_graph as mg  # noqa: E402


def main() -> int:
    print("library search paths:")
    for path in mg.library_search_paths()[:3]:
        print(f"  {path}")

    zero_copy = mg.mlx_zero_copy_status()
    print("mlx zero-copy:")
    print(f"  status={zero_copy.status}")
    print(f"  path={zero_copy.diagnostic.path}")
    print(f"  reason={zero_copy.diagnostic.reason}")
    print(f"  is_zero_copy={zero_copy.diagnostic.is_zero_copy}")

    copy_support = mg.can_import_mlx_array(bytearray((1, 2, 3, 4)), mode="copy")
    print("explicit copy:")
    print(f"  status={copy_support.status}")
    print(f"  path={copy_support.diagnostic.path}")
    print(f"  is_zero_copy={copy_support.diagnostic.is_zero_copy}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
