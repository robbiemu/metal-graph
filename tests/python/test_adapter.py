import gc
import weakref
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
    support = mg.can_import_mlx_array(object())
    assert not support
    assert support.mode == "zero_copy"
    assert not support.shared_storage
    assert "zero-copy" in support.reason

    with pytest.raises(mg.UnsupportedWorkflowError, match="zero-copy import is unsupported"):
        mg.import_mlx_array(object(), mode="zero_copy")

    with pytest.raises(mg.UnsupportedWorkflowError, match="zero-copy import is unsupported"):
        mg.from_mlx_array(object())


def test_optional_mlx_check_is_gated_when_mlx_is_absent_or_present():
    if not mg.mlx_available():
        support = mg.can_import_mlx_array(object())
        assert not support
        assert "MLX is not installed" in support.reason
        pytest.skip("MLX is not installed")

    import mlx.core as mx

    array = mx.zeros((4,), dtype=mx.uint32)
    support = mg.can_import_mlx_array(array)
    assert not support
    assert "public MLX Python API" in support.reason


def test_mlx_copy_mode_requires_contiguous_source():
    source = memoryview(bytearray(range(8)))[::2]
    support = mg.can_import_mlx_array(source, mode="copy")
    assert not support
    assert "contiguous" in support.reason


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


def test_explicit_mlx_copy_import_does_not_claim_zero_copy():
    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            pytest.skip("no system default Metal device")
        raise

    with device:
        source = bytearray((1, 0, 0, 0, 2, 0, 0, 0))
        with mg.import_mlx_array(source, mode="copy", device=device) as buffer:
            assert buffer.import_mode == "copy"
            assert not buffer.is_zero_copy
            assert buffer.read_uint32s(2) == [1, 2]

            source[:] = b"\x09\x00\x00\x00\x09\x00\x00\x00"
            assert buffer.read_uint32s(2) == [1, 2]


def test_explicit_mlx_copy_import_retains_source_owner_while_buffer_lives():
    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            pytest.skip("no system default Metal device")
        raise

    class Source(bytearray):
        pass

    with device:
        source = Source((1, 0, 0, 0))
        source_ref = weakref.ref(source)
        buffer = mg.import_mlx_array(source, mode="copy", device=device)
        del source
        gc.collect()

        try:
            assert source_ref() is not None
            assert buffer.read_uint32s(1) == [1]
        finally:
            buffer.close()


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
