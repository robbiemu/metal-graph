from pathlib import Path

import metal_graph as mg
import pytest

ROOT = Path(__file__).resolve().parents[2]
METALLIB = ROOT / "build" / "phase0_test_kernels.metallib"


def test_version_and_status():
    assert mg.version() == (0, 1, 0)
    assert mg.version_string() == "0.1.0"
    assert mg.status_string(0) == "ok"


def test_mlx_zero_copy_import_is_explicitly_unsupported():
    with pytest.raises(mg.UnsupportedWorkflowError, match="MLX array zero-copy import"):
        mg.from_mlx_array(object())


def test_failed_c_api_call_raises_metal_graph_error():
    if not METALLIB.exists():
        pytest.skip("Metal test metallib has not been built")

    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            pytest.skip("no system default Metal device")
        raise

    with device:
        with mg.Buffer.shared(device, 16) as buffer:
            with mg.Graph.create() as graph:
                with pytest.raises(mg.MetalGraphError, match="resource range") as error_info:
                    graph.add_dispatch_node(
                        metallib_path=METALLIB,
                        kernel_name="mg_phase0_add_one",
                        buffer=buffer,
                        byte_count=32,
                        alignment=4,
                        grid_size=(4, 1, 1),
                    )

                assert error_info.value.status == mg.MG_STATUS_INVALID_ARGUMENT


def test_python_adapter_dispatch_workflow():
    if not METALLIB.exists():
        pytest.skip("Metal test metallib has not been built")

    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            pytest.skip("no system default Metal device")
        raise

    with device:
        with mg.Stream.create(device) as stream:
            with mg.Buffer.shared(device, 16) as buffer:
                buffer.write_uint32s([1, 2, 3, 4])

                with mg.Graph.create() as graph:
                    graph.add_dispatch_node(
                        metallib_path=METALLIB,
                        kernel_name="mg_phase0_add_one",
                        buffer=buffer,
                        byte_count=16,
                        alignment=4,
                        grid_size=(4, 1, 1),
                    )
                    with graph.instantiate(device) as exec_plan:
                        with exec_plan.launch(stream) as launch:
                            launch.synchronize()

                assert buffer.read_uint32s(4) == [2, 3, 4, 5]
