"""ATC (AirTrafficHost) sync protocol implementation.

Handles the full 9-step sync protocol:
  handshake → plist + CIG → AFC upload → FileBegin/Complete → SyncFinished

Source: scripts/atc_nodeps_sync.py + scripts/atc_tv_series_test.py
Protocol spec: research/docs/IMPLEMENTATION_GUIDE.md
"""

from __future__ import annotations

import datetime
import plistlib
import random
import string
import threading
from ctypes import POINTER, byref, c_int, c_void_p
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from mediaporter.exceptions import SyncError
from mediaporter.sync.afc import NativeAFC
from mediaporter.sync.device import DeviceInfo
from mediaporter.sync.frameworks import (
    cfarray,
    cfdata,
    cfdict,
    cfdouble,
    cfnum32,
    cfnum64,
    cfstr,
    cfstr_to_str,
    get_ath,
    get_cf,
    get_cf_constants,
    get_cig,
    get_grappa_bytes,
)


@dataclass
class SyncItem:
    """A file to be synced to the device."""
    file_path: Path
    title: str
    sort_name: str
    duration_ms: int
    file_size: int
    # Movie fields
    is_movie: bool = True
    # TV fields
    is_tv_show: bool = False
    tv_show_name: str | None = None
    sort_tv_show_name: str | None = None
    season_number: int | None = None
    episode_number: int | None = None
    episode_sort_id: int | None = None
    artist: str | None = None
    sort_artist: str | None = None
    album: str | None = None
    sort_album: str | None = None
    album_artist: str | None = None
    sort_album_artist: str | None = None
    # Media info
    is_hd: bool = False
    bit_rate: int = 160
    audio_format: int = 502  # AAC
    channels: int = 2
    # Artwork
    poster_data: bytes | None = None


@dataclass
class _SyncFileInfo:
    """Internal per-file state during a sync session."""
    item: SyncItem
    asset_id: int
    device_path: str
    slot: str


