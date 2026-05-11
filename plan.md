# MediaPorter Roadmap

Living plan. Items move up as priorities change. Engineering checklist for the
MacApp + Python reference. Source of truth for "what's next" — `CLAUDE.md` Next
steps mirrors the P0/P1 items in tighter form.

---

## P0 — Ship now (small, isolated, high impact)

### 1. Episode-still artwork bug
- `MetadataLookup.swift:20` returns `e.showPosterData ?? e.posterData`, so the
  show portrait wins for both Airlock artwork upload (`ATCSession.swift:319`)
  and the embedded MP4 poster atom (`Tagger.swift:33`). TV.app then squishes
  the 500×750 portrait into the 16:9 episode tile — visible bug.
- Fix: flip to `e.posterData ?? e.showPosterData` (per-episode still wins).
- Mirrors Python's `src/mediaporter/metadata.py:175`
  (`poster_url=ep_still_url or show_poster_url`).
- Audit every read of `ResolvedMetadata.posterData` to confirm none want the
  show portrait specifically.

### 2. ffmpeg still fallback for episodes *(shipped)*
- `StillExtractor.swift` extracts 1280×720 JPEG: skip 5%, sample 3 frames
  (10/40/70%), pick brightest (luma > 0.05 else reject). Wired into
  `PipelineController.resolveEpisodePoster` and
  `MetadataLookup.episodePosterFallback`.

### 3. Landscape synthetic fallback for TV episodes *(shipped)*
- `PosterGenerator.generateLandscape` produces 1280×720, scale-aware fonts.
  Episode chain is now: TMDb still → ffmpeg extract → landscape synthetic,
  with `EpisodeStillStamper` burning S/E badge on every branch.

### 4. Test P0 end-to-end
- `swift build` clean.
- Sync 3 AoT episodes → distinct 16:9 stills in TV.app. **2026-05-10: confirmed
  per-episode tiles are now distinct.** Side-effect surfaced as P0.5 #6 below.
- Still pending: episode-without-TMDb-still and no-API-key fallbacks not yet
  observed end-to-end on device. Code path exists; verify next time a JJK-style
  release is loaded (TMDb anime stills are sparse — a natural test case).

### 5. Transcoder `waitUntilExit` hang + Stop escalation *(shipped 2026-05-10)*
- Wedge observed live: ffmpeg exited cleanly but Foundation's
  `proc.waitUntilExit()` parked forever on a CFRunLoop that never received
  the SIGCHLD-derived event (call ran from a background queue with no live
  runloop).
- Fix: replaced with `terminationHandler`-driven async continuation;
  handler installed before `proc.run()` so it's wired into the SIGCHLD reap
  path and fires reliably from any thread. Same fix applied to
  `StillExtractor` (where the race was latent — no production hit yet).
- `ActiveProcesses.cancelAll()` now escalates SIGTERM → SIGKILL after 2 s so
  Stop always escapes a wedged ffmpeg.

### 6. Show-level portrait artwork *(shipped 2026-05-10, commit 88b93bd)*
- For TV episodes we now upload a second JPEG to
  `/Airlock/Media/Artwork/<assetID>_show` and set `album_artwork_cache_id`
  on the insert_track item. medialibraryd picks the portrait up for the
  album row, so TV.app Library shows the show portrait on the show tile
  (was an episode still). Show-detail page hero is hardcoded to 16:9 in
  TV.app and stays an episode still — accepted limitation.

### 7. Clear button after run *(shipped 2026-05-10)*
- `BatchTimelineView` showed Stop while active and nothing in the all-done
  state, so finished rows piled up and the next drag-drop grew the queue
  without bound. Wired the existing `PipelineController.clearCompleted()`
  to a Clear pill that replaces Stop when every job is `.synced`.

---

## P1 — Engine work (next, gated on each other)

### 8. Interleave registration with uploads *(shipped 2026-05-10)*

