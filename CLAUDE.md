# mediaporter

Open-source CLI tool for transferring video to iOS devices with smart transcoding and native TV app integration.

## Project State

- **Transcoding pipeline**: Working (probe → compat → transcode → tag → transfer via AFC)
- **TV app integration**: WORKING — Full end-to-end video sync to iPad TV app from Python. Videos appear with correct media_type=2048, media_kind=2, location_kind_id=4. Confirmed visible in TV app.
- **Test videos**: Generated in `test_fixtures/` (10 files + TV series set)
- **Final implementation**: `scripts/atc_nodeps_sync.py` — zero-dependency version (pure ctypes + Apple frameworks + libcig.dylib, no pymobiledevice3)
- **Earlier implementation**: `scripts/atc_proper_sync.py` — also works, but requires pymobiledevice3

## Key Documentation

Research and protocol analysis live in `research/docs/`:
- `research/docs/ARCHITECTURE.md` — Module overview, data flow, technical decisions
- `research/docs/ATC_PROTOCOL.md` — ATC protocol reverse engineering (wire format, message flow, Grappa auth)
- `research/docs/ATC_SYNC_FLOW.md` — **Complete reverse-engineered ATC+AFC sync flow, Grappa, CIG, sync plists**
- `research/docs/IMPLEMENTATION_GUIDE.md` — **Full implementation specification with code examples**
- `research/docs/TRACE_ANALYSIS.md` — **Protocol trace analysis (4 sessions), correct ATC flow**
- `research/docs/IPAINSTALL_ANALYSIS.md` — **IpaInstall Grappa generation analysis, fake struct technique**
- `research/docs/MEDIA_LIBRARY_DB.md` — MediaLibrary.sqlitedb schema analysis

**Always update these docs when making new discoveries or changing approach.**

## Development Setup

```bash
cd /Users/faeton/Sites/mediaporter
source .venv/bin/activate
pip install -e ".[dev]"
```

Requires: `brew install ffmpeg`, Python 3.11+

## Device Testing

iOS 17+ requires tunnel service (needs sudo once):
```bash
sudo .venv/bin/pymobiledevice3 remote start-tunnel
# Or as daemon: sudo .venv/bin/pymobiledevice3 remote tunneld -d
```

Then: `mediaporter devices` to verify connection.

**SIP debug restrictions currently DISABLED** (`csrutil enable --without debug`) for LLDB tracing.

## Critical Learnings

