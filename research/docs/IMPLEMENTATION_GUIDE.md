# MediaPorter: Complete Video-to-iOS Transfer Implementation Guide

## Overview

This document is a complete, detailed specification for building a macOS CLI application that transfers video files to an iOS device's TV app — without iTunes, Finder, or jailbreak. The protocol was reverse-engineered through LLDB wire-level tracing and AFC file inspection.

**Proven working**: Tested on iPad (iOS 17+) with `test_tiny_red.m4v`. Videos appear instantly in the TV app with correct metadata (`media_type=2048`, `media_kind=2`).

**Reference implementation**: `scripts/atc_nodeps_sync.py` (zero-dependency: pure ctypes + Apple frameworks + libcig.dylib, no pymobiledevice3). An earlier version using pymobiledevice3 for AFC is `scripts/atc_proper_sync.py`.

---

## Architecture

```
┌─────────────┐      USB/usbmuxd       ┌─────────────────┐
│  macOS Host  │ ◄──────────────────► │   iOS Device      │
│              │                        │                   │
│  ┌─────────┐ │  ATC (com.apple.atc)   │  ┌─────────────┐ │
│  │ AirTraf.│ │ ◄────────────────────► │  │  ATC Daemon  │ │
│  │ Host.fw │ │  (4B LE len + bplist)  │  │              │ │
│  └─────────┘ │                        │  └──────┬───────┘ │
│              │                        │         │         │
│  ┌─────────┐ │  AFC (com.apple.afc)   │  ┌──────▼───────┐ │
│  │pymobile │ │ ◄────────────────────► │  │ medialibraryd│ │
│  │device3  │ │  (file read/write)     │  │              │ │
│  └─────────┘ │                        │  └──────────────┘ │
│              │                        │                   │
│  ┌─────────┐ │                        │  ┌──────────────┐ │
│  │ CIG lib │ │                        │  │  TV App      │ │
│  │(libcig) │ │                        │  │              │ │
│  └─────────┘ │                        │  └──────────────┘ │
└─────────────┘                        └───────────────────┘
```

### Components

| Component | Role | Source |
|-----------|------|--------|
| **AirTrafficHost.framework** | macOS private framework. Provides `ATHostConnection*` API for ATC protocol. Loaded via `ctypes`. | `/System/Library/PrivateFrameworks/AirTrafficHost.framework/` or `/Library/Apple/System/Library/PrivateFrameworks/AirTrafficHost.framework/` |
| **MobileDevice.framework** | macOS private framework. Device discovery via `AMDeviceNotificationSubscribe`. | `/System/Library/PrivateFrameworks/MobileDevice.framework/` |
| **CoreFoundation.framework** | CF types (CFString, CFDictionary, CFNumber, CFData, CFArray). | System framework |
| **pymobiledevice3** | Python library for AFC file operations (async, v9.x). Used by `atc_proper_sync.py`; NOT needed by `atc_nodeps_sync.py` which uses native AFC via MobileDevice.framework. | `pip install pymobiledevice3` |
| **libcig.dylib** | Compiled CIG (Cryptographic Integrity Guarantee) engine. Produces 21-byte signatures for sync plists. Source: `cig.cpp` (from `yinyajiang/go-tunes` on GitHub). | Compiled with `clang++ -shared -fPIC -std=c++11 -O2` |
| **Grappa blob** | 84-byte static authentication blob. Replayable across sessions. Same blob is hardcoded in go-tunes. | `traces/grappa.bin` |

---

## Prerequisites

- **macOS** with Python 3.11+
- **USB-connected iOS device** (trusted/paired)
- **pymobiledevice3** (`pip install pymobiledevice3`)
- **ffmpeg/ffprobe** for video analysis (optional but recommended)
- **iOS 17+ tunnel** (required for device connection):
  ```bash
  sudo pymobiledevice3 remote start-tunnel
  # Or as daemon: sudo pymobiledevice3 remote tunneld -d
  ```

---

## Complete Sync Protocol (9 Steps)

### Step 1: Device Discovery

Use `MobileDevice.framework` via ctypes to find the connected device.

```python
AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)

def device_callback(info_ptr, _):
    device = cast(info_ptr, POINTER(c_void_p))[0]
    if device:
        MD.AMDeviceRetain(device)
        udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))

notification = c_void_p()
MD.AMDeviceNotificationSubscribe(callback, 0, 0, None, byref(notification))
# Pump CFRunLoop until device found
for _ in range(50):
    CF.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
    if device_found: break
```

