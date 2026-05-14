# MediaPorter: Complete Video-to-iOS Transfer Implementation Guide

## Overview

This document is the protocol-level specification for transferring video files to an iOS device's TV app — without iTunes, Finder, or jailbreak. The protocol was reverse-engineered through LLDB wire-level tracing and AFC file inspection.

**Proven working**: Tested on iPhone / iPad (iOS 17 – 26+) with files from a few MB up to 8+ GB (HEVC, multi-audio, multi-sub). Videos appear in the TV app with correct metadata (`media_type=2048`, `media_kind=2`) and play.

**Shipping implementation (Swift)**: `MacApp/MediaPorter/Sources/Sync/` — `ATCSession.swift` (ATC protocol), `AFC.swift` (file transport), `Frameworks.swift` (`dlopen` of `MobileDevice.framework` + `AirTrafficHost.framework`, embedded `SyncAuthSeed`). The shipping app needs **no admin prompts**, no `sudo`, and no helper install — it talks to the system `remoted` / `usbmuxd` via the same private frameworks the OS already trusts.

**Frozen Python reference**: `python-reference/src/mediaporter/sync/` (importable module) and the standalone scripts under `python-reference/scripts/` — `atc_nodeps_sync.py` (zero-dependency: pure ctypes + Apple frameworks + libcig.dylib), `atc_proper_sync.py` (older, pymobiledevice3-based AFC). These are the original reverse-engineering artefacts; protocol-correct, but **frozen** — bug fixes land in Swift, not here. The Python path additionally requires `sudo pymobiledevice3 remote start-tunnel` once per boot to set up the iOS 17+ tunnel; the Swift app does not (it uses the system tunnel that `remoted` already maintains).

The Python snippets throughout this document remain the easiest way to read the protocol top-to-bottom; for production behaviour cross-reference the Swift sources cited inline.

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
│  │ Mobile- │ │ ◄────────────────────► │  │ medialibraryd│ │
│  │ Device  │ │  (file read/write)     │  │              │ │
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
| **AirTrafficHost.framework** | macOS private framework. Provides `ATHostConnection*` API for ATC protocol. `dlopen`-ed at runtime (not linked) so notarization passes. | `/System/Library/PrivateFrameworks/AirTrafficHost.framework/` (also `/Library/Apple/System/Library/PrivateFrameworks/`) |
| **MobileDevice.framework** | macOS private framework. Device discovery (`AMDeviceNotificationSubscribe`) AND AFC file transport (`AMDeviceStartService("com.apple.afc")` + `AFCFileRefOpen` etc.). Same `dlopen` strategy. | `/System/Library/PrivateFrameworks/MobileDevice.framework/` |
| **CoreFoundation.framework** | CF types (CFString, CFDictionary, CFNumber, CFData, CFArray). Used at the framework boundary. | System framework |
| **pymobiledevice3** | Python-only. Used by the older `atc_proper_sync.py` reference for AFC + iOS 17+ tunnel setup. The shipping Swift app uses native AFC via `MobileDevice.framework` and the system tunnel — pymobiledevice3 is **not** part of the shipping path. | `pip install pymobiledevice3` (Python reference only) |
| **libcig.dylib** | Compiled CIG (Cryptographic Integrity Guarantee) engine. Produces 21-byte signatures for sync plists. Bundled with the shipping app at `MacApp/MediaPorter/Resources/libcig.dylib` (arm64). Source: `scripts/cig/` (`cig.cpp` from `yinyajiang/go-tunes`). | Built via `clang++ -shared -fPIC -std=c++11 -O2` |
| **SyncAuthSeed (Grappa) blob** | 84-byte static authentication blob, replayable across sessions. Bundled with the shipping app as `MacApp/MediaPorter/Resources/SyncAuthSeed.dat` (XOR-masked at rest, un-masked in `Sync/Frameworks.swift::SyncAuthSeed`). Same blob hardcoded in go-tunes (`deviceGrapa`). | Repo: `MacApp/MediaPorter/Resources/SyncAuthSeed.dat` (Swift) and `python-reference/src/mediaporter/sync/data/SyncAuthSeed.dat` (Python) |

---

## Prerequisites

**Shipping app (Swift)**:
- macOS 13+
- USB-connected iOS device (trusted / paired in Finder once)
- `ffmpeg` / `ffprobe` on `$PATH` for transcode + analysis (`brew install ffmpeg`); release builds bundle ffmpeg inside the `.app`
- **No `sudo`, no helper install, no entitlements.** The system already runs `remoted` / `usbmuxd` and an iOS 17+ tunnel for trusted devices; the app talks to that via `MobileDevice.framework` + `AirTrafficHost.framework` (`dlopen`-ed at launch)

