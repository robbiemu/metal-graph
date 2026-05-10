"""Thin Python adapter over the Metal Graph C ABI.

The adapter keeps Metal Graph as the runtime. It does not compile MLX programs or
call Objective-C++ backend internals.
"""

from __future__ import annotations

import ctypes
import os
from collections.abc import Sequence
from pathlib import Path

MG_STATUS_OK = 0
MG_STATUS_INVALID_ARGUMENT = 1
MG_STATUS_INVALID_TOPOLOGY = 2
MG_STATUS_UNSUPPORTED = 3
MG_STATUS_OUT_OF_MEMORY = 4
MG_STATUS_BACKEND_ERROR = 5
MG_STATUS_INTERNAL_ERROR = 6

MG_ERROR_STAGE_INSTANTIATE = 3

MG_RESOURCE_ACCESS_UNKNOWN = 0
MG_RESOURCE_ACCESS_READ = 1
MG_RESOURCE_ACCESS_WRITE = 2
MG_RESOURCE_ACCESS_READ_WRITE = 3


class MetalGraphError(RuntimeError):
    """Exception raised for non-OK Metal Graph status codes."""

    def __init__(
        self,
        status: int,
        stage: int = 0,
        node_id: int = (2**64 - 1),
        message: str = "",
        backend_message: str = "",
    ) -> None:
        self.status = status
        self.stage = stage
        self.node_id = node_id
        self.backend_message = backend_message
        detail = message or status_string(status)
        if backend_message:
            detail = f"{detail}: {backend_message}"
        super().__init__(detail)


class UnsupportedWorkflowError(MetalGraphError):
    """Raised when a Python/MLX adapter workflow is outside Phase 6 scope."""


class _Version(ctypes.Structure):
    _fields_ = [("major", ctypes.c_uint32), ("minor", ctypes.c_uint32), ("patch", ctypes.c_uint32)]


class _BufferBinding(ctypes.Structure):
    _fields_ = [
        ("index", ctypes.c_uint32),
        ("buffer", ctypes.c_void_p),
        ("offset", ctypes.c_size_t),
    ]


class _DispatchResourceDesc(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_size_t),
        ("index", ctypes.c_uint32),
        ("access", ctypes.c_int),
        ("byte_offset", ctypes.c_size_t),
        ("byte_count", ctypes.c_size_t),
        ("alignment", ctypes.c_size_t),
    ]


class _DispatchDesc(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_size_t),
        ("metallib_path", ctypes.c_char_p),
        ("kernel_name", ctypes.c_char_p),
        ("grid_size", ctypes.c_uint32 * 3),
        ("threads_per_threadgroup", ctypes.c_uint32 * 3),
        ("buffers", ctypes.POINTER(_BufferBinding)),
        ("buffer_count", ctypes.c_uint32),
        ("scalars", ctypes.c_void_p),
        ("scalar_count", ctypes.c_uint32),
        ("max_grid_size", ctypes.c_uint32 * 3),
        ("resources", ctypes.POINTER(_DispatchResourceDesc)),
        ("resource_count", ctypes.c_uint32),
    ]


_LIB: ctypes.CDLL | None = None


def _candidate_libraries() -> list[Path]:
    env_path = os.environ.get("METAL_GRAPH_LIBRARY")
    if env_path:
        return [Path(env_path)]

    root = Path(__file__).resolve().parents[3]
    names = (
        "libmetal_graph_shared.dylib",
        "libmetal_graph_shared.so",
        "metal_graph_shared.dll",
        "libmetal_graph.dylib",
        "libmetal_graph.so",
    )
    dirs = (root / "build", root / "build" / "Debug", root / "build" / "Release")
    return [directory / name for directory in dirs for name in names]


def _load_library() -> ctypes.CDLL:
    global _LIB
    if _LIB is not None:
        return _LIB

    errors: list[str] = []
    for path in _candidate_libraries():
        if not path.exists():
            continue
        try:
            lib = ctypes.CDLL(str(path))
        except OSError as exc:
            errors.append(f"{path}: {exc}")
            continue
        _configure_library(lib)
        _LIB = lib
        return lib

    searched = ", ".join(str(path) for path in _candidate_libraries())
    extra = f" Load errors: {'; '.join(errors)}" if errors else ""
    raise MetalGraphError(
        MG_STATUS_UNSUPPORTED,
        message=f"Metal Graph shared library not found. Searched: {searched}.{extra}",
    )