### Step 2: ATC Connection + HostInfo

Create an ATHostConnection and send HostInfo. The framework internally starts the `com.apple.atc` lockdown service, the notification proxy (for `com.apple.atc.idlewake`), and reads initial device messages (Capabilities, InstalledAssets, AssetMetrics, SyncAllowed).

```python
conn = ATH.ATHostConnectionCreateWithLibrary(
    cfstr('com.yourapp.sync'),   # Library identifier (arbitrary)
    cfstr(device_udid),           # Device UDID
    0                             # Flags
)

ATH.ATHostConnectionSendHostInfo(conn, cfdict(
    LibraryID=cfstr('YOUR_LIBRARY_ID'),  # 16-char hex string
    SyncHostName=cfstr('hostname'),       # Computer name
    SyncedDataclasses=empty_array,        # Empty CFArray
    Version=cfstr('12.8')                 # Protocol version
))

# Read until SyncAllowed
read_until(conn, 'SyncAllowed')
```

**HostInfo is sent on the wire as:**
```
{Session: 0, Command: "HostInfo", Params: {
    LocalCloudSupport: false,
    HostInfo: {LibraryID, SyncHostName, SyncedDataclasses, Version}
}}
```

### Step 3: RequestingSync with Grappa

Send a RequestingSync message containing the replayed 84-byte Grappa blob. This authenticates the sync session.

```python
grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, 84)

host_info = cfdict(
    Grappa=grappa_cf,
    LibraryID=cfstr('YOUR_LIBRARY_ID'),
    SyncHostName=cfstr('hostname'),
    SyncedDataclasses=empty_array,
    Version=cfstr('12.8')
)

params = cfdict(
    DataclassAnchors=cfdict(Media=cfstr('0')),  # STRING '0', not int!
    Dataclasses=array_of(['Media', 'Keybag']),
    HostInfo=host_info
)

msg = ATH.ATCFMessageCreate(0, cfstr('RequestingSync'), params)
ATH.ATHostConnectionSendMessage(conn, msg)
```

**Read until `ReadyForSync`.** Extract:
- **Device Grappa** (83 bytes) from `Params.DeviceInfo.Grappa` — needed for CIG computation
- **Anchor** (string) from `Params.DataclassAnchors.Media` — increment by 1 for our sync

**The Grappa blob** (84 bytes, hex):
```
0101 1111 1111 1111 1111 1111 1111 1111
1111 0440 bc27 85e0 dbf1 6636 1e07 980a
5ea4 8dba 95b3 b8ea 265d 62ae fea5 1bb7
b190 e0b7 7126 290a d39b b13f ecc0 8c25
a956 1c51 7ac1 1e64 905d a029 e61b dfd0
ba22 c313
```

This blob is static and replayable. It is the same blob hardcoded in the open-source `yinyajiang/go-tunes` project.

### Step 4: Build and Write Sync Plist + CIG

Build a **binary plist** (NOT XML) containing the insert_track operation, write it to the device via AFC along with its CIG signature.

**Plist structure:**

```python
sync_plist = plistlib.dumps({
    'revision': new_anchor,          # int, device anchor + 1
    'timestamp': datetime.now(),     # naive datetime (no timezone)
    'operations': [
        # Operation 1: update_db_info (required)
        {
            'operation': 'update_db_info',
            'pid': random_int64(),
            'db_info': {
                'subtitle_language': -1,
                'primary_container_pid': 0,
                'audio_language': -1,
            },
        },
        # Operation 2: insert_track (the video entry)
        {
            'operation': 'insert_track',
            'pid': asset_id,           # random int64, used as AssetID
            'item': {
                'title': 'Video Title',
                'sort_name': 'video title',
                'total_time_ms': duration_ms,
                'date_created': datetime.now(),
                'date_modified': datetime.now(),
                'is_movie': True,              # ← CRITICAL: makes AssetType=Movie
                'remember_bookmark': True,      # enables resume playback
                # Optional metadata:
                # 'artist': '...', 'album': '...', 'album_artist': '...',
                # 'sort_artist': '...', 'sort_album': '...', 'sort_album_artist': '...',
                # 'artwork_cache_id': int,
            },
            'location': {
                'kind': 'MPEG-4 video file',   # ← CRITICAL: file type descriptor
            },
            'video_info': {
                'has_alternate_audio': False,
                'is_anamorphic': False,
                'has_subtitles': False,
                'is_hd': False,                # set True for 720p+
                'is_compressed': False,
                'has_closed_captions': False,
                'is_self_contained': False,
                'characteristics_valid': False,
            },
            'avformat_info': {
                'bit_rate': 160,               # audio bitrate (kbps?)
                'audio_format': 502,           # AAC = 502
                'channels': 2,                 # audio channels
            },
            'item_stats': {
                'has_been_played': False,
                'play_count_recent': 0,
                'play_count_user': 0,
                'skip_count_user': 0,
                'skip_count_recent': 0,
            },
        },
    ],
}, fmt=plistlib.FMT_BINARY)   # MUST be binary plist, not XML
```

