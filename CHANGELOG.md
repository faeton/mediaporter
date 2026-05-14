# Changelog

The Swift MacApp under `MacApp/` is the shipping target. Versions starting with 0.4.0 track the MacApp; the 0.1.x – 0.3.x entries describe the now-frozen Python CLI under `python-reference/`.

## 0.6.1 — 2026-05-14

Hotfix: large-file syncs (>~10 s upload) landed the row in TV.app but the row was unbound and the file got swept — title visible, Play did nothing.

### Fixed

- **Large-file binding** — `ATCSession.finishSync` was treating `SyncAllowed` as terminal-equivalent to `SyncFinished`. The device sends `SyncAllowed` early (right after MetadataSyncFinished / FileBegin) as "you may proceed" and it accumulates in the drainer inbox during long uploads; finishSync grabbed the stale message and returned before medialibraryd committed the asset, leaving the row with `base_location_id=0` and the bytes orphaned for background GC. Mini-clips worked because their upload finished before `SyncAllowed` arrived. Fix: drop pre-existing inbox entries on entry, wait strictly for `SyncFinished` (up to 120 s), fall back to `SyncAllowed` only after a 30 s grace period. Detail: `research/docs/HISTORY.md` "2026-05-14 — SyncAllowed is NOT terminal" + new CLAUDE.md rule #14.
- **`Send N to iPhone` button no-op when all files were skip-on-device** — button now counts files matching the actual `runPipelined` filter; if zero remain it shows a disabled "N file(s) already on device" with a hint to use the per-row badge to override. Skipped rows are dimmed.
- **`atc.FileProgress` heartbeat during upload** — sent every 5 s or 10 % during the AFC upload to keep medialibraryd's asset slot warm. (Turned out the binding bug was elsewhere, but the heartbeat is correct protocol behaviour and matches what real iTunes/Finder do.)

## 0.6.0 — 2026-05-14

The cluster-extras release. Drop a folder of episodes with dub / sub subfolders, pick studios / labels once at cluster level, and Mediaporter muxes each episode's extras into the transcode pass — with the user-chosen default audio surviving into the TV app. Plus the long tail of post-0.5.0 reliability + UX work, signing + notarization, and the first signed DMG shipping from porter.md.

### New

