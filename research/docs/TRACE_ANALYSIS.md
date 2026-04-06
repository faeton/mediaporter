# ATC Protocol Trace Analysis — 2026-04-02

## Summary

LLDB traces of successful ATC sync sessions on iPad (iOS 26.3.1). These traces serve as the reference for the correct ATC message flow and were used to identify the critical protocol elements needed for video sync to the TV app.

## Key Finding: Grappa IS Required

The 84-byte Grappa blob must be embedded inside the `RequestingSync` message at `Params.HostInfo.Grappa`. The AirTrafficHost.framework generates this internally for signed processes. For unsigned processes like ours, the same static blob (found hardcoded in `yinyajiang/go-tunes` on GitHub) can be replayed.

Three services are needed:
1. `com.apple.afc` — Apple File Conduit
2. `com.apple.atc` — AirTrafficControl (NOT atc2)
3. `com.apple.mobile.notification_proxy` — for `com.apple.atc.idlewake`

## Exact ATC Call Sequence (from LLDB traces)

```
1. AMDeviceSecureStartService("com.apple.afc")
2. ATHostConnectionSendHostInfo({
       LibraryID = "E6ED8ADC1A1A1323",
       SyncHostName = "m3max",
       SyncedDataclasses = (),
       Version = "12.8"
   })
   → ATCFMessageCreate("HostInfo", {
       HostInfo = {above},
       LocalCloudSupport = 0
   })
3. ATHostConnectionReadMessage (first call — triggers internal ATC setup):
   - AMDeviceSecureStartService("com.apple.atc")
   - 9× AMDServiceConnectionReceive (device sends Capabilities, InstalledAssets, etc.)
   - 1× AMDServiceConnectionSend (HostInfo to ATC service)
   - AMDeviceSecureStartService("com.apple.mobile.notification_proxy")
   - ObserveNotification("com.apple.atc.idlewake")
4. ATHostConnectionReadMessage × 3 (returns InstalledAssets, AssetMetrics, SyncAllowed)
5. ATHostConnectionSendMessage — THE KEY MESSAGE:
   → RequestingSync {
       DataclassAnchors = { Media = 0 },
       Dataclasses = ( Media, Keybag ),
       HostInfo = {
           Grappa = {length = 84, bytes = 0x0101...},  ← STATIC REPLAYABLE BLOB
           LibraryID = "E6ED8ADC1A1A1323",
           SyncHostName = "m3max",
           SyncedDataclasses = (),
           Version = "12.8"
       }
   }
6. ATHostConnectionReadMessage × 3 (device responds, sync approved)
7. ATHostConnectionSendMetadataSyncFinished({
       SyncTypes = { Keybag = 1; Media = 1 },
       DataclassAnchors = { Media = 8 }
   })
8. ATHostConnectionReadMessage × 3 (device acknowledges)
9. ATHostConnectionSendFileBegin(AssetID=349645419467270165)
   → ATCFMessageCreate("FileBegin", {
       AssetID, Dataclass = "Media",
       FileSize = 2473890, TotalSize = 2473890
   })
10. [ATCFMessageCreate("FileProgress") x14 — file data sent]
11. ATHostConnectionSendAssetCompleted(
        AssetID, Dataclass="Media",
        AssetPath="/iTunes_Control/Music/F02/ANNH.mp4"
    )
    → ATCFMessageCreate("FileComplete", {above})
```

## Breakpoint Hit Counts

| Symbol | Count |
|--------|-------|
| AMDeviceSecureStartService | 3 |
| AMDServiceConnectionSend | 22 |
| AMDServiceConnectionReceive | 26 |
| AMDServiceConnectionSendMessage | 1 |
| ATHostConnectionSendHostInfo | 1 |
| ATHostConnectionSendMetadataSyncFinished | 1 |
| ATHostConnectionSendFileBegin | 1 |
| ATHostConnectionSendAssetCompleted | 1 |
| ATCFMessageCreate | 19 |
| ATHostConnectionSendSyncRequest | 0 |
| ATHostConnectionSendAssetCompletedWithMetadata | 0 |

## Critical Protocol Details

### 1. Grappa blob in RequestingSync
The `RequestingSync` message contains an 84-byte Grappa blob at `Params.HostInfo.Grappa`. This blob is static and replayable — the same blob is hardcoded in the open-source `yinyajiang/go-tunes` project.