**Key fields that control media classification:**
| Field | Value | Effect |
|-------|-------|--------|
| `item.is_movie` | `True` | Sets `AssetType=Movie` in manifest, `media_type=2048` in DB |
| `location.kind` | `"MPEG-4 video file"` | File type descriptor |
| `video_info` dict | (present) | Signals this is video content |

**CIG computation:**
```python
# CIG = cryptographic signature over plist bytes using device Grappa
# Input: device_grappa (83 bytes from ReadyForSync) + plist_bytes
# Output: 21 bytes
cig_bytes = cig_calc(device_grappa, sync_plist_bytes)
```

The CIG engine is compiled from `cig.cpp` (from go-tunes). It uses a modified SHA-1 with S-box key expansion.

**Write to device via AFC:**
```python
# Path: /iTunes_Control/Sync/Media/Sync_{anchor:08d}.plist + .cig
await afc.set_file_contents(f'/iTunes_Control/Sync/Media/Sync_{anchor:08d}.plist', plist_bytes)
await afc.set_file_contents(f'/iTunes_Control/Sync/Media/Sync_{anchor:08d}.plist.cig', cig_bytes)
```

### Step 5: SendPowerAssertion + MetadataSyncFinished

**Both calls are REQUIRED.** SendPowerAssertion prevents the device from sleeping during sync. MetadataSyncFinished tells the device to read the sync plists.

```python
ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)

ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),   # SyncTypes
    cfdict(Media=cfstr(str(new_anchor)))             # Anchors as STRING!
)
```

**Wire format** (the framework translates this to):
```
{Session: 0, Command: "FinishedSyncingMetadata", Params: {
    DataclassAnchors: {Media: "10"},   // STRING
    SyncTypes: {Media: 1, Keybag: 1}
}}
```

**IMPORTANT:** The wire command name is `FinishedSyncingMetadata`, NOT `MetadataSyncFinished`. The high-level API function handles this translation internally.

### Step 6: Read AssetManifest

The device processes the sync plist and responds with an AssetManifest listing assets that need file data.

```python
for i in range(20):
    msg, name = read_msg(conn, timeout=15)
    if name == 'AssetManifest':
        # Success! Device wants our file
        break
    if name == 'SyncFinished':
        # Device didn't create an entry (plist format wrong?)
        break
```

**Expected AssetManifest response:**
```
{Command: "AssetManifest", Params: {
    AssetManifest: {
        Media: [
            {AssetID: 449875709684448843, AssetType: "Movie", IsDownload: 1,
             Variant: {AssetParts: 1}}
        ]
    }
}}
```

If `AssetType` is `Music` instead of `Movie`, the `is_movie: True` field is missing from the plist.

### Step 7: Upload File to Airlock + Final Path

Write the video file to TWO locations via AFC:

```python
# 1. STAGING PATH — device processes media type from here
#    /Airlock/Media/<AssetID>
await afc.makedirs('/Airlock/Media')
await afc.makedirs('/Airlock/Media/Artwork')
await afc.set_file_contents(f'/Airlock/Media/{asset_id}', video_bytes)

# 2. FINAL PATH — where the file lives for playback
#    /iTunes_Control/Music/F{00-49}/{4_RANDOM_CHARS}.mp4
slot = f'F{random.randint(0,49):02d}'
filename = random_4_uppercase_chars() + '.mp4'
final_path = f'/iTunes_Control/Music/{slot}/{filename}'
await afc.makedirs(f'/iTunes_Control/Music/{slot}')
await afc.set_file_contents(final_path, video_bytes)
```

