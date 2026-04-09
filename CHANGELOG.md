# Changelog

## 0.3.1 — 2026-04-10

Pipelined transcode+upload, smarter audio normalization, safer ffmpeg handling, and disk-space-aware runs with a full summary at the end.

### New

- **Pipelined transcode + upload** — each file streams to the device via AFC as soon as its transcode finishes, instead of waiting for the entire batch. A dedicated uploader thread drains a queue fed by the transcode workers; the short ATC registration session still runs once at the end. Two progress displays (transcode above, upload below) render simultaneously via `rich.Live` + `Group`.
- **Smart audio normalization** — mixed-codec files now normalize to the best codec already present in the file (EAC3 > AC3 > AAC) instead of always AAC. Tracks that already match the target use `-c:a copy`, so an `ac3 + eac3` file re-encodes only the AC3 track and preserves the EAC3 surround bit-perfect. New helpers: `mediaporter.audio.pick_normalization_codec()` and `target_bitrate_for()`.
- **Disk space preflight** — before launching any ffmpeg, checks Mac temp (`shutil.disk_usage`) and device free space (lockdown `com.apple.disk_usage` domain) against an upper bound of `sum(source_sizes) * 1.1`. Fails fast with a clear error instead of filling temp or the device mid-transcode.
- **End-of-run summary** — total time, transcode wall clock (parallel), upload wall clock, bytes transferred, peak per-file speed, average sustained speed, Mac + device free space before/after with deltas.
- **Richer `devices` command** — shows device name, model friendly name (iPad Pro 12.9" (3rd gen) etc.), iOS/iPadOS version, model number, native display resolution, and optimal transcode target. Added ~60 iPad/iPhone ProductType → model mappings (iPad7–16, iPhone XS through 16). Queries via `AMDeviceCopyValue` on a short lockdown session.
- **Interactive mode with no args** — `mediaporter` by itself now routes to interactive drag-and-drop mode (was printing `--help`).
- **Verbose ffmpeg passthrough** — `-v` mode now tags each stderr line with the output filename, so you can see what both parallel transcodes are doing side by side.

### Changed

- **Forced remux on mixed-codec audio** — `_partition_jobs` now promotes files with mixed audio codecs to `needs_remux=True` even when the container is already MP4, so the iPad audio switcher stays functional.
- **Split sync module** — `mediaporter.sync` exposes `make_sync_file_info()`, `afc_upload_one()`, and `register_uploaded_files()` so the pipeline can drive upload and registration independently. `sync_files()` is now a thin wrapper around these helpers.
- **Python version** — bumped to 0.3.1 (the 0.3.0 tag was the native SwiftUI app release; this is the Python CLI catching up with its own minor version).

### Fixed

- **ffmpeg stderr pipe deadlock** — long transcodes (2h+ 1080p files) would freeze partway through with a stuck progress percentage. Root cause: `subprocess.Popen(..., stderr=PIPE)` with only stdout being drained; once ffmpeg's stderr filled the ~64 KB OS pipe buffer, ffmpeg blocked on its `write(2)` and stopped emitting stdout progress. Now `transcode()` drains stderr on a background thread into a rolling 200-line tail for error reporting (and live passthrough in `-v` mode).
- **Ctrl+C doesn't kill ffmpeg** — the old `ThreadPoolExecutor` shutdown would hang waiting for workers that were themselves blocked on ffmpeg output. A new module-level process registry in `transcode.py` and a `cancel_all()` helper let the pipeline explicitly `terminate()` every in-flight ffmpeg on `KeyboardInterrupt`, then wait 5 s before escalating to `kill()`. Workers unblock cleanly and the executor shuts down.
- **`sync_all()` removed** — the old dead helper was replaced by the pipelined `transcode_and_sync()` path.

### Protocol / framework additions

- `AMDeviceCopyValue` and `AMDeviceStopSession` wired into the ctypes bindings.
- `CFNumberGetValue` added with a `cfnumber_to_int()` helper for reading numeric lockdown values (disk capacity/free bytes).
- `query_device_details(device)` and `query_device_disk_space(device)` — short-session lockdown queries that return device name, ProductType, iOS version, model number, and `(free_bytes, total_bytes)`.

## 0.2.1 — 2026-04-06

Reliability improvements for large file transfers and interactive UX enhancements.

### New

- **Upload-first sync architecture** — files are uploaded via AFC before the ATC session starts. The ATC session is now seconds instead of minutes, eliminating timeouts for multi-GB files. Interrupted uploads no longer leave ghost entries in the TV app.
- **Interactive subtitle selection** — checkbox multi-select for which subtitle tracks to embed (space to toggle, enter to confirm).
- **Interactive metadata correction** — when TMDb can't match a filename, prompts for manual title/year input and re-searches.
- **Fallback poster generation** — auto-generates a dark poster with title text (via Pillow) when TMDb has no poster art. Every file gets a poster.
- **Verbose upload progress** — `-v` mode now shows upload percentage every 10% during AFC transfer.

### Changed

- **Analysis display moved after selection** — stream actions now reflect the actual plan (selected tracks, force-AAC normalization) instead of showing all streams as "copy" before the user chooses.
- **Thread-based ATC message reading** — replaced SIGALRM with daemon threads for read timeouts. Ctrl+C now works reliably during sync (previously trapped in native ctypes calls).
- **SyncAllowed as sync-complete signal** — for large files, the device may send SyncAllowed (idle handshake) instead of explicit SyncFinished. Both are now recognized as success.

### Fixed

- **5GB+ file sync** — previously failed due to ATC session timeout during long AFC uploads. Upload-first architecture eliminates this entirely.
- **Ghost entries on failed sync** — metadata was registered before file upload, leaving unplayable entries in Movies tab. Now metadata is only registered after files are on device.
- **Ctrl+C hanging** — native `ATHostConnectionReadMessage` blocked Python signal delivery. Thread-based reads allow clean interruption.
- **Stale sync plists** — accumulated plists from failed experiments could confuse the device. Cleanup integrated into sync flow.

### Protocol discoveries

- ATC session goes stale during long AFC uploads (>5min) — device resets sync state
- Device sends InstalledAssets/AssetMetrics/SyncAllowed cycle as idle heartbeat after processing sync
- Opening new AFC connection (AMDeviceConnect+StartSession) during active ATC session can interfere with ATC state
- FileBegin before AFC upload keeps ATC session aware of in-progress transfer

## 0.2.0 — 2026-04-06

Complete rebuild of mediaporter. Replaced pymobiledevice3-based transfer with native ATC protocol implementation via ctypes. Full end-to-end video sync to iPad TV app from Python.

### New

- **Native ATC sync engine** — pure ctypes implementation using Apple's MobileDevice, AirTrafficHost, and CoreFoundation frameworks. No pymobiledevice3 dependency.
- **TV series support** — episodes appear in TV Shows tab grouped by show/season. Automatic detection from filename via guessit.
- **TMDb metadata lookup** — automatic title, year, genre, overview, and poster art from The Movie Database.
- **Poster artwork in TV app** — poster JPEG uploaded via Airlock and referenced in sync plist. Displayed in TV app browse view.
- **Fallback poster generation** — when TMDb has no poster, generates a simple dark poster with title text using Pillow. Every file gets a poster.
- **Interactive audio selection** — per-language track picker when multiple dubs exist (e.g., three Russian translations). Arrow-key navigation, auto-selects single-track languages.
- **Interactive subtitle selection** — checkbox multi-select for which subtitle tracks to embed. Space to toggle, enter to confirm.
- **Interactive metadata correction** — prompts for title/year when TMDb can't match the filename. Re-searches with corrected input.
- **Mixed audio codec normalization** — detects mixed codecs (e.g., AAC + EAC3) and normalizes all to AAC so iPad shows the audio language switcher.
- **Parallel transcoding** — `-j N` flag for ThreadPoolExecutor-based multi-file transcoding.
- **Rich progress UI** — multi-file progress bars for transcoding, transfer speed display for sync.
- **VideoToolbox hardware acceleration** — automatic detection and use of Apple's hardware HEVC encoder.
- **Convenience launcher** — `./mediaporter` shell script at project root for quick access.
- **Ping/Pong keepalive** — handles device keepalive during large file transfers (5GB+).
- **Stale asset cleanup** — parses AssetManifest and sends FileError for pending assets from previous failed syncs.
- **Config file support** — `~/.config/mediaporter/config.toml` with .env file auto-loading for API keys.

### Changed

- **CLI redesign** — `mediaporter movie.mkv` works directly without a subcommand. Custom Click group routes unknown args to the default sync command.
- **Version bumped to 0.2.0** — reflects the complete rebuild.
- **MP4 track naming** — uses `handler_name` instead of `title` metadata (title doesn't survive MP4 muxer).
- **Subtitle embedding** — subrip/ASS/SSA auto-converted to mov_text for MP4 container.
- **Audio channel mapping** — >6ch downmixed to 5.1 (384k), stereo at 256k AAC.

### Removed

- **pymobiledevice3 dependency** — replaced by native ctypes calls to Apple frameworks.
- **Direct SQLite DB modification** (`mediadb.py`) — confirmed dead end; medialibraryd reverts changes.
- **Old transfer module** (`transfer.py`) — replaced by `sync/` package.
- **Old device module** (`device.py`) — replaced by `sync/device.py`.

### Fixed

- **MetadataSyncFinished ordering** — must be sent before file upload to avoid ATC session timeout on large files.
- **Wire command name** — `FinishedSyncingMetadata` on the wire, not `MetadataSyncFinished`.
- **String anchors** — all DataclassAnchors and AssetIDs must be strings, not integers.
- **Binary plist format** — sync plists must be FMT_BINARY, not XML.
- **HEVC copy tag** — `-tag:v hvc1` required even when copying HEVC streams.
- **ffmpeg M4V muxer** — uses `-f mp4` to avoid the ipod muxer which doesn't support HEVC.

### Protocol discoveries

- `is_movie: True` in sync plist sets `media_type=2048` (visible in TV app Movies tab)
- `is_tv_show: True` with `tv_show_name`/`season_number`/`episode_number` creates TV episode entries
- `location.kind: "MPEG-4 video file"` sets `location_kind_id=4`
- Airlock staging (`/Airlock/Media/Artwork/<AssetID>`) needed only for poster artwork, not for video files
- `artwork_cache_id` in plist item dict links uploaded poster to the media entry
- iPad requires same audio codec across all tracks for the language switcher to appear

## 0.1.0 — 2026-04-01

Initial implementation with pymobiledevice3-based file transfer. Transcoding pipeline working, but sync created entries with incorrect media_type (invisible in TV app).