### 2. HostInfo is minimal
Required fields: `{LibraryID, SyncHostName, SyncedDataclasses=(), Version="12.8"}`. No HostID, no HostName.

### 3. RequestingSync format
Sent via `ATHostConnectionSendMessage` (not `SendSyncRequest`). The message has `Dataclasses=(Media, Keybag)` and `DataclassAnchors={Media=0}`.

### 4. Framework handles the conversation
The `ReadMessage` loop handles the internal ATC protocol (starting services, sending HostInfo over ATC, reading device Capabilities, etc.). Only high-level ATHostConnection APIs are needed.

### 5. Error codes observed
- **ErrorCode 12**: No Grappa at all
- **ErrorCode 4**: Invalid Grappa blob (dummy 0x11-filled 84 bytes)
- **ErrorCode 23**: Wrong message sequence (MetadataSyncFinished before RequestingSync)

## Comparison: Finder vs Third-Party Sync

| Aspect | Finder (AMPDevicesAgent) | Third-Party Sync Tools |
|--------|--------------------------|------------------------|
| Services | afc, atc, assertion_agent, installation_proxy, notification_proxy, springboardservices, commcenter | afc, atc, notification_proxy |
| ATHostConnection high-level API | SendHostInfo only | Full: SendHostInfo → SendMetadataSyncFinished → SendFileBegin → SendAssetCompleted |
| HostInfo Version | "13.6.3.2" | "12.8" |
| HostInfo extra fields | MacOSVersion, Type, Wakeable, SyncedAssetTypes | (none) |
| SendSyncRequest | Not observed | Not called |
| SendMetadataSyncFinished | Not observed | Called before FileBegin |
| Grappa | Handled internally by framework | 84-byte blob (replayable) |
| Total breakpoint hits | 539 | 72 |

## Wire Command Names vs API Names

A critical discovery: the ATHostConnection high-level API uses different names than what appears on the ATC wire. Using the wrong name causes silent failures.

| High-level API call | Wire command name |
|---------------------|-------------------|
| ATHostConnectionSendMetadataSyncFinished | `FinishedSyncingMetadata` |
| ATHostConnectionSendFileBegin | `FileBegin` |
| ATHostConnectionSendFileProgress | `FileProgress` |
| ATHostConnectionSendAssetCompleted | `FileComplete` |

## All Wire Values Are STRINGS

Everything that looks numeric on the wire is actually a string:
- DataclassAnchors: `{Media = "12"}` (not integer 12)
- AssetID: `"349645419467270165"` (not integer)
- Passing integers instead of strings causes device to silently ignore messages

## Wire-Level Message Examples

### FileBegin
```plist
{
    Command = FileBegin;
    Params = {
        AssetID = "349645419467270165";
        FileSize = 2473890;
        TotalSize = 2473890;
        Dataclass = "Media";
    };
}
```

### FileComplete
```plist
{
    Command = FileComplete;
    Params = {
        AssetID = "349645419467270165";
        AssetPath = "/iTunes_Control/Music/F23/ACER.mp4";
        Dataclass = "Media";
    };
}
```

### FinishedSyncingMetadata
```plist
{
    Command = FinishedSyncingMetadata;
    Params = {
        SyncTypes = { Keybag = 1; Media = 1 };
        DataclassAnchors = { Media = "8" };
    };
}
```

### FileProgress
```plist
{
    Command = FileProgress;
    Params = {
        AssetID = "349645419467270165";
        Progress = 0.142857;
        Dataclass = "Media";
    };
}
```

## Notification Proxy

A separate connection to `com.apple.mobile.notification_proxy` sends:
```
ObserveNotification("com.apple.atc.idlewake")
```
This keeps the device awake during file transfer.

## File Path Convention

Files placed at: `/iTunes_Control/Music/F{00-49}/{4-char-random}.{ext}`

Example: `/iTunes_Control/Music/F23/ACER.mp4`

The F00-F49 subdirectory and 4-character filename are randomly generated.

## AFC Verification

After sync, AFC directory diff showed:
- **New file**: `/iTunes_Control/Music/F02/QTOG.mp4`
- **NO new sync plists** anywhere under `/iTunes_Control/`
- **NO CIG files** written
- High-level API sync tools use the framework's internal mechanism, not manual sync plists