**The `/Airlock/Media/<AssetID>` path is critical.** This is the staging directory that `medialibraryd` monitors. When a file is placed here during an ATC sync, the device:
1. Reads the file content
2. Determines media type (sets `media_type=2048` for video)
3. Creates the DB entry with correct metadata
4. Consumes (deletes) the Airlock file

Without the Airlock write, entries are created with `media_type=0` (invisible in TV app).

### Step 8: Send FileBegin + FileComplete

Send ATC protocol messages to register the file transfer.

```python
str_aid = str(asset_id)

# FileBegin
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0,
    cfstr('FileBegin'), cfdict(
        AssetID=cfstr(str_aid),         # STRING, not number!
        FileSize=cfnum64(file_size),
        TotalSize=cfnum64(file_size),
        Dataclass=cfstr('Media')
    )))

# FileProgress (report 100%)
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0,
    cfstr('FileProgress'), cfdict(
        AssetID=cfstr(str_aid),
        AssetProgress=cf_double(1.0),
        OverallProgress=cf_double(1.0),
        Dataclass=cfstr('Media')
    )))

# FileComplete — uses FINAL path (not Airlock path!)
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0,
    cfstr('FileComplete'), cfdict(
        AssetID=cfstr(str_aid),
        AssetPath=cfstr(final_path),     # /iTunes_Control/Music/Fxx/name.mp4
        Dataclass=cfstr('Media')
    )))
```

**IMPORTANT:** `AssetID` must be a **STRING** in all messages.

### Step 9: Handle Stale Assets + Read SyncFinished

If the AssetManifest contains assets from previous failed syncs, send `FileError` for each to clear them. Otherwise the device waits for all assets and never sends `SyncFinished`.

```python
# For each stale asset ID in the manifest that isn't ours:
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0,
    cfstr('FileError'), cfdict(
        AssetID=cfstr(stale_asset_id),
        Dataclass=cfstr('Media'),
        ErrorCode=cfnum32(0)
    )))

# Read SyncFinished
for i in range(15):
    msg, name = read_msg(conn, timeout=10)
    if name == 'SyncFinished':
        print("Sync complete! Video is in TV app.")
        break
```

### Cleanup

```python
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
```

---

## Database Values (Verified)

After successful sync, the entry in `MediaLibrary.sqlitedb`:

| Table | Column | Value | Notes |
|-------|--------|-------|-------|
| `item` | `media_type` | `2048` | Set by device from Airlock processing |
| `item` | `in_my_library` | `1` | Visible in library |
| `item_extra` | `media_kind` | `2` | Set by device |
| `item_extra` | `location_kind_id` | `4` | Set by device |
| `item_extra` | `location` | `XXXX.mp4` | Filename only (no path) |
| `item_extra` | `title` | Video title | From plist `item.title` |
| `item_extra` | `sort_name` | lowercase title | From plist `item.sort_name` |
| `item_extra` | `total_time_ms` | duration | From plist `item.total_time_ms` |

---

## CIG (Cryptographic Integrity Guarantee)

The CIG signature protects the sync plist from tampering. It uses a modified SHA-1 with S-box key expansion.

**Input:** Device Grappa (83 bytes from `ReadyForSync.Params.DeviceInfo.Grappa`) + plist bytes
**Output:** 21 bytes

**Source:** `scripts/cig/cig.cpp` (from go-tunes project, publicly available on GitHub)

**Build:**
```bash
clang++ -shared -fPIC -fvisibility=hidden -std=c++11 -O2 \
    -o libcig.dylib cig_wrapper.cpp cig.cpp
```

**API:**
```c
// Returns 1 on success, 0 on failure
int cig_calc(
    unsigned char* grappa,      // 83-byte device grappa
    unsigned char* data,        // plist bytes
    int data_len,               // plist length
    unsigned char* cig_out,     // output buffer (21+ bytes)
    int* cig_len                // output: actual CIG length (always 21)
);
```

---

## Critical Implementation Details

### 1. Binary Plist Format
Binary plist (`FMT_BINARY`) is required, not XML. Use `plistlib.dumps(..., fmt=plistlib.FMT_BINARY)`.

