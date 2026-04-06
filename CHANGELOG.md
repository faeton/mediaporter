# Changelog

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