**Frozen Python reference**:
- macOS with Python 3.11+
- `pip install -e ".[dev]"` from `python-reference/`
- USB-connected iOS device
- iOS 17+ tunnel started by hand once per boot (this is the only step that needs root, and it's a Python-reference limitation — pymobiledevice3 reimplements the tunnel in userspace because it can't talk to the system one):
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
             Variant: {AssetParts: 3}}
        ]
    }
}}
```

If `AssetType` is `Music` instead of `Movie`, the `is_movie: True` field is missing from the plist.

**`Variant.AssetParts` is informational, not a contract.** It reports the device's notion of part count (the number of segments medialibraryd would expect for a hypothetical multi-part asset of this kind), but a single combined MP4 with multi-audio + multi-sub binds correctly with `AssetParts: 3` in the manifest. We send one `FileBegin` / `FileComplete` for the single uploaded MP4 regardless of the value. Confirmed on iOS 26 with HEVC + 3 audio + 2 sub MP4s. See HISTORY.md "2026-05-14 — SyncAllowed is NOT terminal" for the diagnostic that originally suspected `AssetParts` and ruled it out.

### Step 7: Upload File to Final Path

Upload the video file to a single location via AFC:

```python
# FINAL PATH — where the file lives for playback
#    /iTunes_Control/Music/F{00-49}/{4_RANDOM_CHARS}.mp4
slot = f'F{random.randint(0,49):02d}'
filename = random_4_uppercase_chars() + '.mp4'
final_path = f'/iTunes_Control/Music/{slot}/{filename}'
await afc.makedirs(f'/iTunes_Control/Music/{slot}')
await afc.set_file_contents(final_path, video_bytes)
```

**Airlock staging is NOT needed for the media file.** Previously believed essential for setting `media_type=2048`, but confirmed 2026-04-06 that `is_movie: True` + `location.kind` in the sync plist alone set the correct media type. Single upload of the .mp4 to `/iTunes_Control/Music/Fxx/` is sufficient.

(Airlock IS still used for **poster artwork** — write the JPEG to `/Airlock/Media/Artwork/<AssetID>` and set `artwork_cache_id` in the plist `item` dict. See CLAUDE.md rule #13.)

**IMPORTANT for large files:** Steps 5-6 (MetadataSyncFinished → AssetManifest) must happen BEFORE this upload. If you upload first and then send MetadataSyncFinished, the ATC session will time out for multi-GB files. Also, the device sends `Ping` messages during long uploads — respond with `Pong` to keep the session alive.

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

# Read SyncFinished — wait STRICTLY for SyncFinished, NOT SyncAllowed.
# SyncAllowed arrives early (right after MetadataSyncFinished / FileBegin)
# as a "you may proceed" signal and accumulates in any background reader
# during a long upload. Treating it as terminal returns before
# medialibraryd commits the row → row stays unbound, file gets swept by
# background GC. See HISTORY.md "2026-05-14 — SyncAllowed is NOT terminal".
for i in range(15):
    msg, name = read_msg(conn, timeout=10)
    if name == 'SyncFinished':
        print("Sync complete! Video is in TV app.")
        break
    # Ignore SyncAllowed / InstalledAssets / AssetMetrics — keep waiting.
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
| `item` | `media_type` | `2048` | Set by device from `is_movie: True` + `location.kind` in the insert_track plist |
| `item` | `in_my_library` | `1` | Visible in library |
| `item` | `base_location_id` | non-zero | Binding marker — `0` means the row exists but no file is bound; row is unplayable and the uploaded bytes will be GC'd |
| `item_extra` | `media_kind` | `2` | Set by device |
| `item_extra` | `location_kind_id` | `4` | Set by device |
| `item_extra` | `location` | `XXXX.mp4` | Filename only (no path) |
| `item_extra` | `title` | Video title | From plist `item.title` |
| `item_extra` | `sort_name` | lowercase title | From plist `item.sort_name` |
| `item_extra` | `total_time_ms` | duration | From plist `item.total_time_ms` |
| `item_extra` | `file_size` | byte count | Set on bind; `0` is the same "unbound" signal as `base_location_id=0` |

**Diagnosing "row exists but won't play"**: pull `MediaLibrary.sqlitedb` via AFC and check `base_location_id` + `location` + `file_size` for the title. All three at zero / empty means the bind never completed — most often because `finishSync` returned on `SyncAllowed` instead of `SyncFinished`. See CLAUDE.md rule #14.

---

## CIG (Cryptographic Integrity Guarantee)

The CIG signature protects the sync plist from tampering. It uses a modified SHA-1 with S-box key expansion.

**Input:** Device Grappa (83 bytes from `ReadyForSync.Params.DeviceInfo.Grappa`) + plist bytes
**Output:** 21 bytes

**Source:** `scripts/cig/cig.cpp` + `cig_wrapper.cpp` (from `yinyajiang/go-tunes`). Compiled `libcig.dylib` (arm64) is bundled at `MacApp/MediaPorter/Resources/libcig.dylib`.

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
Binary plist is required, not XML. Python: `plistlib.dumps(..., fmt=plistlib.FMT_BINARY)`. Swift: `PropertyListSerialization.data(fromPropertyList:format: .binary, options: 0)`.

### 2. Naive Datetime (Python only)
Binary plist serialization in Python requires naive datetime (no timezone info). Use `datetime.datetime.now()` not `datetime.datetime.now(datetime.timezone.utc)`. Swift `Date` serializes correctly without ceremony.

### 3. String vs Number Types
On the ATC wire, **all anchors and AssetIDs are strings**. Pass them as `cfstr(str(value))` (Python) / `String(value) as CFString` (Swift), not as numbers. `FileSize` / `TotalSize` are 64-bit numbers.

### 4. Stale Asset Handling
Failed syncs leave "pending download" entries in the device's manifest. These accumulate across sessions. Send `FileError(ErrorCode=0)` for any asset in the manifest that isn't yours, or the device will wait forever for them (causing TIMEOUT instead of SyncFinished).

### 5. File Extension
Use `.mp4` for the final filename even for `.m4v` input files. Both work on the device.

### 6. Video Compatibility
The video file must be in a format the device can play:
- **Container:** MP4/M4V (use `-f mp4` with ffmpeg for .m4v output — the `.m4v` extension otherwise picks the ipod muxer which can't do HEVC)
- **Video codec:** H.264 or HEVC (H.265) with `hvc1` tag (`-tag:v hvc1`)
- **Audio codec:** AAC, EAC3 (copy through). AC3 is dropped from the iPad TV-app audio switcher — transcode AC3→AAC. See `AUDIO_SWITCHER_RULE.md`.

### 7. AFC transport (Swift uses `MobileDevice.framework` natively)
The shipping Swift app talks AFC directly via `AMDeviceStartService("com.apple.afc")` + `AFCFileRefOpen` / `AFCFileRefWrite` / `AFCFileRefClose`. See `MacApp/MediaPorter/Sources/Sync/AFC.swift`. The Python reference uses `pymobiledevice3.services.afc` (async, v9.x — `async / await` with `asyncio.run()`); this is a Python-implementation detail, not a protocol requirement.

### 8. `SyncAllowed` is NOT terminal-equivalent to `SyncFinished`
`SyncAllowed` arrives early in the post-MetadataSyncFinished phase as "you may proceed" — during a long upload it accumulates in any background reader. Only `SyncFinished` confirms medialibraryd has committed the row. If `finishSync` accepts `SyncAllowed` it returns before the bind, leaving the row with `base_location_id=0` and orphaning the bytes for background GC. See CLAUDE.md rule #14 + HISTORY.md "2026-05-14".

---

## Confirmed Dead Ends

These approaches were tested and do NOT work:

| Approach | Why it fails |
|----------|-------------|
| Code-signed .app with `com.apple.private.fpsd.client` (or any other private entitlement) | macOS kills the process at launch with private Apple entitlements, even on SIP-disabled developer machines. Notarization would also reject it. The shipping app uses **no private entitlements** — it `dlopen`s the framework instead. |
| `DYLD_INSERT_LIBRARIES` injection into Apple binaries | Blocked by library validation. |
| Grappa struct patch (offset 0x5C) inside CoreFP | Triggers CoreFP but creates DB entries with empty location. Replaying the static 84-byte Grappa as `SyncAuthSeed` is the working path. |
| Direct `MediaLibrary.sqlitedb` modification via AFC | `medialibraryd` reverts the row within seconds. Use the ATC `insert_track` plist instead. |
| ~~Setting `media_kind`/`media_type` via sync plist fields~~ | **CORRECTED**: `is_movie: True` + `location.kind: "MPEG-4 video file"` in `insert_track` give `media_type=2048`, `media_kind=2`, `location_kind_id=4`. Earlier testing missed these specific fields. |
| Raw ATC connection (manual TCP-style protocol without `ATHostConnection`) | Device silently ignores `MetadataSyncFinished` because the framework also manages PowerAssertion / SyncSession state the device expects. Use `ATHostConnection*`. |
| ~~Writing file only to `/iTunes_Control/Music/Fxx/` (without Airlock)~~ | **CORRECTED**: Single upload to `/iTunes_Control/Music/Fxx/` works when `is_movie: True` is in the plist. Airlock was a red herring; not used in shipping. |
| AFC hardlink/symlink between Airlock and `iTunes_Control` | `AFCLinkPath` returns error 15 — cross-directory links not allowed on iOS. |
| Uploading large files before `MetadataSyncFinished` | ATC session times out during multi-GB uploads. Send `MetadataSyncFinished` first, then upload. |
| Treating `SyncAllowed` as terminal-equivalent to `SyncFinished` | `SyncAllowed` arrives early (post-FileBegin) as "you may proceed" and accumulates in the inbox during long uploads. Returning on it leaves the row unbound (`base_location_id=0`) and the file gets GC'd. Wait strictly for `SyncFinished`. See HISTORY.md "2026-05-14". |

---

## File Locations on Device

| Path | Purpose |
|------|---------|
| `/iTunes_Control/Sync/Media/Sync_XXXX.plist` | Sync operation plist (consumed by device) |
| `/iTunes_Control/Sync/Media/Sync_XXXX.plist.cig` | CIG signature for plist |
| `/iTunes_Control/Music/F{00-49}/XXXX.mp4` | Final media file location (single upload target) |
| `/iTunes_Control/iTunes/MediaLibrary.sqlitedb` | Media library database |
| `/Airlock/Media/<AssetID>` | ~~Media staging~~ NOT needed for media files — `is_movie: True` in plist suffices |
| `/Airlock/Media/Artwork/<AssetID>` | Poster artwork JPEG (paired with `artwork_cache_id` in the plist `item` dict). See CLAUDE.md #13. |

---

## Error Codes

| ATC ErrorCode | Meaning |
|---------------|---------|
| 4 | Invalid Grappa blob |
| 12 | No Grappa provided |
| 23 | Wrong message sequence |

---

## Testing

**Shipping app (Swift)**:
```bash
cd MacApp && swift build && .build/debug/MediaPorter      # GUI
cd MacApp && swift run mediaporterctl ls /iTunes_Control/Music/F00   # CLI: list
cd MacApp && swift run mediaporterctl pull /iTunes_Control/iTunes/MediaLibrary.sqlitedb /tmp/m.sqlitedb
sqlite3 /tmp/m.sqlitedb 'SELECT ie.title, i.media_type, i.base_location_id, ie.file_size FROM item i JOIN item_extra ie ON i.item_pid=ie.item_pid ORDER BY i.item_pid DESC LIMIT 5;'
```

`base_location_id != 0` and `file_size != 0` ⇒ row is bound and the file will play. Both zero ⇒ unbound, the uploaded bytes will be GC'd.

**Frozen Python reference**:
```bash
# Single video transfer (zero-dependency version)
python python-reference/scripts/atc_nodeps_sync.py path/to/video.m4v "Video Title"