**Result.** `RegisterSession` (`SyncEngine.swift`) wraps three new ATCSession
phases — `prepareSync` (handshake + plist + MetadataSyncFinished + wait
AssetManifest + clear stale, then start a Ping drainer), `registerFile`
(FileBegin + artwork AFC + FileProgress + FileComplete per file), and
`finishSync` (wait SyncFinished). `PipelineController.runPipelined`
opens the session BEFORE the upload loop and calls `registerFile` from
inside each upload Task as soon as bytes land; per-file `.synced` flips
in the UI as each FileComplete is sent. Smoke test
(`mediaporterctl streaming-test`) on two files: open 19 s upfront,
finishSync 5 s at the end (vs 128 s in the legacy bulk register). On
larger batches the gain scales — the old ~30 s/file finalizing burst
disappears entirely. Cancel path: `abandonAsset(assetID:)` sends
FileError(0) for any pre-allocated asset we won't FileComplete, so
medialibraryd doesn't block SyncFinished waiting for it.

Legacy `register(...)` and `registerUploadedFiles(...)` retained for
orphan recovery + retry-registration paths.

**History — gating experiment (2026-05-10).** Ran `mediaporterctl gate-test`
with two H.264 mp4s on iPhone (akm16pro). After sending `FileComplete #1`,
pulled `MediaLibrary.sqlitedb`+wal via a parallel AFC connection: file 1's
row was present in `item_extra.location` at T+0s (within ~1.5 s of the
send), still present at T+60s, still well before `FileComplete #2` or
terminal `SyncFinished`. medialibraryd commits per FileComplete, not on
batch terminator. register() wall time was 128 s for 2 files (≈30 s/file
post-batch — matches the plan's hypothesis of why the finalizing phase
feels dead). Code: `Sources/Sync/GateTest.swift`,
`ATCSession.register(afterFileComplete:)`, `ATCSession.pingAwareSleep`.

**Follow-ups.**
- Port to Python (`src/mediaporter/sync/atc.py`) — same three-phase
  shape; lower priority since the GUI is the primary surface.
- Real-world batch validation: drag 10+ files, confirm timeline turns
  green progressively and overall wall time matches expectation.

### 9. Mid-sync device-disk poll *(shipped 2026-05-10)*
- `runPipelined` now re-queries `queryDeviceDiskSpace` per file before
  each AFC upload starts. Aborts cleanly with "Device filled up during
  sync" if free < incoming + 256 MB headroom (the scratch medialibraryd
  briefly holds during ingestion). Replaces the cryptic mid-write AFC
  failure when iOS background traffic eats space mid-batch.

### 10. Parallel analyze *(shipped 2026-05-10)*
- `analyzeAll` runs in waves of `TaskGroup`-with-cap=4. probeFile is
  I/O-bound and TMDb / OpenSubtitles are network-bound, so 4 episodes
  analyze in roughly the time of 1.
- Cluster-resolve dedup: `clusterResolveTasks: [String: Task<...>]`
  coalesces concurrent same-cluster calls — first job's task is awaited
  by the rest, so 12 episodes of one show fire one TMDb search, not 12.
- Wave model picks up jobs added mid-run (second drag-drop while wave 1
  is still analyzing) — they form the next wave.

### 10b. Duplicate detection before sync *(shipped 2026-05-11)*
- `loadDeviceLibrary(device:)` pulls `MediaLibrary.sqlitedb` (+ wal/shm)
  via AFC and SELECTs `(title, total_time_ms)` from `item_extra` where
  `media_kind IN (2, 32)` (movies + TV episodes). Run once at the start
  of `analyzeAll` when a device is connected; snapshot lives on
  `PipelineController.deviceLibrarySnapshot`.
- `analyzeOne` tags each `FileJob.duplicateOnDevice` by matching the
  job's computed sync title against the snapshot (durationMs within
  ±2 s). Title is what SyncItem would set in the plist — episode title
  for TV, movie/file title for movies — so it round-trips exactly with
  what landed on the device on a previous sync.
- `runPipelined` filters out `duplicateOnDevice && !syncDespiteDuplicate`
  before opening the register session; if every analyzed job is a
  duplicate, status reads "Nothing to sync (all files already on device)"
  and we don't open the ATC session at all.
- UI: per-row chip in `FileRowView` shows "on device — skip" by default;
  clicking toggles `syncDespiteDuplicate` and the chip becomes
  "will duplicate" (amber) so the user knows they're opting into a
  duplicate row.
- Snapshot is cleared after `runPipelined` completes — the rows we just
  added would otherwise flag the next analyze as duplicates.

---

## P2 — UX polish

### 11. External audio/sub track muxing (anime release layout)
*Land Python first per CLAUDE.md, port to Swift after.*