**Finder AFC diff**: Also shows NO sync plists written. Both Finder and third-party tools use ATC protocol messages internally, not AFC-based sync plists.

## AFC Trace Findings (2026-04-06) — THE BREAKTHROUGH

LLDB AFC-level tracing (breakpoints on AFCFileRefWrite and related) revealed the three missing pieces that make video entries appear correctly in TV app.

### Discovery 1: `is_movie: True` in insert_track plist

The binary plist for `insert_track` includes `is_movie: True` in the item dict. This is THE field that causes the device to set `media_type=2048`. Our previous exhaustive testing of `media_kind`, `media_type`, `mediaKind`, `mediaType` never tried the boolean `is_movie` field.

### Discovery 2: `/Airlock/Media/<AssetID>` staging path

The file is uploaded to **two locations**:
1. `/Airlock/Media/<AssetID>` — staging location where the device reads and processes the file to determine media type
2. `/iTunes_Control/Music/Fxx/name.mp4` — final playback location

The Airlock path is essential. Without it, the device creates DB entries with media_type=0 even when `is_movie: True` is set in the plist. The device uses the Airlock-staged file to validate and set the correct media type.

The `FileBegin` and `FileComplete` ATC messages reference the FINAL path (`/iTunes_Control/Music/Fxx/`), NOT the Airlock path.

### Discovery 3: `location.kind: "MPEG-4 video file"`

The `location` dict in the insert_track plist includes a `kind` field set to `"MPEG-4 video file"`. This maps to `location_kind_id=4` in the database.

### Complete Binary Plist Format

Decoded from AFC trace, the insert_track plist includes these sections:

```python
{
    'operation': 'insert_track',
    'pid': asset_id,
    'item': {
        'title': '...', 'sort_name': '...',
        'total_time_ms': ..., 'date_created': ..., 'date_modified': ...,
        'is_movie': True,           # ← media_type=2048
        'remember_bookmark': True,
        'album_artist': '...', 'album': '...', 'artist': '...',
        'sort_artist': '...', 'sort_album': '...', 'sort_album_artist': '...',
        'artwork_cache_id': 143,
    },
    'location': {
        'kind': 'MPEG-4 video file',  # ← location_kind_id=4
    },
    'video_info': {
        'has_alternate_audio': False, 'is_anamorphic': False,
        'has_subtitles': False, 'is_hd': False,
        'is_compressed': False, 'has_closed_captions': False,
        'is_self_contained': False, 'characteristics_valid': False,
    },
    'avformat_info': {
        'bit_rate': 160, 'audio_format': 502, 'channels': 2,
    },
    'item_stats': {
        'has_been_played': False, 'play_count_recent': 0,
        'play_count_user': 0, 'skip_count_user': 0, 'skip_count_recent': 0,
    },
}
```

### Result: Correct DB Values

With all three discoveries applied, synced entries now have:
- `media_type = 2048` (was 0)
- `media_kind = 2` (was 0)
- `location_kind_id = 4` (was 0)

Videos appear immediately in the TV app.

## DB Inspection Results (2026-04-03)

After a successful sync, inspecting MediaLibrary.sqlitedb reveals the correct values for video entries:

| Field | Correct Value | Finder Value | Our Sync Value (2026-04-06) |
|-------|---------------|--------------|-------------------------------|
| media_type | **2048** | 8192 | **2048** (CORRECT) |
| media_kind | **2** | 1024 | **2** (CORRECT) |
| location_kind_id | **4** | 4 | **4** (CORRECT) |
| in_my_library | 1 | 1 | 1 |

**Key insight**: The correct values are `media_type=2048`, `media_kind=2` — NOT the Finder values (8192/1024). Both make entries visible in TV app but with different classifications.

**RESOLVED (2026-04-06)**: Our sync now creates entries with correct values. The solution was three-fold: (1) `is_movie: True` in the item dict, (2) file staged to `/Airlock/Media/<AssetID>`, (3) `location.kind: "MPEG-4 video file"` in the location dict.

## File Comparison Result

Byte-level comparison of transferred files confirmed they are **identical** regardless of the tool used. File format and transcoding are NOT the issue — the remaining problem was purely in ATC protocol metadata (creating Video entries vs Music entries), now resolved.