def _configure_library(lib: ctypes.CDLL) -> None:
    lib.mgVersion.restype = _Version
    lib.mgVersionString.restype = ctypes.c_char_p
    lib.mgStatusString.argtypes = [ctypes.c_int]
    lib.mgStatusString.restype = ctypes.c_char_p

    lib.mgErrorDestroy.argtypes = [ctypes.c_void_p]
    lib.mgErrorStatus.argtypes = [ctypes.c_void_p]
    lib.mgErrorStatus.restype = ctypes.c_int
    lib.mgErrorStage.argtypes = [ctypes.c_void_p]
    lib.mgErrorStage.restype = ctypes.c_int
    lib.mgErrorNodeId.argtypes = [ctypes.c_void_p]
    lib.mgErrorNodeId.restype = ctypes.c_uint64
    lib.mgErrorMessage.argtypes = [ctypes.c_void_p]
    lib.mgErrorMessage.restype = ctypes.c_char_p
    lib.mgErrorBackendMessage.argtypes = [ctypes.c_void_p]
    lib.mgErrorBackendMessage.restype = ctypes.c_char_p

    lib.mgDeviceCreateSystemDefault.argtypes = [
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.mgDeviceCreateSystemDefault.restype = ctypes.c_int
    lib.mgDeviceDestroy.argtypes = [ctypes.c_void_p]

    lib.mgStreamCreate.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.mgStreamCreate.restype = ctypes.c_int
    lib.mgStreamDestroy.argtypes = [ctypes.c_void_p]

    lib.mgBufferCreateShared.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.mgBufferCreateShared.restype = ctypes.c_int
    lib.mgBufferDestroy.argtypes = [ctypes.c_void_p]
    lib.mgBufferLength.argtypes = [ctypes.c_void_p]
    lib.mgBufferLength.restype = ctypes.c_size_t
    lib.mgBufferContents.argtypes = [ctypes.c_void_p]
    lib.mgBufferContents.restype = ctypes.c_void_p

    lib.mgGraphCreate.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)]
    lib.mgGraphCreate.restype = ctypes.c_int
    lib.mgGraphDestroy.argtypes = [ctypes.c_void_p]
    lib.mgGraphAddDispatchNode.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(_DispatchDesc),
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.mgGraphAddDispatchNode.restype = ctypes.c_int
    lib.mgGraphInstantiate.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.mgGraphInstantiate.restype = ctypes.c_int
    lib.mgGraphExecDestroy.argtypes = [ctypes.c_void_p]

    lib.mgGraphLaunch.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.mgGraphLaunch.restype = ctypes.c_int
    lib.mgLaunchSynchronize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.mgLaunchSynchronize.restype = ctypes.c_int
    lib.mgLaunchDestroy.argtypes = [ctypes.c_void_p]


def _decode(value: bytes | None) -> str:
    return value.decode("utf-8") if value else ""


def _raise_from_error(status: int, error: ctypes.c_void_p) -> None:
    lib = _load_library()
    if error.value:
        try:
            raise MetalGraphError(
                status=lib.mgErrorStatus(error),
                stage=lib.mgErrorStage(error),
                node_id=lib.mgErrorNodeId(error),
                message=_decode(lib.mgErrorMessage(error)),
                backend_message=_decode(lib.mgErrorBackendMessage(error)),
            )
        finally:
            lib.mgErrorDestroy(error)
    raise MetalGraphError(status=status, message=status_string(status))


def _check(status: int, error: ctypes.c_void_p) -> None:
    if status != MG_STATUS_OK:
        _raise_from_error(status, error)
    if error.value:
        _load_library().mgErrorDestroy(error)


def status_string(status: int) -> str:
    return _decode(_load_library().mgStatusString(status))


def version() -> tuple[int, int, int]:
    raw = _load_library().mgVersion()
    return (raw.major, raw.minor, raw.patch)


def version_string() -> str:
    return _decode(_load_library().mgVersionString())


class _Handle:
    _destroy = ""

    def __init__(self, handle: int | ctypes.c_void_p) -> None:
        if isinstance(handle, ctypes.c_void_p):
            self._handle = ctypes.c_void_p(handle.value)
        else:
            self._handle = ctypes.c_void_p(handle)

    def close(self) -> None:
        if self._handle.value:
            getattr(_load_library(), self._destroy)(self._handle)
            self._handle = ctypes.c_void_p()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass


class Device(_Handle):
    _destroy = "mgDeviceDestroy"

    @classmethod
    def system_default(cls) -> Device:
        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgDeviceCreateSystemDefault(ctypes.byref(out), ctypes.byref(error))
        _check(status, error)
        return cls(out)


class Stream(_Handle):
    _destroy = "mgStreamDestroy"

    @classmethod
    def create(cls, device: Device) -> Stream:
        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgStreamCreate(
            device._handle, ctypes.byref(out), ctypes.byref(error)
        )
        _check(status, error)
        return cls(out)