1. **Direct MediaLibrary.sqlitedb modification DOES NOT WORK** — medialibraryd daemon reverts changes within seconds. Do not attempt this approach.
2. **The correct path is the ATC protocol** (`com.apple.atc` lockdown service) — this is what iTunes and Finder use for media sync.
3. **ATC uses legacy plist messages** (4-byte LE length + binary plist) on this device/iOS version.
4. **Grappa authentication IS required** — but the 84-byte blob can be replayed (static, same blob works across sessions). go-tunes hardcodes the same blob. ErrorCode 12 = no Grappa, ErrorCode 4 = invalid Grappa.
5. **ffmpeg .m4v output needs `-f mp4`** — the .m4v extension triggers the ipod muxer which doesn't support HEVC.
6. **HEVC copy mode still needs `-tag:v hvc1`** — Apple devices require this tag even when not re-encoding.
7. **pymobiledevice3 v9.x is fully async** — use a persistent background event loop thread for sync wrappers.
8. **media_type/media_kind ARE settable via sync plists** — requires `is_movie: True` in item dict and `location.kind: "MPEG-4 video file"`. These alone set media_type=2048 correctly.
9. **Correct DB values for TV app**: `media_type=2048`, `media_kind=2`, `location_kind_id=4` (NOT Finder's 8192/1024 which creates "Home Video" entries). These make entries appear correctly in TV app.
10. ~~**`/Airlock/Media/<AssetID>` staging path is essential**~~ — **CORRECTED 2026-04-06**: Airlock staging is NOT needed. `is_movie: True` + `location.kind` in the plist alone sets media_type=2048. Single upload to `/iTunes_Control/Music/Fxx/` is sufficient. Confirmed working without Airlock.
11. **Binary plist format required** — binary plist (not XML) for sync plists. Matches what the device expects.
12. **Ping/Pong keepalive required for large files** — device sends `Ping` during long operations, must respond with `Pong` or session drops. Without this, syncs of large files (>100MB) fail with session reset.
13. **MetadataSyncFinished must be sent BEFORE file upload** — for large files, sending it after upload causes ATC session timeout. Correct order: plist+CIG → MetadataSyncFinished → AssetManifest → file upload → FileBegin/FileComplete.
14. **Stale pending assets must be cleared from AssetManifest** — device accumulates pending download assets from previous failed syncs. Parse AssetManifest, send `FileError` for any AssetID that isn't ours, or device waits forever (no SyncFinished).
15. **iPad requires same audio codec for track switcher** — mixed codecs (e.g., AAC + EAC3) in the same file = iPad won't show audio language selector. All audio tracks must be normalized to the same codec (AAC) for the switcher to appear. Confirmed 2026-04-06.
16. **Artwork via Airlock** — poster JPEG uploaded to `/Airlock/Media/Artwork/<AssetID>` + `artwork_cache_id` in plist item dict → TV app shows poster. AssetParts jumps from 1 to 3 when artwork is present.

## Design Priorities

- **No sudo/root if at all possible.** If any discovery allows avoiding the tunnel sudo requirement, prefer that path. Explore: macOS `remoted` daemon reuse, `lockdown start-tunnel` (iOS 17.4+), or userland alternatives.

## Confirmed Findings (2026-04-01)

- Finder sync creates TV app entries with `media_type=8192`, `media_kind=1024` ("Home Video")
- The `integrity` field (57 bytes) is a Grappa-signed hash — NOT a simple file hash
- socat usbmux capture does NOT work on iOS 17+ (Finder uses RemoteXPC tunnels)
- The ATC conversation gets to `SyncAllowed` but `BeginSync` fails with ErrorCode 12 (Grappa auth missing)
- All previously synced movies were lost during DB experimentation — DO NOT push modified DBs
- `cfgutil` has NO media sync commands (dead end)
- `ATMD5SignatureProvider` exists as legacy fallback — DOES NOT work on iOS 26 (still ErrorCode 12)
- AMPDevicesAgent runs as USER (not root) and handles all ATC/Grappa internally

## Confirmed Findings (2026-04-02) — LLDB Trace Capture (BREAKTHROUGH)

- **Grappa is used by all sync tools** — 84-byte blob embedded in `RequestingSync.Params.HostInfo.Grappa`, generated by AirTrafficHost.framework internally
- **Correct ATC flow**: `SendHostInfo → ReadMessage(×4) → SendMessage(RequestingSync with Grappa) → ReadMessage(×3) → SendMetadataSyncFinished → ReadMessage(×3) → SendFileBegin → [FileProgress] → SendAssetCompleted`
- **Our process gets Grappa=0** — `ATHostConnectionGetGrappaSessionId` stays 0 throughout, framework never initializes Grappa for unsigned processes
- **HostInfo must be minimal**: `{LibraryID, SyncHostName, Version="12.8"}` — NO HostID, NO HostName
- **RequestingSync includes**: `{DataclassAnchors={Media=0}, Dataclasses=(Media, Keybag), HostInfo={Grappa=<84 bytes>, LibraryID, SyncHostName, SyncedDataclasses=(), Version="12.8"}}`
- **ErrorCode 12** = no Grappa at all; **ErrorCode 4** = invalid Grappa blob; **ErrorCode 23** = wrong message sequence
- **Only 3 services needed**: `com.apple.afc`, `com.apple.atc`, `com.apple.mobile.notification_proxy`
- **Finder uses low-level Send/Receive directly** (322 Send, 133 Receive) — does NOT use ATHostConnectionSendSyncRequest etc.
- **Third-party tools use high-level ATHostConnection API** — framework generates Grappa blob internally
- **Full trace logs**: `traces/` directory (gitignored), analysis: `docs/TRACE_ANALYSIS.md`

## Confirmed Findings (2026-04-02) — AirTrafficHost PoC

- **MobileDevice.framework works WITHOUT sudo/tunnel** — `AMDCreateDeviceList()` + `AMDeviceConnect()` + `AMDeviceSecureStartService("com.apple.atc")` all succeed from an unsigned Python process via usbmuxd
- **AirTrafficHost.framework loads and connects** — `ATHostConnectionCreateWithLibrary()` returns valid handle, receives InstalledAssets/AssetMetrics/SyncAllowed
- **Both ATC and ATC2 services start** via `AMDeviceSecureStartService` with SSL contexts
- **Grappa fails because CoreFP needs `com.apple.private.fpsd.client` entitlement** — the FairPlay daemon (`fairplayd`) rejects requests from unsigned processes
- **AMPDevicesAgent XPC confirmed BLOCKED** — `NSCocoaErrorDomain Code=4097` when calling `fetchDeviceIdentifiersWithReply:` (needs `com.apple.amp.devices.client` entitlement)
- **AMPDevicesClient class works via PyObjC** — `connect()` succeeds but XPC calls are rejected
- **ATC2 service connects but sends no initial message** — may use request-based protocol

## Confirmed Findings (2026-04-02) — Grappa Replay & CIG

- **Grappa replay WORKS** — replaying the 84-byte blob (from `yinyajiang/go-tunes`) in our `RequestingSync` gets `ReadyForSync` (not `SyncFailed`)
- **Same blob found in `yinyajiang/go-tunes`** (GitHub) — hardcoded as `deviceGrapa` constant, used for ringtone sync
- **CIG engine compiled** — `scripts/cig/libcig.dylib` (from go-tunes `cig.cpp`, 10K lines), produces 21-byte signatures
- **CIG input**: device Grappa (83 bytes from `ReadyForSync`) + plist bytes → 21-byte output
- **Device Grappa extraction works** — from `ReadyForSync.Params.DeviceInfo.Grappa` via CFDictionaryGetValue
- **Sync anchor is a CFString** — `ReadyForSync.Params.DataclassAnchors.Media` returns string "12" not number

## Confirmed Findings (2026-04-02) — Sync Plist Experiments

- **Two sync approaches exist**: (A) high-level ATHostConnection API (framework handles everything), (B) go-tunes writes sync plists manually via AFC
- **Finder does NOT write sync plists** — AFC diff before/after Finder sync shows NO sync plists written. Uses ATC protocol messages internally.
- **Our high-level API calls fail** — `SendFileBegin` returns garbage (framework state not initialized, Grappa=0)
- **go-tunes sync plist approach partially works**: device consumes `/iTunes_Control/Sync/Media/Sync_XXXX.plist` (with CIG), but does NOT consume dataclass plist from `/iTunes_Control/Media/Sync/`
- **Device processes `update_db_info` from consumed plist** — `Progress` message observed (0.4% progress)
- **`insert_track` not processed** — device may reject our video insert_track format, or the dataclass plist path is wrong
- **Our sync plists accidentally deleted existing movies** — `Movie._Count` dropped from 2 to 0 after `update_db_info` ran without proper insert operations
- **After `SyncFinished`, manual `FileBegin`/`FileComplete` messages are accepted** (return 1) but have no visible effect — session already closed

## Confirmed Findings (2026-04-02) — Wire-Level Protocol & AssetManifest Breakthrough

- **File format is NOT the issue** — byte-level comparison confirmed transferred files are identical regardless of tool
- **Wire command name mismatch** — the ATC wire command for "MetadataSyncFinished" is actually `FinishedSyncingMetadata`. Using wrong name caused device to ignore the message silently.
- **All ATC values are STRINGS on the wire** — anchors, AssetIDs are strings (e.g., "12", "349645419467270165"), not integers
- **AssetManifest breakthrough achieved** by combining three fixes:
  1. Using go-tunes video plist format: `insert_track` with `video_info` dict, NO `update_db_info`, NO `track_info`
  2. Calling `ATHostConnectionSendPowerAssertion(conn, true)` before `FinishedSyncingMetadata`
  3. Passing anchor as STRING not int in `FinishedSyncingMetadata`
- **Notification proxy required** — separate connection for `ObserveNotification("com.apple.atc.idlewake")`
- **Wire-level FileBegin params**: `{AssetID: string, FileSize: int, TotalSize: int, Dataclass: "Media"}`
- **Wire-level FileComplete params**: `{AssetID: string, AssetPath: string, Dataclass: "Media"}`
- **FileProgress messages** report progress as floats; actual file data goes via internal AFC channel
- **File path convention**: `/iTunes_Control/Music/F23/ACER.mp4` (F00-F49 subdirs, 4-char random name)

## Confirmed Findings (2026-04-02) — go-tunes Video End-to-End

- **go-tunes approach works end-to-end** — video appeared in TV app
- **But creates entry as Music (AssetType=Music)**, not Video
- **Attempted DB patch** with Finder values: `media_type=8192`, `media_kind=1024`, `location_kind_id=4` (these were later found to be WRONG — correct values are 2048/2/4)
- **medialibraryd reverts DB changes** — same problem as direct DB modification
- **Conclusion**: go-tunes plist approach gets file on device and registered, but metadata is wrong for video. RESOLVED in 2026-04-06 findings via `is_movie: True` + Airlock staging.

## Confirmed Findings (2026-04-02) — Dead Ends

- **Grappa struct patch (offset 0x5C)** — `ATHostConnectionGetGrappaSessionId` reads from offset 92 in the struct. Patching to non-zero triggers CoreFP/fairplayd pipeline but fails because "1" is not a real session ID.
- **Code-signed .app is a dead end** — even with ad-hoc entitlement `com.apple.private.fpsd.client`, macOS kills the process. `DYLD_INSERT_LIBRARIES` blocked by library validation. Would need a real Apple Developer cert with private entitlements.
- **Raw ATC MetadataSyncFinished was ignored** — because we sent command name "MetadataSyncFinished" instead of the correct wire name "FinishedSyncingMetadata"

## Confirmed Findings (2026-04-03) — Complete End-to-End Sync Protocol

- **Full ATC sync flow now works** — handshake with replayed Grappa, sync plist with CIG, SendPowerAssertion + MetadataSyncFinished (STRING anchor), AssetManifest received, FileComplete + FileError for stale assets, SyncFinished
- **DB entries ARE created** with correct title, sort_name, total_time_ms, file_size, location (filename.mp4), in_my_library=1
- ~~**BUT media_type=0, media_kind=0, location_kind_id=0** — makes entries invisible in TV app~~ — SOLVED, see 2026-04-06 findings

## Confirmed Findings (2026-04-03) — Correct DB Values (CORRECTION)

- **Correct values**: `media_type=2048`, `media_kind=2`, `location_kind_id=4` (from deep trace + DB inspection)
- **Previously assumed Finder values were WRONG**: `media_type=8192`, `media_kind=1024` were Finder's "Home Video" classification
- **media_type=2048, media_kind=2** = the values that make video entries appear correctly in TV app

## Confirmed Findings (2026-04-03) — media_type NOT Settable via Sync Plists (CORRECTED 2026-04-06)

- **Previous conclusion was WRONG** — media_type IS settable via sync plists, but requires specific fields we hadn't tried
- ~~media_type/media_kind are ONLY set by the framework's internal file transfer mechanism~~ — CORRECTED below

## Confirmed Findings (2026-04-03) — Grappa Struct Patch Deep Dive

- **ATHostConnectionGetGrappaSessionId** reads from offset 0x5C (arm64)
- **ATHostConnectionSendFileBegin** reads flag at offset 0x4C, then sends via `[conn+0x40]` (ATHostMessageLinkSendMessage)
- **ATHostConnectionSendMessage** uses the SAME path (`[conn+0x40]` → ATHostMessageLinkSendMessage)
- **Patching 0x5C to 1** triggers CoreFP/fairplayd pipeline but fails (not a real session)
- **With patched Grappa**: SendFileBegin returns non-null, but creates entry with empty location
- **Ad-hoc signing with `com.apple.private.fpsd.client`** entitlement → OS kills the process
- **DYLD_INSERT_LIBRARIES** blocked by library validation even with SIP debug disabled

## Confirmed Findings (2026-04-06) — COMPLETE WORKING SOLUTION (BREAKTHROUGH)

- **End-to-end video sync to iPad TV app from Python is WORKING**
- **Three breakthroughs from LLDB AFC tracing**:
  1. **`is_movie: True`** in the item dict of the insert_track plist
  2. ~~**`/Airlock/Media/<AssetID>`** staging path~~ — originally thought essential, but see 2026-04-06 correction below
  3. **`location.kind: "MPEG-4 video file"`** — file type descriptor in the location dict
- ~~**File must be uploaded to TWO paths**~~ — **CORRECTED**: Single upload to `/iTunes_Control/Music/Fxx/name.mp4` is sufficient. Airlock staging is NOT needed when `is_movie: True` + `location.kind` are set in the plist.
- **FileBegin/FileComplete use the FINAL path** (not the Airlock path)
- **AssetManifest now returns AssetType=Movie** (previously returned Music)
- **DB entries created with correct values**: media_type=2048, media_kind=2, location_kind_id=4
- **Binary plist format** (not XML) required for sync plists
- **Previous assumption "media_type not settable via sync plists" was WRONG** — it IS settable with the correct fields (`is_movie`, `location.kind`). Airlock staging is NOT required for this.

### Full insert_track Plist Format (decoded from binary plist via AFC trace)

```python
{
    'operation': 'insert_track',
    'pid': asset_id,
    'item': {
        'title': 'Title',
        'sort_name': 'title',
        'total_time_ms': 125,
        'date_created': now,
        'date_modified': now,
        'is_movie': True,           # KEY FIELD for media_type=2048
        'remember_bookmark': True,
        'album_artist': '...',
        'album': '...',
        'artist': '...',
        'sort_artist': '...',
        'sort_album': '...',
        'sort_album_artist': '...',
        'artwork_cache_id': 143,
    },
    'location': {
        'kind': 'MPEG-4 video file',  # KEY FIELD for location_kind_id
    },
    'video_info': {
        'has_alternate_audio': False,
        'is_anamorphic': False,
        'has_subtitles': False,
        'is_hd': False,
        'is_compressed': False,
        'has_closed_captions': False,
        'is_self_contained': False,
        'characteristics_valid': False,
    },
    'avformat_info': {
        'bit_rate': 160,
        'audio_format': 502,
        'channels': 2,
    },
    'item_stats': {
        'has_been_played': False,
        'play_count_recent': 0,
        'play_count_user': 0,
        'skip_count_user': 0,
        'skip_count_recent': 0,
    },
}
```

### Complete Working Sync Flow (Updated 2026-04-06)

```
1. ATC handshake with replayed 84-byte Grappa blob → ReadyForSync
2. AFC: write binary plist + CIG to /iTunes_Control/Sync/Media/
3. ATC: SendPowerAssertion(conn, true)
4. ATC: FinishedSyncingMetadata with STRING anchor
5. Device: AssetManifest (AssetType=Movie)
6. AFC: upload file to /iTunes_Control/Music/Fxx/name.mp4 (single upload, no Airlock needed)
7. ATC: FileBegin + FileComplete with final path
8. ATC: FileError for stale pending assets (parsed from AssetManifest)
9. ATC: Ping/Pong keepalive during processing
10. Device: SyncFinished → entry appears in TV app with media_type=2048
```

## Confirmed Findings (2026-04-03) — Wire Trace Details

- Wire command for MetadataSyncFinished = "FinishedSyncingMetadata"
- All DataclassAnchors values are STRINGS on wire
- AssetID is STRING in FileBegin/FileComplete
- FileProgress contains only progress floats (AssetProgress, OverallProgress), NOT file data
- File data sent via internal AFC (framework manages this)
- Notification proxy: ObserveNotification for `com.apple.atc.idlewake` (separate connection)
- File path example: `/iTunes_Control/Music/F23/ACER.mp4`

## Confirmed Findings (2026-04-03) — Finder AFC Diff Results

- **Finder does not write sync plists for video** — uses framework's internal mechanism
- Finder rearranges MP4 atoms (faststart optimization) — not required for sync to work
- Files are byte-identical between different sync tools and our source

## Grappa Blob — Replayable, Known in Open Source

- **84-byte static blob** — identical to hardcoded blob in `yinyajiang/go-tunes` (GitHub)
- **Format**: `0x0101` (version) + `0x11`×16 (CIG engine init state) + 66 bytes real crypto
- **Generated by** `AirFairSyncGrappaCreate` inside AirTrafficHost.framework — requires CoreFP/fairplayd
- **Replayable** — same blob works across sessions. go-tunes uses a static blob for ringtone sync.
- **CIG (signature) engine** from go-tunes `cig.cpp` (10K lines) — signs individual plist messages after Grappa handshake
- **Kerrbty/IpaInstall** (GitHub) — calls real Apple DLL functions at hardcoded offsets via fake ATHostConnection struct

## ATC+AFC Sync Flow (Updated 2026-04-06) — COMPLETE WORKING SOLUTION

### Working Sync Flow (Updated 2026-04-06 — single upload, no Airlock needed)

```
1. ATC handshake with replayed 84-byte Grappa blob → ReadyForSync
2. AFC: write binary plist (with is_movie + location.kind) + CIG
   to /iTunes_Control/Sync/Media/Sync_XXXXXXXX.plist + .cig
3. ATC: SendPowerAssertion(conn, true)
4. ATC: FinishedSyncingMetadata (anchor as STRING!)
5. Device: AssetManifest (AssetType=Movie) — respond to Ping with Pong
6. AFC: upload file to /iTunes_Control/Music/Fxx/name.mp4 (single upload)
7. ATC: FileBegin { AssetID: str, FileSize: int, TotalSize: int, Dataclass: "Media" }
8. ATC: FileComplete { AssetID: str, AssetPath: "/iTunes_Control/Music/Fxx/name.mp4", Dataclass: "Media" }
9. ATC: FileError for any stale pending assets from AssetManifest
10. ATC: respond to Ping with Pong while waiting
11. Device: SyncFinished → entry in TV app with media_type=2048, media_kind=2
```

**Status**: FULLY WORKING. Videos appear in TV app with correct metadata. Tested with 5GB+ files.

**Critical elements for correct video sync:**
1. `ATHostConnectionSendPowerAssertion(conn, true)` before MetadataSyncFinished
2. Anchor passed as STRING (not int) in MetadataSyncFinished
3. `is_movie: True` in the item dict of insert_track plist
4. `location.kind: "MPEG-4 video file"` in the location dict
5. MetadataSyncFinished sent BEFORE file upload (avoids ATC session timeout for large files)
6. Ping/Pong keepalive during long operations
7. FileError for stale pending assets parsed from AssetManifest

**Airlock staging is NOT needed** — `is_movie: True` + `location.kind` alone set media_type=2048. Previously thought essential (finding #10 from 2026-04-06), but confirmed 2026-04-06 that single upload to final path works correctly.

### Correct Wire Command Names (from deep trace)

| High-level API call | Actual wire command name |
|---------------------|------------------------|
| SendMetadataSyncFinished | `FinishedSyncingMetadata` |
| SendFileBegin | `FileBegin` |
| SendAssetCompleted | `FileComplete` |
| SendFileProgress | `FileProgress` |

## Confirmed Findings (2026-04-06) — TV Series Support WORKING

- **`is_tv_show: True`** in the item dict creates `AssetType = TVEpisode` (vs `is_movie: True` → `AssetType = Movie`)
- **TV series fields confirmed working**: `tv_show_name`, `sort_tv_show_name`, `season_number`, `episode_number`, `episode_sort_id`
- **Episode appears correctly in TV app** under "TV Shows", grouped by show name, with S01E01 metadata
- **Album/artist convention**: `artist` = show name, `album` = "Show Name, Season N" (matches iTunes)
- **`is_hd: True`** in `video_info` for 1080p content
- **Test script**: `scripts/atc_tv_series_test.py` — confirmed working with Breaking Bad S01E01

## Next Steps (Updated 2026-04-06)

CLI v0.2.0 is WORKING with full pipeline: probe → transcode → tag → sync via ATC. Remaining:

1. ~~**Integrate into CLI pipeline**~~ — DONE (v0.2.0)
2. **Multi-episode batch sync** — Test syncing multiple episodes in a single ATC session
3. ~~**Handle stale pending assets**~~ — DONE (parse AssetManifest, send FileError for stale IDs)
4. **Clean up orphan files on device** — Dozens of test files accumulated in `/iTunes_Control/Music/F*/`
5. ~~**Progress reporting**~~ — DONE (Rich progress bars for transcode + sync)
6. **Parallel transcode** — ThreadPoolExecutor with `-j N` (implemented, needs real-world testing)

## Resolved Questions (Updated 2026-04-06)

- **How to set media_type=2048?** — ANSWERED: `is_movie: True` + `location.kind: "MPEG-4 video file"` in the insert_track plist. Airlock staging NOT required.
- **Is Airlock staging needed?** — ANSWERED: NO. `is_movie: True` in plist alone sets media_type=2048. Single upload to `/iTunes_Control/Music/Fxx/` is sufficient. Tested and confirmed.
- **Are media_type/media_kind settable via sync plists?** — ANSWERED: YES, with `is_movie` + `location.kind`. No Airlock needed.
- **Why do large file syncs fail?** — ANSWERED: Two causes: (1) ATC session timeout if MetadataSyncFinished sent after long upload — fix: send it before upload. (2) Ping/Pong keepalive — device sends Ping, must respond with Pong or session drops.
- **Why does device never send SyncFinished?** — ANSWERED: Stale pending assets. Device waits for ALL assets in AssetManifest. Must send FileError for stale ones.

## Research Docs

All research documentation is in `research/docs/`. See `research/README.md` for a full index.

Key docs:
- `research/docs/ATC_PROTOCOL.md` — Wire format, message flow, observed commands
- `research/docs/ATC_SYNC_FLOW.md` — Complete reverse-engineered sync flow
- `research/docs/IMPLEMENTATION_GUIDE.md` — Full implementation specification
- `research/docs/TRACE_ANALYSIS.md` — Protocol trace analysis
- `research/docs/GRAPPA.md` — Grappa auth protocol analysis

## Scripts & Tools

- `scripts/lldb_atc_trace.py` — LLDB Python helper for ATC call tracing (breakpoints on 15+ symbols)
- `scripts/trace_atc_sync.sh` — Wrapper to attach LLDB to Finder/AMPDevicesAgent
- `scripts/cig/libcig.dylib` — Compiled CIG engine from go-tunes (arm64, modified SHA-1)
- `scripts/cig/cig.cpp` — Source (10K+ lines, from publicly available go-tunes project)
- `scripts/atc_nodeps_sync.py` — **FINAL IMPLEMENTATION**: zero-dependency video sync (pure ctypes + Apple frameworks + libcig.dylib). Confirmed working.
- `scripts/atc_proper_sync.py` — **WORKING**: video sync using pymobiledevice3 for AFC. Also confirmed working but has external dependency.
- `scripts/atc_tv_series_test.py` — TV series sync test (confirmed working)
- `research/scripts/` — Experimental PoCs from protocol research (historical)
- `traces/` — LLDB trace logs (gitignored)
- `traces/grappa.bin` — 84-byte Grappa blob (replayable, same as go-tunes)