- **TV-show clustering** — episodes from the same drop are grouped by parsed (show name, year). One TMDb lookup per cluster (not per file), one show-pick re-applies across every episode. A pending-pick is surfaced as a single resolvable conflict instead of N modal prompts.
- **Cluster-scoped selection (#11a / 11b)** — audio / sub / resolution / burn-in changes on one episode raise an "Apply to all N other episodes?" popover that auto-dismisses after 5 s. "Always" toggle silences the prompt entirely; reachable from both the popover and Settings → TV shows.
  - Intent is stored as `(lang, codec)` pairs, not stream indices — survives across episodes where track order differs.
  - When a sibling has no matching `(lang, codec)` for the cluster's audio intent, fall back to selecting every audio track instead of bricking the output with an empty audio map.
- **External-track scanner (#11c)** — walks the source directory (depth ≤ 4) for `.mka / .ac3 / .eac3 / .flac / .aac / .m4a / .opus` (dubs) and `.srt / .ass / .ssa / .vtt` (subs). Groups by parent folder = label, infers language from path tokens, detects "forced" subs by token (`forced`, `signs`, `songs`, `надписи`, `форсированные`). Scanner runs once per directory, not once per file.
- **ClusterExtrasSection UI (#11d)** — collapsible section at the top of the file list, one per cluster with extras. Per-studio audio checkbox + Default radio (CLAUDE.md #10 compliant: exactly one default at output); per-label sub checkbox + "Burn in" radio that auto-includes the sub in the mux and flags the file for transcode.
- **External-track mux pass (#11e)** — pre-transcode ffmpeg pass combines source video + selected dubs / subs into an intermediate MKV (codec-copy, chapters + data streams stripped, ASS / SSA pre-converted to SRT, exactly one default audio). The existing transcode stage runs against the intermediate unchanged.
- **Burn-in on cluster-extras subs** — selecting Burn-in on a cluster-extras sub label is now end-to-end: the sub is auto-included for the mux, the burn-in language is carried through the mux, and the post-mux re-probe rewrites the burn-in target to the newly embedded subtitle stream index. Works for direct picks and for propagated burn-in language from a sibling.
- **OpenSubtitles auto-fetch** — when API key + login + languages are set in Settings, analyze fetches missing-language SRTs via moviehash / TMDb id into `~/Library/Caches/MediaPorter/opensubtitles` and includes them in the next pipeline run.
- **Burn-in subtitles** — embedded text (libass via `-vf subtitles=`), sidecar SRT, and bitmap (PGS / VOBSUB via `filter_complex overlay`) are all burnable. Bitmap canvas size is picked per codec (1920×1080 for PGS, 720×576 for DVD); downscale is applied after overlay so burned glyphs scale with the picture.
- **Anime episode handling** — filename parser learned `S01 - E01`, `Show.S01E01-Final`, and friends; episode picker race fix prevents stale TMDb responses from clobbering current selections; tagger drops the "0." prefix on TV episodes by writing `episode_sort_id` to the insert_track plist.
- **Duplicate skip (#10b)** — analyze pulls a snapshot of the device's `MediaLibrary.sqlitedb` via AFC and flags files whose (title, durationMs ±2 s) already exist. Skipped by default; per-row override puts them back into the queue.
- **Streaming registration (#8)** — ATC session opens before the upload loop; per-file `FileBegin/FileComplete` fires the moment AFC finishes a file; medialibraryd commits rows continuously. Replaces the previous "one big register call at the end" path. Failed registration leaves bytes on the device with a "Retry Registration" menu item that re-runs just the ATC step.
- **Mid-sync disk watchdog (#5 / #9)** — background poll every 10 s queries device free space and aborts cleanly if it drops below 256 MB during a long upload; per-file preflight checks file size + 256 MB headroom before each FileBegin. Previously a runaway Photos / iCloud sync mid-upload surfaced as a cryptic AFC write error several minutes in.
- **Parallel analyze (#10)** — analyzeAll runs probe + decision + TMDb resolve in waves of up to 4. Cluster resolution is deduped per cluster id so 8 episodes of the same show fire one TMDb search instead of 8.
- **Storage-aware recommendation banner (#3)** — banner respects the device's panel resolution by default; Settings → Transcode → "I AirPlay or cast to a 4K display" toggle flips it to keep originals.
- **Zombie ffmpeg sweep (#6)** — at launch, sweep system ffmpeg processes whose command line references the app's temp prefix and SIGKILL them. Recovers cleanly from a previous SIGKILL / panic that bypassed `ActiveProcesses.cancelAll()`.
- **Orphan-aware cleanup (#2)** — "Clean Up Staged Media Files" cross-references the device's `AssetManifest` and removes only true orphans under `/iTunes_Control/Music/F*/`. Surfaces leftover transcoded `.m4v` outputs from previous failed runs with a one-click cleanup banner.
- **Help menu — bug report + diagnostic info** — one-click captures a redacted report (app version, OS, device, last debug log tail) and opens a pre-filled GitHub issue.
- **ffmpeg precheck at launch** — surfaces a one-shot dialog with `brew install ffmpeg` guidance when ffmpeg is missing on $PATH; verdict logged to the debug log. Release builds will bundle ffmpeg inside the `.app`.
- **Cancel + Retry per row** — Cancel button on the bottom timeline kills every in-flight ffmpeg (mux pass, ass→srt pre-pass, main transcode all participate now), unwinds the AFC upload at the next 1 MB chunk, and abandons in-flight ATC asset registrations. Retry button on a failed row re-runs only that file.
- **Hold-to-preview poster** — hold any row's poster thumbnail to see the full-size artwork (show portrait + episode still side by side for TV).
- **Multi-device support** — picks iPad first when multiple devices are attached; explicit override is persisted across launches.
- **CLI 'pull' command** — `mediaporterctl pull <devicepath>` reads any file off the device via AFC, mirroring Apple's Finder behaviour. Useful for protocol debugging and inspecting on-device state.
- **Sign-and-notarize pipeline** — `MacApp/scripts/build-app.sh` + `release.sh` produce a signed + notarized + stapled DMG via Developer ID. Hardened runtime with `disable-library-validation` for the bundled `libcig.dylib`. First public DMG hosted on [porter.md](https://porter.md).
- **AppIcon generation** — `AppIcon.icns` is built from the runtime brand mark composition; same artwork used in dock, Finder, and Spotlight.

### Changed

- **Default audio is preserved through transcode** — the final ffmpeg pass now pins the input's existing `default` disposition (set by the cluster-extras mux step on the user's chosen dub) instead of always forcing track 0 as default. The Default radio in ClusterExtrasSection is now wired all the way to the TV app.
- **Burn-in forces a transcode** — `needsReencode` / `videoBeingReencoded` return true when `burnInSubtitle` is set or a deferred `pendingBurnInExtraLang` is staged. Previously a sibling that received a propagated burn-in onto otherwise-compatible video would skip ffmpeg and silently drop the burn-in.
- **`reclusterJobs` migrates cluster state** — when "Set show…" reassigns a job to a new cluster, `clusterExtras` and `clusterSelections` move with it. Old keys are GC'd when no remaining job references them.
- **TMDb `original_language` fallback for untagged audio** — embedded audio with no `language` tag (or `und`) inherits the title's `original_language` so the iPad TV-app switcher doesn't surface every untagged anime track as "Unknown".
- **Two-artwork sync** — every TV episode gets both a show portrait (used as the Library tile) and an episode still. Movie posters stay single-artwork.
- **Honest UX during the post-upload register wait** — finishing-sync stage no longer flashes "0 synced" while medialibraryd commits; the timeline reads "X on device" until rows actually land, then flips to "X synced" + Clear button. Transcode / tag no longer clobber the device-card status while uploads run in parallel.
- **Selection-aware work classification** — deselecting an incompatible track flips `needsReencode` off if it was the only reason to transcode. AC3-only files where the user dropped the AC3 track now copy through without any ffmpeg pass.
- **Cmd-Q guard while syncing** — confirms before quitting during an active run so half-uploaded files don't leak as orphans.
- **Dock icon set programmatically** — no .icns dependency at debug-build time; release builds use the icns bundled into Resources.
- **Cleanup confirmation shows total size** — Device → Clean Up surfaces "Free up X GB" instead of just a file count.
- **Same-language sub warning** — when two subs share a language code, the row warns that the iOS picker dedupes them into a single entry regardless of `title` / `handler_name` / disposition. Verified on iPhone 16 Pro / iOS 26.4.2 via `scripts/test_subtitle_picker.py`.
- **Tagger no longer hangs** — `ffmpeg` stdin is detached from the tty and tagging waits on `terminationHandler` continuations instead of `waitUntilExit`. Long tagging operations on big files don't freeze the UI.

### Fixed

- **Cancel during mux leaked a zombie ffmpeg** — `ExternalMux.mux` and `convertAssToSrt` now register their `Process` with the shared `ActiveProcesses` registry, so `Transcoder.cancelAll()` reaches them. SIGTERM then SIGKILL after a 2 s grace, identical to the main transcode pass.
- **Burn-in on cluster-extras subs silently dropped** — fixed end-to-end (see "New" → Burn-in on cluster-extras subs).
- **Always-apply toggle was a roach motel** — once enabled in the popover, the popover never resurfaced (because Always silently propagates) so the toggle was unreachable. Now also in Settings → TV shows.
- **Burn-in chip disappeared on siblings after propagation** — sibling jobs with compatible video had `videoBeingReencoded == false`, so the UI hid the burn-in flame. Now any non-nil burn-in (resolved or deferred) makes the chip render.
- **PGS burn-in on a 4K → 1080p downscale** — bitmap subtitle was overlaid at the source canvas then ignored on scale, leaving subs in the top-left corner. Now scales to source dims before overlay, then downscales the composite. Sub text scales with the picture.
- **Stale assets bricking SyncFinished** — parse `AssetManifest`, send `FileError` (ErrorCode 0) for any AssetID that isn't ours. Prevents the device from waiting forever for assets from a previous failed run.
- **TV episode "0." prefix in TV.app** — `insert_track` plist was missing `episode_sort_id`. Without it the TV app couldn't sort and prefixed every title with "0.".
- **852p banner copy** — the recommendation banner was extracting the device's panel height (852 for iPhone 16 Pro) and reporting it as the target. Now reports a ResolutionLimit name ("1080p", "Original") instead.
- **Misleading "recommend 1080p" banner on AirPlay setups** — replaced by the storage-aware + AirPlay-to-4K logic.
- **Hung transcoder after a previous run** — `unwedge` path clears `isAnalyzing / isRunning` flags and the cancel state when a previous run died unexpectedly; "Clear" button on the bottom timeline reaches `synced` jobs only.

### Protocol / framework

- `dlopen` Apple's `MobileDevice.framework` and `AirTrafficHost.framework` at runtime — no admin prompts, no `SMAppService` dialog, no sudo. The `pymobiledevice3 remote start-tunnel` step is Python-reference-only.
- Wired `ATHFileError`, fixed `AT*` return-type signatures in the ctypes shim, ported stale-asset `FileError` flow from the Python reference.
- Per-stream `disposition.default` propagated from `ffprobe` through `StreamInfo.isDefault`; final transcode pins exactly one default at output (mp4 muxer forces ≥1 default).

## 0.3.2 — 2026-04-13

Corrects the iPad audio-language-switcher rule and drops a lot of incidental re-encoding along the way. Previous versions believed "every audio track must share a codec or the switcher disappears" and normalized the whole track set; the real rule is codec-specific and much cheaper.

### Changed

- **AC3 → AAC transcode, AAC + EAC3 copy.** The iPad TV app decodes AC3 but silently drops AC3 tracks from the audio-language selector. AAC and EAC3 are both listable and can coexist freely. The pipeline now transcodes only the AC3 tracks (stereo 256k / 5.1 384k AAC) and copies AAC + EAC3 through untouched, so a typical `ac3 + eac3` release gets its 5.1 EAC3 preserved bit-perfect instead of being re-encoded. `compat.COMPATIBLE_AUDIO_CODECS` drops `ac3`.
- **Exactly one default audio track, enforced at ffmpeg invocation.** A track that carries `default` disposition on every audio stream (or inherits multiple defaults from a careless source) kills the switcher entirely. `build_ffmpeg_command` now always emits `-disposition:a:0 default` plus `-disposition:a:N 0` for the rest, regardless of source state. The MP4 muxer still forces at least one default, so "no defaults" is not a failure mode.
- **`_partition_jobs` no longer force-remuxes mixed-codec files.** Per-stream codec decisions in `compat.evaluate_compatibility` are authoritative — files with AC3 partition into `needs_transcode` naturally, files with only compatible codecs in different flavors (e.g. `aac + eac3`) pass through as copy.

### Removed

- `mediaporter.audio.pick_normalization_codec()` and `target_bitrate_for()` — both existed only to implement the incorrect "pick the best codec and normalize everything to it" rule. Their callers in `transcode.py`, `pipeline.py`, and `progress.py` have been simplified accordingly.

### Research

- **`research/docs/AUDIO_SWITCHER_RULE.md`** — full experimental matrix (11 variants A–K) proving the codec-specific rule. Source file: `The.Luckiest.Man.in.America.2024.AMZN.WEB-DL.1080p.mkv` with 4 audio tracks (2× RU AC3, 1× UK AAC, 1× EN EAC3 5.1). Every outcome is explained by "AAC/EAC3 listable, AC3 silently filtered, need ≥2 listable tracks, exactly one default."
- **`scripts/test_audio_switcher.py`** — reproducible test harness. Builds all 11 variants from one MKV, generates distinct labeled cover JPEGs per variant (so they're identifiable on-device by color and big letter), and syncs them via `mediaporter.sync.sync_files`. Supports `--only A,B,C`, `--no-build`, `--no-sync` for iterative workflows.
- **CLAUDE.md finding #15** rewritten. The 2026-04-06 "all tracks must share a codec" assumption was conflating the AC3-specific filter with a codec-uniformity requirement.

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
