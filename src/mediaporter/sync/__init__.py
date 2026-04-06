"""Sync engine — transfers files to iOS device via ATC protocol.

Public API: sync_files() handles the complete flow:
  device discovery → ATC handshake → plist + CIG → AFC upload → register → SyncFinished
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from mediaporter.exceptions import SyncError
from mediaporter.sync.afc import NativeAFC
from mediaporter.sync.atc import ATCSession, SyncItem, _SyncFileInfo
from mediaporter.sync.device import DeviceInfo, discover_device


@dataclass
class SyncResult:
    """Result of syncing a single file."""
    path: Path
    success: bool
    error: str | None = None
    device_path: str | None = None


def sync_files(
    items: list[SyncItem],
    progress_cb: Callable[[str, int, int], None] | None = None,
    verbose: bool = False,
) -> list[SyncResult]:
    """Sync multiple files to a connected iOS device in a single ATC session.

    Args:
        items: Files to sync with metadata.
        progress_cb: Optional callback(filename, bytes_sent, total_bytes).
        verbose: Print protocol messages.

    Returns:
        List of SyncResult, one per input item.
    """
    if not items:
        return []

    # Discover device
    device = discover_device()

    # Prepare file info
    sync_files_info: list[_SyncFileInfo] = []
    for item in items:
        device_path, slot = ATCSession.generate_device_path()
        asset_id = ATCSession.generate_asset_id()
        sync_files_info.append(_SyncFileInfo(
            item=item,
            asset_id=asset_id,
            device_path=device_path,
            slot=slot,
        ))

    results: list[SyncResult] = []

    try:
        with ATCSession(device, verbose=verbose) as session:
            # Handshake
            device_grappa, anchor_str = session.handshake()
            new_anchor = str(int(anchor_str) + 1)

            # Build sync plist with ALL items
            plist_data = session.build_sync_plist(sync_files_info, int(new_anchor))
            cig_data = session.compute_cig(device_grappa, plist_data)

            # Open AFC and do the full transfer + registration
            with NativeAFC(device.handle) as afc:
                session.upload_and_register(
                    afc=afc,
                    files=sync_files_info,
                    plist_data=plist_data,
                    cig_data=cig_data,
                    anchor=new_anchor,
                    progress_cb=progress_cb,
                )

            # All succeeded if we got here
            for f in sync_files_info:
                results.append(SyncResult(
                    path=f.item.file_path,
                    success=True,
                    device_path=f.device_path,
                ))

    except SyncError as e:
        # Mark all remaining items as failed
        synced = {r.path for r in results}
        for f in sync_files_info:
            if f.item.file_path not in synced:
                results.append(SyncResult(
                    path=f.item.file_path,
                    success=False,
                    error=str(e),
                ))

    return results