**Problem.** Scene anime releases ship as bare MKV (JP audio + EN sub) with
sibling folders of `.mka` dub tracks and `.srt/.ass` sub tracks, one folder per
studio, filenames matching the video 1:1. Reference layout
(`~/Downloads/Jujutsu.Kaisen.Season3.WEB-DL.1080p`):
```
[BudLightSubs] Jujutsu Kaisen S3 - 01 [1080p].mkv
…
RUS Sound/AniLiberty/[BudLightSubs] Jujutsu Kaisen S3 - 01 [1080p].mka
RUS Sound/RedHeadSound/…  (5 more studios)
RUS Subs/CafeSubs/…
RUS Subs/Crunchyroll/…
RUS Subs/Crunchyroll/Надписи/   (typesetting / forced)
```
Today the Python pipeline and MacApp see only the bare MKV — JP-only audio
reaches the device, all 6 dubs ignored.

**Decisions taken (2026-05-10 review).**
- Selection scoped per **cluster** (TMDb show+season), persisted under
  `clusterID`. User picks once for the whole season, applies to every episode.
- Track ↔ episode matching by parsed **S/E numbers** via `FilenameParser`, not
  by basename. Robust to studio renames.
- ASS subtitles converted to `mov_text` at mux time (style loss accepted —
  TV.app on iOS has no ASS renderer). SRT in as-is. Hardsub deferred.
