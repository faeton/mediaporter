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

### 11. Cluster-scoped selection — internal bulk-apply + external track muxing ✅ 2026-05-11
*Swift-first. CLI/Python will catch up later.*

Shipped: `MacApp/MediaPorter/Sources/Pipeline/ClusterSelection.swift`,
`MacApp/MediaPorter/Sources/Metadata/ExternalTrackScanner.swift`,
`MacApp/MediaPorter/Sources/Transcode/ExternalMux.swift`,
`MacApp/App/Sources/ClusterExtrasSection.swift`. Bulk-apply popover in
`FileRowView`; mux pre-stage in `PipelineController.transcodeAll`.

**Two problems, one model.**
1. Drop 12 episodes × 5 audio + 6 sub tracks. User wants only RU audio + RU sub.
   Today: ~100 per-row clicks.
2. Scene anime releases ship as bare MKV (JP audio + EN sub) with sibling folders
   of `.mka` dubs and `.srt/.ass` subs. Today only the bare MKV is seen — all
   dubs ignored. Reference layout (`~/Downloads/Jujutsu.Kaisen.Season3.WEB-DL.1080p`):
   ```
   [BudLightSubs] Jujutsu Kaisen S3 - 01 [1080p].mkv
   RUS Sound/AniLiberty/[BudLightSubs] Jujutsu Kaisen S3 - 01 [1080p].mka
   RUS Sound/RedHeadSound/…       (5 more studios)
   RUS Subs/Crunchyroll/…
   RUS Subs/Crunchyroll/Надписи/   (typesetting / forced)
   ```

Both reduce to: **user picks once per cluster, applies to every episode**.
Build a shared `ClusterSelection` layer and both #11-internal and #11-external
fall out of it.

**Core abstraction: `ClusterSelection`.**

Keyed by `clusterID` (already on `FileJob`). Holds **intent**, not concrete
stream indices:

```swift
struct ClusterSelection {
    // Internal-stream intent (resolved against each FileJob.mediaInfo)
    var audio: AudioIntent = .all     // .all | .langs(Set<String>) | .codecs(...) | .explicit(...)
    var subs: SubIntent = .all
    var maxResolution: ResolutionLimit = .original
    var burnInSubLang: String?        // resolved per-episode at transcode time

    // External-track intent (resolved against ReleaseExtras per episode)
    var includedDubStudios: Set<String> = []
    var defaultAudioStudio: String?   // single "default" disposition
    var includedSubLabels: Set<String> = []
}
```

A **resolver** at analyze time computes per-job concrete `selectedAudio`,
`selectedSubtitles`, `selectedExternalSubs`, `maxResolution`, `burnInSubtitle`,
plus an `externalTracksToMux: [ExtraTrackRef]` field, by intersecting intent
with what that episode actually has.

Matching rules (apply to both bulk-apply and external):
- Internal audio/sub: match by `(language, codec_name)` — indices drift between
  episodes, lang+codec is stable. If target episode lacks a match, skip silently
  for that episode.
- External: match by `(s, e)` from `FilenameParser`. Orphans (E08 in dubs,
  missing in video) → log + drop.
- Scalars (resolution, burn-in lang) propagate directly.

**Phases.**

#### 11a. ClusterSelection store + resolver
- New `MacApp/MediaPorter/Sources/Pipeline/ClusterSelection.swift`: the struct
  above + a store `var clusterSelections: [String: ClusterSelection] = [:]`
  on `PipelineController`.
- New `ClusterSelectionResolver.resolve(job:, selection:, extras:) -> JobSelection`
  pure function. Called at end of `analyzeOne` (before today's
  `setDefaultStreamSelection` heuristic). Today's heuristic stays as the
  *seed* when no `ClusterSelection` exists yet for that cluster.
- `FileJob.selectedAudio/Subtitles/…` continue to exist (UI binds to them);
  resolver writes them. UI change on a single row → write back to
  `clusterSelections[clusterID]` as `.explicit(langs+codecs of current
  selection)` and re-resolve all sibling jobs.
- Persistence: cluster selection lives in-memory only for v1. Per-cluster
  preferences across launches deferred (state-surface cost not yet justified).

