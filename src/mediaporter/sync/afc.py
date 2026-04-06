"""Native AFC (Apple File Conduit) client via MobileDevice.framework.

Zero external dependencies — uses ctypes directly.
Source: scripts/atc_nodeps_sync.py lines 159-206.
"""

from __future__ import annotations

from ctypes import byref, c_long, c_void_p
from pathlib import Path
from typing import Callable

from mediaporter.exceptions import SyncError
from mediaporter.sync.frameworks import cfstr, get_md

AFC_WRITE_MODE = 2
CHUNK_SIZE = 1048576  # 1MB


class NativeAFC:
    """AFC client using MobileDevice.framework — zero external dependencies."""

    def __init__(self, device_handle: c_void_p):
        self._md = get_md()
        self._device = device_handle
        self._afc_conn: c_void_p | None = None
        self._connect()

    def _connect(self):
        rc = self._md.AMDeviceConnect(self._device)
        if rc != 0:
            raise SyncError(f"AMDeviceConnect failed: {rc}")

        rc = self._md.AMDeviceStartSession(self._device)
        if rc != 0:
            raise SyncError(f"AMDeviceStartSession failed: {rc}")

        svc_handle = c_void_p()
        rc = self._md.AMDeviceStartService(
            self._device, cfstr("com.apple.afc"), byref(svc_handle), None
        )
        if rc != 0:
            raise SyncError(f"StartService(afc) failed: {rc}")

        self._afc_conn = c_void_p()
        rc = self._md.AFCConnectionOpen(svc_handle, 0, byref(self._afc_conn))
        if rc != 0:
            raise SyncError(f"AFCConnectionOpen failed: {rc}")

    def makedirs(self, path: str) -> None:
        """Create directory on device. Ignores errors if it already exists."""
        self._md.AFCDirectoryCreate(self._afc_conn, path.encode("utf-8"))

    def write_file(self, path: str, data: bytes) -> None:
        """Write bytes to a file on the device."""
        handle = c_long(0)
        rc = self._md.AFCFileRefOpen(
            self._afc_conn, path.encode("utf-8"), AFC_WRITE_MODE, byref(handle)
        )
        if rc != 0:
            raise SyncError(f"AFCFileRefOpen({path}) failed: {rc}")

        offset = 0
        while offset < len(data):
            chunk = data[offset:offset + CHUNK_SIZE]
            rc = self._md.AFCFileRefWrite(self._afc_conn, handle, chunk, len(chunk))
            if rc != 0:
                self._md.AFCFileRefClose(self._afc_conn, handle)
                raise SyncError(f"AFCFileRefWrite failed at offset {offset}: {rc}")
            offset += len(chunk)

        self._md.AFCFileRefClose(self._afc_conn, handle)

    def write_file_streaming(
        self,
        remote_path: str,
        local_path: Path,
        progress_cb: Callable[[int, int], None] | None = None,
    ) -> None:
        """Stream a local file to device in chunks. Avoids loading entire file into memory."""
        file_size = local_path.stat().st_size

        handle = c_long(0)
        rc = self._md.AFCFileRefOpen(
            self._afc_conn, remote_path.encode("utf-8"), AFC_WRITE_MODE, byref(handle)
        )
        if rc != 0:
            raise SyncError(f"AFCFileRefOpen({remote_path}) failed: {rc}")

        sent = 0
        try:
            with open(local_path, "rb") as f:
                while True:
                    chunk = f.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    rc = self._md.AFCFileRefWrite(self._afc_conn, handle, chunk, len(chunk))
                    if rc != 0:
                        raise SyncError(f"AFCFileRefWrite failed at offset {sent}: {rc}")
                    sent += len(chunk)
                    if progress_cb:
                        progress_cb(sent, file_size)
        finally:
            self._md.AFCFileRefClose(self._afc_conn, handle)

    def close(self) -> None:
        """Close the AFC connection."""
        if self._afc_conn:
            self._md.AFCConnectionClose(self._afc_conn)
            self._afc_conn = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
