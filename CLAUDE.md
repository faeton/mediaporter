# mediaporter

CLI + macOS app for transferring video to iOS devices' TV app. Smart transcoding, ATC protocol sync.

**Status**: end-to-end sync working. Python (`src/mediaporter/`) is the reference; Swift MacApp (`MacApp/MediaPorter/`) is at parity. Land fixes in Python first, port to Swift after validation.

## Critical rules

These are non-obvious and breaking any of them silently fails. Don't relearn from scratch — check `research/docs/HISTORY.md` for the trace-level evidence.

1. **Do not modify `MediaLibrary.sqlitedb` directly.** medialibraryd reverts within seconds. The only working path is the ATC protocol (`com.apple.atc`).
2. **Grappa is replayable.** The 84-byte blob in `traces/grappa.bin` (same as `yinyajiang/go-tunes` `deviceGrapa`) works across sessions. ErrorCode 12 = no Grappa, 4 = invalid, 23 = wrong sequence.
3. **Wire command names ≠ API names.** `MetadataSyncFinished` on the wire is `FinishedSyncingMetadata`. Anchor and AssetID are STRINGS on the wire, never ints.
4. **Sync plist must be binary plist**, not XML. Written to `/iTunes_Control/Sync/Media/Sync_NNNN.plist` + `.cig`.
5. **TV-app metadata fields**: `is_movie: True` (or `is_tv_show: True`) + `location.kind: "MPEG-4 video file"` in `insert_track` set `media_type=2048, media_kind=2, location_kind_id=4`. Airlock staging is NOT required.
6. **TV episodes need full set**: `tv_show_name`, `sort_tv_show_name`, `season_number`, `episode_number`, `episode_sort_id`, plus `artist`/`album`/`album_artist` (+ sorts). Missing `episode_sort_id` shows as "0." prefix in TV app.
7. **Order matters**: `MetadataSyncFinished` must be sent BEFORE file upload, not after. Sending after a long upload causes ATC session timeout.
8. **Stale pending assets must be cleared**: parse `AssetManifest`, send `FileError` (ErrorCode 0) for any AssetID that isn't ours, or device waits forever for them and never emits `SyncFinished`.
9. **Ping/Pong keepalive** is mandatory during long operations — respond to every `Ping` with a `Pong` or the session drops.
10. **AC3 audio is silently dropped from the iPad TV app's audio switcher** (not a uniformity rule). Transcode AC3 → AAC, copy AAC/EAC3. Set `-disposition:a:0 default` + `-disposition:a:N 0` for N>0 (multiple defaults break the switcher entirely). See `research/docs/AUDIO_SWITCHER_RULE.md`.
11. **ffmpeg .m4v output needs `-f mp4`** (the .m4v extension picks the ipod muxer which can't do HEVC). HEVC copy still needs `-tag:v hvc1`.
12. **ffmpeg subprocess gotchas**: drain stderr in a thread (full pipe deadlocks ffmpeg); set stdin to `/dev/null` (otherwise SIGTTIN freezes); register Popen handles globally so Ctrl+C / cancel can kill them.
13. **Artwork via Airlock**: poster JPEG → `/Airlock/Media/Artwork/<AssetID>` + `artwork_cache_id` in plist item dict.

## Sync flow (reference)

```
ATC handshake (replayed Grappa)            → ReadyForSync
AFC: write binary plist + CIG              → /iTunes_Control/Sync/Media/Sync_NNNN.plist[.cig]
ATC: SendPowerAssertion(true)
ATC: FinishedSyncingMetadata (STRING anchor)
Device: AssetManifest                       (respond to Ping with Pong)
AFC: upload file                            → /iTunes_Control/Music/Fxx/name.mp4
ATC: FileBegin + FileComplete (final path)
ATC: FileError for stale pending assets
Device: SyncFinished                        → entry visible in TV app
```

Wire detail and message dictionaries: `research/docs/ATC_SYNC_FLOW.md`, `research/docs/IMPLEMENTATION_GUIDE.md`.

## Design priorities

- **Avoid sudo/root.** Tunnel currently needs `sudo pymobiledevice3 remote start-tunnel` once. Prefer any path that removes this (e.g. `lockdown start-tunnel` on iOS 17.4+, `remoted` reuse).

## Dev setup

```bash
source .venv/bin/activate
pip install -e ".[dev]"        # Python 3.11+, brew install ffmpeg
mediaporter devices             # verify tunnel + connection
```

Swift MacApp: `cd MacApp && swift build` (or open the SwiftPM workspace).

## Next steps

1. **Interleave registration with uploads** — current pipeline does `upload×N → register×1`. medialibraryd commits the whole batch on terminal `SyncFinished`, ~30s/file, all visible as a long "finalizing" dead phase in the UI. Plan: open ATC session before uploads, receive `AssetManifest`, send each file's `FileBegin`/`FileComplete` the moment its AFC upload finishes. medialibraryd processes per-file instead of in a burst. Touch points: split `MacApp/MediaPorter/Sources/Sync/SyncEngine.swift::registerUploadedFiles` into open/per-file/close; rework `PipelineController.runPipelined` to start the session before the upload loop. Port to Python after Swift validation.
2. **Orphan detection via AssetManifest** — current cleanup purges everything under `/iTunes_Control/Music/F*/`. Cross-reference `AssetManifest` paths to keep registered content and remove only true orphans.

## Where things live

- `src/mediaporter/` — Python reference (`sync/atc.py`, `sync/__init__.py`, `pipeline.py`, `transcode.py`, `metadata.py`, `probe.py`)
- `MacApp/MediaPorter/` — Swift port (Sources mirror Python module names)
- `scripts/atc_nodeps_sync.py` — zero-dep proof of working sync (ctypes + Apple frameworks)
- `scripts/cig/libcig.dylib` — compiled CIG engine from go-tunes (arm64)
- `traces/grappa.bin` — replayable 84-byte Grappa blob
- `research/docs/` — protocol analysis, trace findings, dated history (`HISTORY.md`)
- `research/docs/HISTORY.md` — chronological findings log (formerly inline here)
