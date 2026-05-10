"""Demonstrate the explicit non-zero-copy import path."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bindings" / "python"))

import metal_graph as mg  # noqa: E402


def main() -> int:
    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            print("skipped: no system default Metal device")
            return 0
        raise

    with device:
        source = bytearray((1, 0, 0, 0, 2, 0, 0, 0))
        with mg.import_mlx_array(source, mode="copy", device=device) as buffer:
            print(f"mode={buffer.import_mode} zero_copy={buffer.is_zero_copy}")
            print(buffer.read_uint32s(2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
