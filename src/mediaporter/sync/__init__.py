"""Sync engine — transfers files to iOS device via ATC protocol.

Public API:
  sync_files()              — one-shot: upload + register, sequential.
  make_sync_file_info()     — reserve an asset_id / device_path for an item.
  afc_upload_one()          — upload a single prepared file over AFC.
  register_uploaded_files() — short ATC session to register pre-uploaded files.

The split lets the pipeline overlap transcoding and uploading: as each transcode
completes, its file is uploaded immediately (via afc_upload_one) while other
files are still transcoding. register_uploaded_files() then runs the short ATC
metadata session after everything is on the device.

Files are always uploaded via AFC BEFORE the ATC session starts. This keeps the
ATC session short, avoids timeouts during multi-GB transfers, and prevents ghost
entries (metadata without file) on interruption.
"""

from __future__ import annotations

import sys
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


def make_sync_file_info(item: SyncItem) -> _SyncFileInfo:
    """Reserve an asset_id + device_path for a SyncItem.

    Does not touch the device — this is pure ID generation so the upload phase
    can start before the ATC session opens.
    """
    device_path, slot = ATCSession.generate_device_path()
    asset_id = ATCSession.generate_asset_id()
    return _SyncFileInfo(
        item=item,
        asset_id=asset_id,
        device_path=device_path,
        slot=slot,
    )


def afc_upload_one(
    afc: NativeAFC,
    info: _SyncFileInfo,
    progress_cb: Callable[[str, int, int], None] | None = None,
) -> None:
    """Upload a single prepared file to its final device path via AFC."""
    afc.makedirs(f"/iTunes_Control/Music/{info.slot}")

    total = info.item.file_size
    title = info.item.title

    def _cb(sent: int, _total: int) -> None:
        if progress_cb:
            progress_cb(title, sent, total)

    afc.write_file_streaming(info.device_path, info.item.file_path, _cb)


def register_uploaded_files(
    device: DeviceInfo,
    files: list[_SyncFileInfo],
    verbose: bool = False,
) -> list[SyncResult]:
    """Run the short ATC metadata session over files already uploaded via AFC.

    Assumes `files` have been written to their device_path already (e.g. via
    afc_upload_one). Opens a fresh ATC session, sends the sync plist + CIG,
    waits for AssetManifest, sends FileBegin/FileComplete for each asset,
    clears any stale pending assets, then waits for SyncFinished.
    """
    if not files:
        return []

    results: list[SyncResult] = []
    try:
        with ATCSession(device, verbose=verbose) as session:
            device_grappa, anchor_str = session.handshake()
            new_anchor = str(int(anchor_str) + 1)

            plist_data = session.build_sync_plist(files, int(new_anchor))
            cig_data = session.compute_cig(device_grappa, plist_data)

            with NativeAFC(device.handle) as afc:
                session.upload_and_register(
                    afc=afc,
                    files=files,
                    plist_data=plist_data,
                    cig_data=cig_data,
                    anchor=new_anchor,
                    progress_cb=None,
                    files_already_uploaded=True,
                )

            for f in files:
                results.append(SyncResult(
                    path=f.item.file_path,
                    success=True,
                    device_path=f.device_path,
                ))
    except SyncError as e:
        synced = {r.path for r in results}
        for f in files:
            if f.item.file_path not in synced:
                results.append(SyncResult(
                    path=f.item.file_path,
                    success=False,
                    error=str(e),
                ))

    return results


def sync_files(
    items: list[SyncItem],
    progress_cb: Callable[[str, int, int], None] | None = None,
    verbose: bool = False,
) -> list[SyncResult]:
    """Sync multiple files to a connected iOS device.

    Flow: upload all files via AFC first, then short ATC session for metadata
    + registration. This avoids ATC session timeouts during large file
    transfers and prevents ghost entries if the transfer is interrupted.
    """
    if not items:
        return []

    device = discover_device()
    sync_files_info = [make_sync_file_info(item) for item in items]

    # Step 1: Upload all files via AFC BEFORE opening the ATC session.
    if verbose:
        print("  Pre-uploading files via AFC...", file=sys.stderr)

    try:
        with NativeAFC(device.handle) as afc:
            for f in sync_files_info:
                if verbose:
                    print(
                        f"  AFC: uploading {f.item.file_path.name} -> {f.device_path}"
                        f" ({f.item.file_size // 1048576} MB)",
                        file=sys.stderr,
                    )
                afc_upload_one(afc, f, progress_cb=progress_cb)
    except SyncError as e:
        return [
            SyncResult(path=f.item.file_path, success=False, error=str(e))
            for f in sync_files_info
        ]

    # Step 2: Short ATC session — metadata + registration only.
    return register_uploaded_files(device, sync_files_info, verbose=verbose)