class Buffer(_Handle):
    _destroy = "mgBufferDestroy"

    @classmethod
    def shared(cls, device: Device, length: int) -> Buffer:
        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgBufferCreateShared(
            device._handle, length, ctypes.byref(out), ctypes.byref(error)
        )
        _check(status, error)
        return cls(out)

    @property
    def length(self) -> int:
        return int(_load_library().mgBufferLength(self._handle))

    def _contents(self) -> int:
        address = _load_library().mgBufferContents(self._handle)
        if not address:
            raise MetalGraphError(
                MG_STATUS_UNSUPPORTED,
                message="buffer has no host-visible contents",
            )
        return int(address)

    def write_uint32s(self, values: Sequence[int]) -> None:
        array_type = ctypes.c_uint32 * len(values)
        array = array_type(*values)
        byte_count = ctypes.sizeof(array)
        if byte_count > self.length:
            raise ValueError("values do not fit in buffer")
        ctypes.memmove(self._contents(), ctypes.addressof(array), byte_count)

    def read_uint32s(self, count: int) -> list[int]:
        byte_count = ctypes.sizeof(ctypes.c_uint32) * count
        if byte_count > self.length:
            raise ValueError("read exceeds buffer length")
        array_type = ctypes.c_uint32 * count
        return list(array_type.from_address(self._contents()))


class Node:
    def __init__(self, handle: int | ctypes.c_void_p) -> None:
        if isinstance(handle, ctypes.c_void_p):
            self._handle = ctypes.c_void_p(handle.value)
        else:
            self._handle = ctypes.c_void_p(handle)


class Graph(_Handle):
    _destroy = "mgGraphDestroy"

    @classmethod
    def create(cls) -> Graph:
        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgGraphCreate(ctypes.byref(out), ctypes.byref(error))
        _check(status, error)
        return cls(out)

    def add_dispatch_node(
        self,
        *,
        metallib_path: str | os.PathLike[str],
        kernel_name: str,
        buffer: Buffer,
        index: int = 0,
        byte_count: int,
        grid_size: tuple[int, int, int],
        threads_per_threadgroup: tuple[int, int, int] = (1, 1, 1),
        access: int = MG_RESOURCE_ACCESS_READ_WRITE,
        alignment: int = 1,
        offset: int = 0,
    ) -> Node:
        binding = _BufferBinding(index, buffer._handle, offset)
        resource = _DispatchResourceDesc(
            ctypes.sizeof(_DispatchResourceDesc),
            index,
            access,
            0,
            byte_count,
            alignment,
        )
        metallib = os.fsencode(Path(metallib_path))
        kernel = kernel_name.encode("utf-8")
        desc = _DispatchDesc()
        desc.size = ctypes.sizeof(_DispatchDesc)
        desc.metallib_path = metallib
        desc.kernel_name = kernel
        desc.grid_size = (ctypes.c_uint32 * 3)(*grid_size)
        desc.threads_per_threadgroup = (ctypes.c_uint32 * 3)(*threads_per_threadgroup)
        desc.buffers = ctypes.pointer(binding)
        desc.buffer_count = 1
        desc.resources = ctypes.pointer(resource)
        desc.resource_count = 1

        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgGraphAddDispatchNode(
            self._handle, ctypes.byref(desc), ctypes.byref(out), ctypes.byref(error)
        )
        _check(status, error)
        return Node(out)

    def instantiate(self, device: Device) -> GraphExec:
        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgGraphInstantiate(
            self._handle, device._handle, ctypes.byref(out), ctypes.byref(error)
        )
        _check(status, error)
        return GraphExec(out)


class GraphExec(_Handle):
    _destroy = "mgGraphExecDestroy"

    def launch(self, stream: Stream) -> Launch:
        out = ctypes.c_void_p()
        error = ctypes.c_void_p()
        status = _load_library().mgGraphLaunch(
            self._handle, stream._handle, ctypes.byref(out), ctypes.byref(error)
        )
        _check(status, error)
        return Launch(out)


class Launch(_Handle):
    _destroy = "mgLaunchDestroy"

    def synchronize(self) -> None:
        error = ctypes.c_void_p()
        status = _load_library().mgLaunchSynchronize(self._handle, ctypes.byref(error))
        _check(status, error)


def mlx_available() -> bool:
    try:
        import mlx.core  # type: ignore  # noqa: F401
    except Exception:
        return False
    return True


def from_mlx_array(_array) -> Buffer:
    raise UnsupportedWorkflowError(
        MG_STATUS_UNSUPPORTED,
        message=(
            "MLX array zero-copy import is not supported in Phase 6. "
            "Use Metal Graph-owned shared buffers through the Python adapter."
        ),
    )


__all__ = [
    "Buffer",
    "Device",
    "Graph",
    "GraphExec",
    "Launch",
    "MetalGraphError",
    "Node",
    "Stream",
    "UnsupportedWorkflowError",
    "from_mlx_array",
    "mlx_available",
    "status_string",
    "version",
    "version_string",
    "MG_RESOURCE_ACCESS_READ",
    "MG_RESOURCE_ACCESS_READ_WRITE",
    "MG_RESOURCE_ACCESS_UNKNOWN",
    "MG_RESOURCE_ACCESS_WRITE",
    "MG_STATUS_UNSUPPORTED",
]
