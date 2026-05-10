from pathlib import Path

import metal_graph as mg
import pytest

ROOT = Path(__file__).resolve().parents[2]
METALLIB = ROOT / "build" / "phase0_test_kernels.metallib"


def test_mlx_zero_copy_status_has_stable_diagnostic_fields():
    status = mg.mlx_zero_copy_status()

    assert not status
    assert status.status == "unsupported_public_api"
    assert status.mode == "zero_copy"
    assert status.diagnostic.path == "unsupported"
    assert status.diagnostic.source == "mlx"
    assert status.diagnostic.reason == "unsupported_public_api"
    assert not status.diagnostic.is_zero_copy
    assert not status.diagnostic.shared_storage_verified
    assert status.diagnostic.requested_mode == "zero_copy"
    assert status.diagnostic.selected_mode == "reject"
    assert status.diagnostic.copy_bytes == 0
    assert status.diagnostic.fallback_reason == "unsupported_public_api"
    assert status.diagnostic.copy_fallback_available
    assert "no zero-copy synchronization contract" in status.diagnostic.synchronization


def test_zero_copy_rejection_carries_diagnostic():
    with pytest.raises(mg.UnsupportedWorkflowError) as error_info:
        mg.import_mlx_array(object(), mode="zero_copy")

    diagnostic = error_info.value.diagnostic
    assert diagnostic.path == "unsupported"
    assert diagnostic.source == "mlx"
    assert diagnostic.reason == "unsupported_public_api"
    assert not diagnostic.is_zero_copy
    assert diagnostic.selected_mode == "reject"


def test_explicit_copy_support_and_buffer_diagnostic():
    support = mg.can_import_mlx_array(bytearray((1, 0, 0, 0)), mode="copy")
    assert support
    assert support.status == "explicit_copy"
    assert support.diagnostic.path == "copy"
    assert support.diagnostic.reason == "explicit_copy_requested"
    assert not support.diagnostic.is_zero_copy
    assert not support.diagnostic.shared_storage_verified
    assert support.diagnostic.copy_bytes == 4
    assert support.diagnostic.fallback_reason == ""

    try:
        device = mg.Device.system_default()
    except mg.MetalGraphError as exc:
        if exc.status == mg.MG_STATUS_UNSUPPORTED:
            pytest.skip("no system default Metal device")
        raise

    with device:
        with mg.import_mlx_array(bytearray((1, 0, 0, 0)), mode="copy", device=device) as buffer:
            assert buffer.import_mode == "copy"
            assert not buffer.is_zero_copy
            assert buffer.diagnostic.path == "copy"
            assert buffer.diagnostic.reason == "explicit_copy_requested"
            assert "synchronize" in buffer.diagnostic.synchronization
            assert buffer.diagnostic.copy_bytes == 4
            assert not buffer.diagnostic.shared_storage_verified


def test_unsupported_copy_object_reports_reject_diagnostic():
    support = mg.can_import_mlx_array(object(), mode="copy")
    assert not support
    assert support.status == "reject"
    assert support.diagnostic.path == "reject"
    assert support.diagnostic.reason == "unsupported_object_type"
    assert support.diagnostic.requested_mode == "copy"
    assert support.diagnostic.selected_mode == "reject"
    assert support.diagnostic.fallback_reason == "unsupported_object_type"


def test_icb_diagnostic_reports_disabled_and_unavailable_paths():
    disabled = mg.GraphExecDiagnostics(
        icb_available=True,
        icb_enabled=False,
        icb_groups_planned=0,
        icb_groups_used=0,
        icb_groups_fallback=0,
        icb_last_fallback_reason="none",
    ).icb_diagnostic()
    assert disabled.path == "disabled"
    assert disabled.reason == "backend_feature_disabled"
    assert not disabled.requires_synchronization

    unavailable = mg.GraphExecDiagnostics(
        icb_available=False,
        icb_enabled=True,
        icb_groups_planned=0,
        icb_groups_used=0,
        icb_groups_fallback=0,
        icb_last_fallback_reason="unsupported",
    ).icb_diagnostic()
    assert unavailable.path == "unavailable"
    assert unavailable.reason == "backend_feature_unavailable"
    assert not unavailable.is_zero_copy


def test_graph_exec_icb_diagnostics_wrap_existing_c_api():
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
                graph.add_dispatch_node(
                    metallib_path=METALLIB,
                    kernel_name="mg_phase0_add_one",
                    buffer=buffer,
                    byte_count=16,
                    alignment=4,
                    grid_size=(4, 1, 1),
                )
                with graph.instantiate(device) as exec_plan:
                    diagnostics = exec_plan.diagnostics()

    assert isinstance(diagnostics.icb_available, bool)
    assert isinstance(diagnostics.icb_enabled, bool)
    assert diagnostics.icb_groups_planned >= 0
    assert diagnostics.icb_last_fallback_reason
    assert diagnostics.icb_diagnostic().source == "icb"