- One mux step **before** the existing transcode stage: produces an
  intermediate multi-audio MKV in temp, then `Transcoder` runs unchanged. The
  AC3-switcher rule (CLAUDE.md #10) catches AC3 dub tracks naturally — they
  hit `transcode AC3 → AAC` like any internal AC3.

**Phases.**

#### 11a. Python: detector + data model
- New module `src/mediaporter/extras.py`:
  - `scan_release(source_dir: Path, episodes: list[ParsedFile]) -> ReleaseExtras`
  - Walks `source_dir` and one level of siblings. Identifies dub folders
    (`.mka/.ac3/.eac3/.flac/.aac` files matching parsed S/E of any episode)
    and sub folders (`.srt/.ass/.vtt`). Folder name → studio label.
  - Heuristic for language: parent path contains "RUS" / "ENG" / locale code
    → tag accordingly; else fall back to ffprobe `language` metadata; else
    `und`.
  - Returns `ReleaseExtras { dubs: [DubStudio{label, lang, episodes: dict[(s,e)→Path]}],
    subs: [SubTrack{label, lang, forced: bool, episodes: dict[(s,e)→Path]}] }`.
  - "Forced" inferred from folder name (`Надписи`, `Signs`, `Forced`) or
    track name in ffprobe.
- Unit tests with a fixture that mirrors the JJK layout (empty 1-byte stub
  files are enough — detector doesn't read content yet).
- Edge: orphan dub episode (E08 in dubs, missing in main video) → log + drop,
  do **not** fabricate a video entry.

#### 11b. Python: CLI selection + mux step
- Extend `mediaporter sync` with `--include-dub LABEL` (repeatable),
  `--default-dub LABEL`, `--include-sub LABEL`. Without flags, behavior
  unchanged (pure backwards compat).
- Add stage between `analyze` and `transcode` in `pipeline.py`:
  `mux_external_tracks(video, extras, selection) -> Path` →
  intermediate MKV in temp.
- ffmpeg invocation:
  - `-i video.mkv -i dub1.mka -i dub2.mka -i sub1.srt -i sub2.ass`
  - Map: `-map 0:v -map 0:a:0 -map 1:a:0 -map 2:a:0 -map 3:s? -map 4:s?`
    (keep original audio as track 0; appended dubs follow).
  - Per-track metadata: `-metadata:s:a:N title=<studio> language=<lang>`.
  - Disposition: exactly one `default` on the audio track flagged as
    "default" in selection; everything else `0`. (CLAUDE.md #10.)
  - Subtitles: ASS pre-pass `ffmpeg -i in.ass out.srt` (drops styling) before
    main mux. mov_text codec assignment happens in `Transcoder`, not here —
    keep mux step codec-copy for speed.
- ffprobe each external `.mka` ahead of mux; if AC3, hand `Transcoder` a hint
  to recode that specific track index → AAC. Existing rule covers it once
  flagged.

#### 11c. Python: validate on JJK
- Run end-to-end with 2 dubs + 1 sub selected. Verify on iPad:
  - Audio switcher shows JP + 2 RU studios with correct labels.
  - Subtitle switcher shows the selected RU sub.
  - Episode 8 absent from video is reported as skipped, not crash.
  - No regression on a normal single-audio MKV (selection empty path).

#### 11d. Swift port: scanner + state
- `MacApp/MediaPorter/Sources/Metadata/ExternalTrackScanner.swift` mirrors
  `extras.py`. Returns `ReleaseExtras` struct.
- Persist selection in a new `ClusterPreferences` store keyed by `clusterID`
  (same key TMDb cache uses). Survives app relaunch.

#### 11e. Swift port: UI
- New view section in the cluster header (where TMDb poster/title sit in
  `DeviceColumnView`) — collapsed by default, expands when extras detected:
  ```
  Доп. аудио:  ☐ AniLiberty  ☑ RedHeadSound  ☐ StudioBand  ☐ TVShows
                ☐ Дубляжная   ☐ ForceMedia
  По умолчанию: ◉ RedHeadSound
  Доп. сабы:    ☑ Crunchyroll  ☐ CafeSubs  ☑ Crunchyroll/Надписи (forced)
  ```
- Counter chip on each episode row: "+2 audio, +1 sub" so user sees what
  will be muxed without expanding the section.

#### 11f. Swift port: pipeline integration
- New stage `MuxExternalTracks` in `PipelineController` between analyze and
  transcode. Same ffmpeg semantics as 11b.
- Status enum gains `.muxing` between `.analyzed` and `.transcoding`.
- Cleanup: intermediate MKV deleted after `Transcoder` consumes it (or on
  cancel, via `ActiveProcesses`).

**Out of scope (defer, link back here when pulled).**
- Hardsub mode for ASS (separate ffmpeg path; breaks HEVC copy).
- Auto-selecting "best" dub (subjective; let the user click).
- Downloading missing tracks from external sources.
- Per-episode override of cluster selection (one user, one season — overkill
  unless someone asks).

### 12. Recommendation rework
- Banner today (`DeviceColumnView.swift::recommendationCard`) makes a flat
  "1080p is the sweet spot for this device's display" claim. Misleads users
  who AirPlay/HDMI to a 4K TV; ignores storage axis; resolution alone isn't
  the real space lever.
- Decisions:
  - Keep on-device-display framing as default copy.
  - Add Settings toggle "I AirPlay/cast to a 4K TV" → flips
    `suggestedResolution` to `.original` (or `.uhd4k`) and rewrites banner.
  - Storage-aware: when `deviceFreeBytes` >> incoming library (e.g. >3×),
    bias toward keeping originals; when tight, push downscale harder. Banner
    reflects which mode it's in.
  - Surface bitrate alongside resolution. Add a bitrate hint to the banner;
    show source bitrate in the per-file row in `FileRowView`.

### 13. Zombie ffmpeg sweep at launch
- `ActiveProcesses.cancelAll()` (Transcoder.swift:104) only fires on graceful
  Swift exit. SIGKILL/crash leaves orphan ffmpeg children writing to temp.
- On launch, find ffmpeg processes whose CWD is our temp dir and whose parent
  PID is gone; terminate.

---

## P3 — QoL features (pull when an item bites)

10. Manual metadata override in the file row (title / year / SxxEyy).
11. Dry-run / final-size estimate before "Send"
    (source bitrate × resolution-ratio² × duration).
12. Forced-subtitle flag in the per-file details.
13. Audio loudnorm checkbox.
14. Multi-device picker in DeviceColumn (currently auto-picks iPad).
15. Expert-mode custom ffmpeg flags in Settings.

---

## Deferred / not planned (with reason)

- **Multi-track HW transcode** — VideoToolbox media-engine count makes
  "30–40%" speculative; benchmark before planning anything.
- **Poster `Data` memory footprint** — ~10 MB at 100 files; not a real
  problem.
- **ffmpeg version pinning/warnings** — no observed breakage.
- **TMDb cluster name+year collisions** — picker already lets the user fix it.
- **Orphan detection via `AssetManifest`** — keep on the radar, but it
  naturally lands as part of #5 since `AssetManifest` parsing arrives there.