### 2. Naive Datetime
Binary plist serialization in Python requires naive datetime (no timezone info). Use `datetime.datetime.now()` not `datetime.datetime.now(datetime.timezone.utc)`.

### 3. String vs Number Types
On the ATC wire, **all anchors and AssetIDs are strings**. Pass them as `cfstr(str(value))`, not `cfnum64(value)`. FileSize/TotalSize are numbers (`cfnum64`).

### 4. Stale Asset Handling
Failed syncs leave "pending download" entries in the device's manifest. These accumulate across sessions. Send `FileError` for any asset in the manifest that isn't yours, or the device will wait forever for them (causing TIMEOUT instead of SyncFinished).

### 5. File Extension
Use `.mp4` for the final filename even for `.m4v` input files. Both work on the device.

### 6. Video Compatibility
The video file must be in a format the device can play:
- **Container:** MP4/M4V (use `-f mp4` with ffmpeg for .m4v output)
- **Video codec:** H.264 or HEVC (H.265) with `hvc1` tag (`-tag:v hvc1`)
- **Audio codec:** AAC or AC-3

### 7. pymobiledevice3 v9.x is Fully Async
All AFC operations must use `async/await` with `asyncio.run()`.

---

## Confirmed Dead Ends

These approaches were tested and do NOT work:

| Approach | Why it fails |
|----------|-------------|
| Code-signed .app with `com.apple.private.fpsd.client` | macOS kills process with private entitlements (even with SIP debug disabled) |
| `DYLD_INSERT_LIBRARIES` injection | Blocked by library validation for Apple binaries |
| Grappa struct patch (offset 0x5C) | Triggers CoreFP but creates entries with empty location |
| Direct `MediaLibrary.sqlitedb` modification | `medialibraryd` reverts changes within seconds |
| Setting `media_kind`/`media_type` via sync plist fields | Device ignores ALL field placements (tested exhaustively) |
| Raw ATC connection (manual protocol without ATHostConnection) | Device ignores `MetadataSyncFinished` (connection state not managed) |
| Writing file only to `/iTunes_Control/Music/Fxx/` (without Airlock) | Creates entry with `media_type=0` (invisible) |

---

## File Locations on Device

| Path | Purpose |
|------|---------|
| `/iTunes_Control/Sync/Media/Sync_XXXX.plist` | Sync operation plist (consumed by device) |
| `/iTunes_Control/Sync/Media/Sync_XXXX.plist.cig` | CIG signature for plist |
| `/Airlock/Media/<AssetID>` | Staging area for file transfer (consumed by device) |
| `/Airlock/Media/Artwork/` | Artwork staging (create empty dir) |
| `/iTunes_Control/Music/F{00-49}/XXXX.mp4` | Final media file location |
| `/iTunes_Control/iTunes/MediaLibrary.sqlitedb` | Media library database |

---

## Error Codes

| ATC ErrorCode | Meaning |
|---------------|---------|
| 4 | Invalid Grappa blob |
| 12 | No Grappa provided |
| 23 | Wrong message sequence |

---

## Testing

```bash
# Single video transfer (zero-dependency version)
python scripts/atc_nodeps_sync.py path/to/video.m4v "Video Title"

# Or with pymobiledevice3 version:
# python scripts/atc_proper_sync.py path/to/video.m4v "Video Title"

# Verify in DB
python3 -c "
import asyncio, sqlite3, tempfile
async def check():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        tmp = tempfile.mkdtemp()
        open(f'{tmp}/db','wb').write(await a.get_file_contents('/iTunes_Control/iTunes/MediaLibrary.sqlitedb'))
        db = sqlite3.connect(f'{tmp}/db')
        for r in db.execute('SELECT ie.title, i.media_type, ie.media_kind FROM item i JOIN item_extra ie ON i.item_pid=ie.item_pid ORDER BY i.item_pid DESC LIMIT 5'):
            print(r)
asyncio.run(check())
"
```

---

## References

- **go-tunes** (`yinyajiang/go-tunes`) — Open-source Go implementation of ringtone sync via ATC. Source of CIG engine and hardcoded Grappa blob.
- **IpaInstall** (`Kerrbty/IpaInstall`) — Windows tool that calls AirFairSyncGrappaCreate via fake struct. Analysis of Grappa generation mechanism.
- **pymobiledevice3** — Python library for iOS device communication (AFC, lockdown, etc.)