class ATCSession:
    """Manages a single ATC sync session with a device."""

    LIBRARY_ID = "MEDIAPORTER00001"
    HOST_NAME = "mediaporter"
    VERSION = "12.8"

    def __init__(self, device: DeviceInfo, verbose: bool = False):
        self._device = device
        self._ath = get_ath()
        self._cf = get_cf()
        self._conn: c_void_p | None = None
        self._device_grappa: bytes | None = None
        self._anchor: str = "0"
        self._verbose = verbose

    def _log(self, msg: str) -> None:
        if self._verbose:
            import sys
            print(msg, flush=True, file=sys.stderr)

    def handshake(self) -> tuple[bytes, str]:
        """Full ATC handshake. Returns (device_grappa, anchor_str)."""
        ath = self._ath
        k = get_cf_constants()

        # Create connection
        self._conn = ath.ATHostConnectionCreateWithLibrary(
            cfstr("com.mediaporter.sync"), cfstr(self._device.udid), 0
        )
        if not self._conn:
            raise SyncError("ATHostConnectionCreateWithLibrary failed")
        self._log(f"  ATC connection created for {self._device.udid[:16]}...")

        # SendHostInfo
        empty_arr = cfarray()
        ath.ATHostConnectionSendHostInfo(self._conn, cfdict(
            LibraryID=cfstr(self.LIBRARY_ID),
            SyncHostName=cfstr(self.HOST_NAME),
            SyncedDataclasses=empty_arr,
            Version=cfstr(self.VERSION),
        ))
        self._log("  >> SendHostInfo")
        self._read_until("SyncAllowed")
        self._log("  << SyncAllowed")

        # RequestingSync with Grappa
        grappa_bytes = get_grappa_bytes()
        grappa_cf = cfdata(grappa_bytes)

        host_info = cfdict(
            Grappa=grappa_cf,
            LibraryID=cfstr(self.LIBRARY_ID),
            SyncHostName=cfstr(self.HOST_NAME),
            SyncedDataclasses=cfarray(),
            Version=cfstr(self.VERSION),
        )

        dataclasses = cfarray(cfstr("Media"), cfstr("Keybag"))

        msg = ath.ATCFMessageCreate(0, cfstr("RequestingSync"), cfdict(
            DataclassAnchors=cfdict(Media=cfstr("0")),
            Dataclasses=dataclasses,
            HostInfo=host_info,
        ))
        ath.ATHostConnectionSendMessage(self._conn, msg)

        self._log("  >> RequestingSync (with Grappa)")
        ready_msg, _ = self._read_until("ReadyForSync")
        if not ready_msg:
            raise SyncError("No ReadyForSync received — handshake failed")
        self._log("  << ReadyForSync")

        self._device_grappa = self._extract_device_grappa(ready_msg)
        if not self._device_grappa:
            raise SyncError("Failed to extract device Grappa from ReadyForSync")

        self._anchor = self._extract_anchor(ready_msg)
        self._log(f"  Device grappa: {len(self._device_grappa)}B, anchor: {self._anchor}")
        return self._device_grappa, self._anchor

    def build_sync_plist(self, files: list[_SyncFileInfo], anchor: int) -> bytes:
        """Build binary plist with insert_track operations."""
        now = datetime.datetime.now()  # naive datetime required

        operations = [
            {
                "operation": "update_db_info",
                "pid": random.randint(10**17, 10**18 - 1),
                "db_info": {
                    "subtitle_language": -1,
                    "primary_container_pid": 0,
                    "audio_language": -1,
                },
            },
        ]

        for f in files:
            item_dict = self._build_item_dict(f.item, now)
            operations.append({
                "operation": "insert_track",
                "pid": f.asset_id,
                "item": item_dict,
                "location": {"kind": "MPEG-4 video file"},
                "video_info": {
                    "has_alternate_audio": False,
                    "is_anamorphic": False,
                    "has_subtitles": False,
                    "is_hd": f.item.is_hd,
                    "is_compressed": False,
                    "has_closed_captions": False,
                    "is_self_contained": False,
                    "characteristics_valid": False,
                },
                "avformat_info": {
                    "bit_rate": f.item.bit_rate,
                    "audio_format": f.item.audio_format,
                    "channels": f.item.channels,
                },
                "item_stats": {
                    "has_been_played": False,
                    "play_count_recent": 0,
                    "play_count_user": 0,
                    "skip_count_user": 0,
                    "skip_count_recent": 0,
                },
            })

        return plistlib.dumps(
            {"revision": anchor, "timestamp": now, "operations": operations},
            fmt=plistlib.FMT_BINARY,
        )

    def compute_cig(self, device_grappa: bytes, plist_data: bytes) -> bytes:
        """Compute 21-byte CIG signature."""
        cig_lib = get_cig()
        import ctypes
        out = ctypes.create_string_buffer(21)
        olen = c_int(21)
        rc = cig_lib.cig_calc(device_grappa, plist_data, len(plist_data), out, byref(olen))
        if rc != 1:
            raise SyncError("CIG computation failed")
        return out.raw[:olen.value]

    def upload_and_register(
        self,
        afc: NativeAFC,
        files: list[_SyncFileInfo],
        plist_data: bytes,
        cig_data: bytes,
        anchor: str,
        progress_cb: Callable[[str, int, int], None] | None = None,
        files_already_uploaded: bool = False,
    ) -> None:
        """Upload files and complete the ATC sync protocol.

        progress_cb(filename, bytes_sent, total_bytes) called during file upload.
        files_already_uploaded: skip AFC file upload (files pre-uploaded before ATC session).
        """
        ath = self._ath
        k = get_cf_constants()
        new_anchor = anchor

        # Step 1: Write sync plist + CIG (small, fast)
        afc.makedirs("/iTunes_Control/Sync/Media")
        plist_path = f"/iTunes_Control/Sync/Media/Sync_{int(new_anchor):08d}.plist"
        afc.write_file(plist_path, plist_data)
        afc.write_file(plist_path + ".cig", cig_data)
        self._log(f"  AFC: plist+CIG -> {plist_path}")

        # Step 2: SendPowerAssertion + MetadataSyncFinished BEFORE big uploads
        # (avoids ATC session timeout during multi-GB file transfers)
        self._log("  >> SendPowerAssertion")
        ath.ATHostConnectionSendPowerAssertion(self._conn, k.kCFBooleanTrue)
        self._log(f'  >> MetadataSyncFinished (anchor="{new_anchor}")')
        ath.ATHostConnectionSendMetadataSyncFinished(
            self._conn,
            cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
            cfdict(Media=cfstr(new_anchor)),  # Anchor as STRING
        )

        # Step 3: Read AssetManifest
        got_manifest = False
        our_asset_ids = {str(f.asset_id) for f in files}
        self._log("  Waiting for AssetManifest...")
        for _ in range(30):
            msg, name = self._read_msg(timeout=15)
            if name in ("TIMEOUT", None):
                self._log(f"  << {name}")
                break
            self._log(f"  << {name}")
            if name == "Ping":
                self._send_pong()
                continue
            if name == "SyncFailed":
                if self._verbose:
                    self._cf.CFShow(msg)
                raise SyncError("Device rejected sync (SyncFailed)")
            if name == "AssetManifest":
                got_manifest = True
                if self._verbose:
                    self._cf.CFShow(msg)
                # Extract stale asset IDs from manifest
                stale_ids = self._extract_stale_assets(msg, our_asset_ids)
                break
            if name == "SyncFinished":
                self._log("  Device sent SyncFinished without AssetManifest (plist rejected?)")
                break

        if not got_manifest:
            raise SyncError("No AssetManifest received from device")

        # Step 4: Upload files + FileBegin/FileComplete
        afc.makedirs("/Airlock/Media")
        afc.makedirs("/Airlock/Media/Artwork")

        for f in files:
            total_size = f.item.file_size
            str_aid = str(f.asset_id)

            # FileBegin — always sent (even for pre-uploaded files)
            self._log(f"  >> FileBegin (asset={str_aid}, size={total_size // 1048576} MB)")
            ath.ATHostConnectionSendMessage(self._conn, ath.ATCFMessageCreate(
                0, cfstr("FileBegin"), cfdict(
                    AssetID=cfstr(str_aid),
                    FileSize=cfnum64(total_size),
                    TotalSize=cfnum64(total_size),
                    Dataclass=cfstr("Media"),
                )
            ))

            if files_already_uploaded:
                # Files pre-uploaded before ATC session — skip AFC upload
                self._log(f"  File already on device: {f.device_path}")
            else:
                afc.makedirs(f"/iTunes_Control/Music/{f.slot}")

                self._log(f"  AFC: uploading -> {f.device_path} ({total_size // 1048576} MB)")

                last_pct = [0]

                def _progress_cb(sent, total, _title=f.item.title, _total=total_size,
                                 _str_aid=str_aid, _last_pct=last_pct):
                    if progress_cb:
                        progress_cb(_title, sent, _total)
                    if _total > 0:
                        pct = int(sent * 100 / _total)
                        if pct >= _last_pct[0] + 10:
                            _last_pct[0] = pct - (pct % 10)
                            mb_sent = sent / 1048576
                            mb_total = _total / 1048576
                            self._log(f"  AFC: {mb_sent:.0f}/{mb_total:.0f} MB ({pct}%)")

                afc.write_file_streaming(f.device_path, f.item.file_path, _progress_cb)

                # Drain any pending ATC messages (Pings) that accumulated during upload
                self._log("  Draining ATC messages after upload...")
                for _ in range(20):
                    msg, name = self._read_msg(timeout=2)
                    if name == "TIMEOUT" or name is None:
                        break
                    self._log(f"  << {name}")
                    if name == "Ping":
                        self._send_pong()

            # Upload artwork to Airlock if available (always, even for pre-uploaded)
            if f.item.poster_data:
                artwork_path = f"/Airlock/Media/Artwork/{f.asset_id}"
                self._log(f"  AFC: artwork -> {artwork_path} ({len(f.item.poster_data) // 1024} KB)")
                afc.write_file(artwork_path, f.item.poster_data)

            # FileProgress + FileComplete AFTER upload
            ath.ATHostConnectionSendMessage(self._conn, ath.ATCFMessageCreate(
                0, cfstr("FileProgress"), cfdict(
                    AssetID=cfstr(str_aid),
                    AssetProgress=cfdouble(1.0),
                    OverallProgress=cfdouble(1.0),
                    Dataclass=cfstr("Media"),
                )
            ))

            self._log(f"  >> FileComplete (path={f.device_path})")
            ath.ATHostConnectionSendMessage(self._conn, ath.ATCFMessageCreate(
                0, cfstr("FileComplete"), cfdict(
                    AssetID=cfstr(str_aid),
                    AssetPath=cfstr(f.device_path),
                    Dataclass=cfstr("Media"),
                )
            ))

        # Send FileError for stale pending assets from previous failed syncs
        if stale_ids:
            self._log(f"  Clearing {len(stale_ids)} stale pending asset(s)...")
            for stale_id in stale_ids:
                self._log(f"  >> FileError (stale asset={stale_id})")
                ath.ATHostConnectionSendMessage(self._conn, ath.ATCFMessageCreate(
                    0, cfstr("FileError"), cfdict(
                        AssetID=cfstr(stale_id),
                        Dataclass=cfstr("Media"),
                        ErrorCode=cfnum32(0),
                    )
                ))

        # Read SyncFinished (handle Ping→Pong keepalive, max 120s wait)
        # For large files, the device may not send SyncFinished explicitly.
        # Instead it re-sends InstalledAssets/AssetMetrics/SyncAllowed — its idle
        # handshake cycle — which means it processed the sync and is ready for a
        # new session. We treat SyncAllowed after FileComplete as success.
        self._log("  Waiting for SyncFinished...")
        timeouts = 0
        got_sync_allowed = False
        for _ in range(120):
            try:
                msg, name = self._read_msg(timeout=5)
            except KeyboardInterrupt:
                self._log("  Interrupted by user")
                return
            if name == "TIMEOUT":
                timeouts += 1
                if got_sync_allowed:
                    # Device sent SyncAllowed (idle handshake) — sync is done
                    self._log("  *** SYNC COMPLETE (device returned to idle) ***")
                    return
                if timeouts >= 12:  # 60s of silence
                    self._log("  SyncFinished not received (timeout after 60s)")
                    return
                continue
            if name is None:
                break
            timeouts = 0
            self._log(f"  << {name}")
            if name == "Ping":
                self._send_pong()
                continue
            if name == "SyncFinished":
                self._log("  *** SYNC COMPLETE ***")
                return
            if name == "SyncAllowed":
                # Device re-sent its idle handshake — sync processed
                got_sync_allowed = True
                continue
            # InstalledAssets, AssetMetrics, Progress etc. — keep waiting
            continue

    def close(self) -> None:
        """Invalidate and release the ATC connection."""
        if self._conn:
            self._ath.ATHostConnectionInvalidate(self._conn)
            self._ath.ATHostConnectionRelease(self._conn)
            self._conn = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    def _extract_stale_assets(self, manifest_msg: c_void_p, our_ids: set[str]) -> list[str]:
        """Extract asset IDs from AssetManifest that aren't ours (stale pending)."""
        import ctypes
        ath = self._ath
        cf = self._cf

        stale = []
        try:
            manifest = ath.ATCFMessageGetParam(manifest_msg, cfstr("AssetManifest"))
            if not manifest:
                return stale

            media = cf.CFDictionaryGetValue(manifest, cfstr("Media"))
            if not media:
                return stale

            # media is a CFArray — get count and iterate
            cf.CFArrayGetCount = cf.CFArrayGetCount if hasattr(cf, '_array_count_set') else cf.CFArrayGetCount
            cf.CFArrayGetCount.restype = ctypes.c_long
            cf.CFArrayGetCount.argtypes = [c_void_p]
            cf.CFArrayGetValueAtIndex.restype = c_void_p
            cf.CFArrayGetValueAtIndex.argtypes = [c_void_p, ctypes.c_long]

            count = cf.CFArrayGetCount(media)
            for i in range(count):
                item = cf.CFArrayGetValueAtIndex(media, i)
                if not item:
                    continue
                aid_cf = cf.CFDictionaryGetValue(item, cfstr("AssetID"))
                if not aid_cf:
                    continue
                # AssetID might be a CFNumber — convert to string
                type_id = cf.CFGetTypeID(aid_cf)
                if type_id == cf.CFStringGetTypeID():
                    aid_str = cfstr_to_str(aid_cf)
                else:
                    # It's a CFNumber — read as int64
                    val = ctypes.c_int64(0)
                    cf.CFNumberGetValue.restype = ctypes.c_bool
                    cf.CFNumberGetValue.argtypes = [c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int64)]
                    cf.CFNumberGetValue(aid_cf, 4, ctypes.byref(val))
                    aid_str = str(val.value)

                if aid_str and aid_str not in our_ids:
                    stale.append(aid_str)
        except Exception as e:
            self._log(f"  Warning: failed to parse AssetManifest: {e}")

        return stale

    def _send_pong(self) -> None:
        """Respond to a Ping with Pong to keep the session alive."""
        self._log("  >> Pong")
        self._ath.ATHostConnectionSendMessage(
            self._conn,
            self._ath.ATCFMessageCreate(0, cfstr("Pong"), cfdict()),
        )

    def _read_msg(self, timeout: int = 15) -> tuple[c_void_p | None, str | None]:
        """Read an ATC message with thread-based timeout.

        Uses a background thread for the blocking native call so the main
        thread stays responsive to Ctrl+C (KeyboardInterrupt).
        """
        result: list = [None]  # [msg_or_None]
        done = threading.Event()

        def _reader():
            result[0] = self._ath.ATHostConnectionReadMessage(self._conn)
            done.set()

        t = threading.Thread(target=_reader, daemon=True)
        t.start()

        # Wait with short sleeps so Ctrl+C can interrupt
        elapsed = 0.0
        while elapsed < timeout:
            if done.wait(0.25):
                break
            elapsed += 0.25

        if not done.is_set():
            return None, "TIMEOUT"

        msg = result[0]
        if not msg:
            return None, None
        name = cfstr_to_str(self._ath.ATCFMessageGetName(msg))
        return msg, name

    def _read_until(
        self, target: str, max_msgs: int = 10, timeout: int = 8
    ) -> tuple[c_void_p | None, str | None]:
        """Read messages until a target message name is received."""
        for _ in range(max_msgs):
            msg, name = self._read_msg(timeout)
            if name in ("TIMEOUT", None):
                return None, name
            if name == target:
                return msg, name
        return None, "MAX_MSGS"

    def _extract_device_grappa(self, msg: c_void_p) -> bytes | None:
        """Extract device Grappa (83 bytes) from ReadyForSync message."""
        ath = self._ath
        cf = self._cf

        di = ath.ATCFMessageGetParam(msg, cfstr("DeviceInfo"))
        if not di or cf.CFGetTypeID(di) != cf.CFDictionaryGetTypeID():
            return None

        g = cf.CFDictionaryGetValue(di, cfstr("Grappa"))
        if not g or cf.CFGetTypeID(g) != cf.CFDataGetTypeID():
            return None

        return bytes(cf.CFDataGetBytePtr(g)[:cf.CFDataGetLength(g)])

    def _extract_anchor(self, msg: c_void_p) -> str:
        """Extract Media anchor (STRING) from ReadyForSync message."""
        ath = self._ath
        cf = self._cf

        anchors = ath.ATCFMessageGetParam(msg, cfstr("DataclassAnchors"))
        if not anchors:
            return "0"

        val = cf.CFDictionaryGetValue(anchors, cfstr("Media"))
        if not val:
            return "0"

        if cf.CFGetTypeID(val) == cf.CFStringGetTypeID():
            return cfstr_to_str(val) or "0"

        return "0"

    def _build_item_dict(self, item: SyncItem, now: datetime.datetime) -> dict:
        """Build the item dict for an insert_track operation."""
        d: dict = {
            "title": item.title,
            "sort_name": item.sort_name,
            "total_time_ms": item.duration_ms,
            "date_created": now,
            "date_modified": now,
            "remember_bookmark": True,
        }

        if item.poster_data:
            d["artwork_cache_id"] = random.randint(1, 9999)

        if item.is_tv_show:
            d["is_tv_show"] = True
            if item.tv_show_name:
                d["tv_show_name"] = item.tv_show_name
            if item.sort_tv_show_name:
                d["sort_tv_show_name"] = item.sort_tv_show_name
            if item.season_number is not None:
                d["season_number"] = item.season_number
            if item.episode_number is not None:
                d["episode_number"] = item.episode_number
            if item.episode_sort_id is not None:
                d["episode_sort_id"] = item.episode_sort_id
            if item.artist:
                d["artist"] = item.artist
                d["sort_artist"] = item.sort_artist or item.artist.lower()
            if item.album:
                d["album"] = item.album
                d["sort_album"] = item.sort_album or item.album.lower()
            if item.album_artist:
                d["album_artist"] = item.album_artist
                d["sort_album_artist"] = item.sort_album_artist or item.album_artist.lower()
        else:
            d["is_movie"] = True

        return d

    @staticmethod
    def generate_device_path() -> tuple[str, str]:
        """Generate a random device path. Returns (full_path, slot)."""
        slot = f"F{random.randint(0, 49):02d}"
        fname = "".join(random.choices(string.ascii_uppercase, k=4)) + ".mp4"
        return f"/iTunes_Control/Music/{slot}/{fname}", slot

    @staticmethod
    def generate_asset_id() -> int:
        """Generate a random 18-digit asset ID."""
        return random.randint(10**17, 10**18 - 1)