# Or with pymobiledevice3 version:
# python python-reference/scripts/atc_proper_sync.py path/to/video.m4v "Video Title"
```

The shipping debug log lives at `/tmp/mediaporter-debug.log`; tail it during a sync to see ATC wire events (`atc.MetadataSyncFinished`, `atc.manifest`, `atc.FileBegin`, `atc.FileProgress`, `atc.FileComplete`, `atc.finishSync.done via=...`).

---

## References

**Source code**:
- Swift shipping implementation: `MacApp/MediaPorter/Sources/Sync/` — `ATCSession.swift`, `AFC.swift`, `Frameworks.swift`, `SyncEngine.swift`
- Python frozen reference: `python-reference/src/mediaporter/sync/` (importable) and `python-reference/scripts/` (standalone)
- CIG engine: `scripts/cig/` (`cig.cpp`, `cig.h`, `cig_wrapper.cpp`); compiled `libcig.dylib` shipped at `MacApp/MediaPorter/Resources/`

**Companion docs**:
- `ATC_SYNC_FLOW.md` — wire-level message dictionaries and state machine
- `HISTORY.md` — chronological findings log (most recent: 2026-05-14 SyncAllowed/SyncFinished diagnosis)
- `AUDIO_SWITCHER_RULE.md` — AC3 / disposition-flag interaction with the iPad TV-app picker
- `MEDIA_LIBRARY_DB.md` — schema notes for `MediaLibrary.sqlitedb`
- `GRAPPA.md` — Grappa blob format and replay analysis

**External**:
- **go-tunes** (`yinyajiang/go-tunes` on GitHub) — Open-source Go implementation of ringtone sync via ATC. Source of the CIG engine and the hardcoded `deviceGrapa` blob we replay as `SyncAuthSeed`.
- **IpaInstall** (`Kerrbty/IpaInstall` on GitHub) — Windows tool that calls `AirFairSyncGrappaCreate` via a fake struct. Useful for understanding Grappa generation, not used at runtime.
- **pymobiledevice3** — Python library for iOS device communication (AFC, lockdown, tunnel). Used by the Python reference, not the Swift shipping path.
