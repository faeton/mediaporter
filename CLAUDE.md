# mediaporter

macOS app for transferring video to iOS devices' TV app. Smart transcoding, ATC protocol sync.

**Status**: end-to-end sync working. The shipping target is the Swift MacApp (`MacApp/MediaPorter/`); new features land there. The Python reference under `python-reference/` is frozen — kept for protocol-level reference, not maintained in lockstep. Distribution: signed + notarized via Developer ID, hosted on porter.md.

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

- **No admin prompts ever.** The Swift app `dlopen`s Apple's own `MobileDevice.framework` (and `AirTrafficHost.framework`), which talks to the system `remoted`/`usbmuxd` daemons — no sudo, no helper install, no `SMAppService` auth dialog. The `sudo pymobiledevice3 remote start-tunnel` step only applies to the Python reference, which reimplements the tunnel in userspace and therefore needs root to create `utun`. The shipping app does not have this requirement.
- **Notarization-friendly framework loading.** Private frameworks are `dlopen`-ed at runtime, not linked. See `MacApp/MediaPorter/Sources/Sync/Frameworks.swift`. Linking would fail App Store review; `dlopen` passes notarization (notarization is a malware scan, not API review).

## Dev setup

Swift MacApp (primary):

```bash
cd MacApp
swift build                 # or open the SwiftPM workspace in Xcode
.build/debug/MediaPorter    # run the app
```

Requires `ffmpeg` for now (`brew install ffmpeg`) — release builds will bundle it inside the `.app`.

Python reference (frozen):

```bash
cd python-reference
pip install -e ".[dev]"
mediaporter devices
```

Python path needs `sudo pymobiledevice3 remote start-tunnel` once per boot (see above).

## Next steps

1. **Signing + notarization pipeline** — set up `MacApp/Signing/Info.plist`, `MediaPorter.entitlements` (hardened runtime, `disable-library-validation` for `libcig.dylib`), `MacApp/scripts/build-app.sh` to assemble the `.app` bundle around SwiftPM output, `release.sh` to sign nested binaries + outer app, submit to `notarytool` (keychain profile: `porter-notarization`), staple, build DMG. First target: arm64-only. x86_64 build added later (needs `libcig.dylib` recompiled from `yinyajiang/go-tunes` Go source for `darwin/amd64`, separate notarization).
2. **Interleave registration with uploads** — current pipeline does `upload×N → register×1`. medialibraryd commits the whole batch on terminal `SyncFinished`, ~30s/file, all visible as a long "finalizing" dead phase in the UI. Plan: open ATC session before uploads, receive `AssetManifest`, send each file's `FileBegin`/`FileComplete` the moment its AFC upload finishes. medialibraryd processes per-file instead of in a burst. Touch points: split `MacApp/MediaPorter/Sources/Sync/SyncEngine.swift::registerUploadedFiles` into open/per-file/close; rework `PipelineController.runPipelined` to start the session before the upload loop. Gating check: send one `FileComplete`, sleep 60 s, query `MediaLibrary.sqlitedb` — if the row isn't there, medialibraryd still buffers until terminal `SyncFinished` and the gain disappears.
2. **Orphan detection via AssetManifest** — current cleanup purges everything under `/iTunes_Control/Music/F*/`. Cross-reference `AssetManifest` paths to keep registered content and remove only true orphans.
3. **Recommendation rework** — banner today (`MacApp/App/Sources/DeviceColumnView.swift::recommendationCard`) makes a flat "1080p is the sweet spot for this device's display" claim that misleads users who AirPlay/HDMI to a 4K TV and ignores the storage axis. Plan:
   - Keep the on-device-display framing as the default copy.
   - Add a Settings toggle "I AirPlay/cast to a 4K TV" that flips `suggestedResolution` to `.original` (or `.uhd4k`) and rewrites the banner.
   - Make the recommendation storage-aware: when `deviceFreeBytes` >> incoming library size (e.g. >3×), bias toward keeping original; when tight, push the downscale harder. Banner should reflect which mode it's in.
   - Surface bitrate alongside resolution — the real "wastes space" lever. Add a bitrate hint to the banner copy and show source bitrate in the per-file details row (`FileRowView`) so the user can see *why* a 1080p file is huge.
4. **Parallel analyze** — `PipelineController.analyzeAll` (line 693) loops sequentially; probe is I/O-bound and TMDb is network-bound. `TaskGroup` with concurrency ~4 would cut "Analyzing…" wall time on big drops. Care: `resolveCluster` cache means N episodes of the same show shouldn't fire N parallel TMDb searches — either pre-resolve clusters serially then fan out per-file probes, or guard cluster resolution with an `actor`/awaiting `Task` per `clusterID`.
5. **Mid-sync disk poll** — `checkDiskSpace()` preflight (PipelineController.swift:1066) runs once; nothing watches device free space during the AFC upload loop. If iOS background traffic (Photos, iCloud) eats space mid-sync we crash with a cryptic AFC error. Re-query `queryDeviceDiskSpace` every Nth chunk (or once per file) and abort cleanly with a "device filled up" status before AFC fails.
6. **Zombie ffmpeg on hard kill** — `ActiveProcesses.cancelAll()` (Transcoder.swift:104) only fires on graceful Swift exit. SIGKILL / crash leaves orphan ffmpeg children writing to temp. On app launch, sweep for `ffmpeg` processes whose parent PID is gone and whose CWD is our temp dir; terminate.

## Where things live

- `MacApp/MediaPorter/` — Swift core (shipping target). Modules: `Sync/` (ATC + AFC + framework loading), `Pipeline/`, `Transcode/`, `Analysis/`, `Metadata/`, `Tagger/`
- `MacApp/App/Sources/` — SwiftUI app target
- `MacApp/MediaPorter/Resources/libcig.dylib` — arm64 CIG engine bundled into the Swift app
- `MacApp/MediaPorter/Resources/grappa.bin` — replayable 84-byte Grappa blob bundled into the Swift app
- `python-reference/` — frozen Python implementation (`src/mediaporter/`, `tests/`, `scripts/`, `pyproject.toml`). Kept for protocol reference, not maintained in lockstep
- `scripts/cig/` — CIG source (`cig.cpp`, `cig.h`, `cig_wrapper.cpp`) + compiled `libcig.dylib` (arm64). Shared by both implementations
- `research/docs/` — protocol analysis, trace findings, dated history (`HISTORY.md`)
- `research/docs/HISTORY.md` — chronological findings log
- `site/` — porter.md (Astro)
- `brand/` — brand assets