#### 11b. UI — bulk-apply popover for internal streams
- When the user toggles audio/sub/resolution/burn-in on a row that has
  `clusterID` ≠ nil AND ≥ 2 sibling jobs in the cluster: anchored popover
  near the changed control:
  > Apply to all 12 episodes of *Jujutsu Kaisen S3*? ☑ Apply  · Just this one
- Auto-dismiss after 5 s if user keeps clicking. For one-off files (movies,
  single episodes) the popover never appears.
- Settings toggle "Always apply within show" for power users.

#### 11c. External-track scanner
- `MacApp/MediaPorter/Sources/Metadata/ExternalTrackScanner.swift`:
  `scanRelease(sourceDir: URL, episodes: [ParsedFile]) -> ReleaseExtras`.
- Walks source dir + one level of siblings. Identifies dub files
  (`.mka/.ac3/.eac3/.flac/.aac`) and sub files (`.srt/.ass/.vtt`) matching
  parsed `(s, e)` of any episode in the drop. Folder name → studio label.
  Flat layout (no folders, dub file next to video) → label "external" or
  the filename language tag.
- Language heuristic: parent path contains `RUS`/`ENG`/locale code → tag;
  else ffprobe `language` metadata; else `und`.
- Forced inferred from folder name (`Надписи`, `Signs`, `Forced`) or ffprobe
  track name.
- Returns `ReleaseExtras { dubs: [DubStudio{label, lang, episodes: [(s,e):Path]}],
  subs: [SubTrack{label, lang, forced, episodes: [(s,e):Path]}] }`.
- Stored once per cluster (`clusterExtras: [String: ReleaseExtras]`).

#### 11d. UI — cluster header for external tracks
- New section in cluster header (next to TMDb poster/title in
  `DeviceColumnView`). Collapsed by default; expands when extras detected:
  ```
  Доп. аудио:  ☐ AniLiberty  ☑ RedHeadSound  ☐ StudioBand
  По умолчанию: ◉ RedHeadSound
  Доп. сабы:    ☑ Crunchyroll  ☑ Crunchyroll/Надписи (forced)
  ```
- Counter chip on each episode row: "+2 audio, +1 sub".
- Same popover pattern as 11b — but for external it's *always* cluster-wide
  (no "just this one" option, by design).

#### 11e. Pipeline integration — mux step
- New stage `MuxExternalTracks` in `PipelineController` between analyze and
  transcode, runs only when `job.externalTracksToMux` non-empty.
- ffmpeg invocation:
  - `-i video.mkv -i dub1.mka -i dub2.mka -i sub1.srt -i sub2.ass`
  - Map: `-map 0:v -map 0:a:0 -map 1:a:0 -map 2:a:0 -map 3:s? -map 4:s?`
  - Per-track metadata: `-metadata:s:a:N title=<studio> language=<lang>`.
  - Disposition: exactly one `default` audio (CLAUDE.md #10); rest `0`.
  - ASS pre-pass `ffmpeg -i in.ass out.srt` (drops styling — TV.app has no
    ASS renderer; hardsub deferred).
  - Mux step is codec-copy. ffprobe each external `.mka` ahead of mux; if
    AC3, hand `Transcoder` a hint to recode that specific track → AAC
    (CLAUDE.md #10 covers it once flagged).
- Status enum gains `.muxing` between `.analyzed` and `.transcoding`.
- Cleanup: intermediate MKV deleted after `Transcoder` consumes it (or on
  cancel, via `ActiveProcesses`).

#### 11f. Validate on real drops
- Bulk-apply: drop a 12-episode pack with 5 audio + 6 sub each; deselect
  4 audio + 4 subs on episode 1; confirm popover → click "Apply"; verify
  episodes 2-12 reflect the change; verify lang+codec matching (don't accept
  index-based propagation).
- External: drop JJK S3. 2 dubs + 1 sub selected. iPad audio switcher shows
  JP + 2 RU studios with correct labels; subtitle switcher shows selected
  RU sub; episode 8 missing from video reported skipped, no crash.
- Regression: a normal single-audio MKV (no extras, no cluster) still syncs
  unchanged.

**Out of scope (defer, link back here when pulled).**
- Cluster preferences persisted across launches.
- Hardsub mode for ASS (separate ffmpeg path; breaks HEVC copy).
- Auto-selecting "best" dub (subjective).
- Downloading missing tracks from external sources.
- Bulk-apply across different clusters in one drop.

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
