"""Run a minimal dispatch graph from a source checkout.

Build first:
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
    cmake --build build
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bindings" / "python"))

import metal_graph as mg  # noqa: E402


def main() -> int:
    metallib = ROOT / "build" / "phase0_test_kernels.metallib"
    if not metallib.exists():
        print("skipped: build/phase0_test_kernels.metallib has not been built")
        return 0

    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            print("skipped: no system default Metal device")
            return 0
        raise

    with device:
        with mg.Stream.create(device) as stream:
            with mg.Buffer.shared(device, 16) as buffer:
                buffer.write_uint32s([1, 2, 3, 4])

                with mg.Graph.create() as graph:
                    graph.add_dispatch_node(
                        metallib_path=metallib,
                        kernel_name="mg_phase0_add_one",
                        buffer=buffer,
                        byte_count=16,
                        alignment=4,
                        grid_size=(4, 1, 1),
                    )
                    with graph.instantiate(device) as exec_plan:
                        with exec_plan.launch(stream) as launch:
                            launch.synchronize()

                print(buffer.read_uint32s(4))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
