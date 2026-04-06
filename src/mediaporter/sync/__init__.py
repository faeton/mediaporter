"""Sync engine — transfers files to iOS device via ATC protocol.

Public API: sync_files() handles the complete flow:
  AFC upload (pre-upload) → ATC handshake → plist + CIG → register → SyncFinished

Files are uploaded via AFC BEFORE the ATC session starts. This keeps the ATC
session short, avoiding timeouts during multi-GB transfers and preventing ghost
entries (metadata without file) on interruption.
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
    """Sync multiple files to a connected iOS device.

    Flow: upload files via AFC first, then short ATC session for metadata + registration.
    This avoids ATC session timeouts during large file transfers and prevents ghost
    entries if the transfer is interrupted.

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
        # Step 1: Upload all files via AFC BEFORE ATC session
        # No metadata is registered yet, so interruption here is safe
        # (just orphan files on device, no ghost entries in TV app)
        if verbose:
            import sys
            print("  Pre-uploading files via AFC...", file=sys.stderr)

        with NativeAFC(device.handle) as afc:
            for f in sync_files_info:
                afc.makedirs(f"/iTunes_Control/Music/{f.slot}")
                if verbose:
                    print(f"  AFC: uploading {f.item.file_path.name} -> {f.device_path}"
                          f" ({f.item.file_size // 1048576} MB)", file=sys.stderr)

                def _progress_cb(sent, total, _title=f.item.title, _total=f.item.file_size):
                    if progress_cb:
                        progress_cb(_title, sent, _total)

                afc.write_file_streaming(f.device_path, f.item.file_path, _progress_cb)

        # Step 2: Short ATC session — metadata + registration only
        # Files are already on device, so this is fast (seconds, not minutes)
        with ATCSession(device, verbose=verbose) as session:
            device_grappa, anchor_str = session.handshake()
            new_anchor = str(int(anchor_str) + 1)

            plist_data = session.build_sync_plist(sync_files_info, int(new_anchor))
            cig_data = session.compute_cig(device_grappa, plist_data)

            # Open fresh AFC for plist write + artwork upload
            with NativeAFC(device.handle) as afc:
                session.upload_and_register(
                    afc=afc,
                    files=sync_files_info,
                    plist_data=plist_data,
                    cig_data=cig_data,
                    anchor=new_anchor,
                    progress_cb=None,  # upload already done
                    files_already_uploaded=True,
                )

            for f in sync_files_info:
                results.append(SyncResult(
                    path=f.item.file_path,
                    success=True,
                    device_path=f.device_path,
                ))

    except SyncError as e:
        synced = {r.path for r in results}
        for f in sync_files_info:
            if f.item.file_path not in synced:
                results.append(SyncResult(
                    path=f.item.file_path,
                    success=False,
                    error=str(e),
                ))

    return results
