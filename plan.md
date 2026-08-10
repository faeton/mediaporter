# MediaPorter Roadmap

Living plan. Items move up as priorities change. Engineering checklist for the
MacApp + Python reference. Source of truth for "what's next".

---

## Readiness snapshot — 2026-07-26

Shipped: **0.8.0 + 0.8.1** (both tagged 2026-06-08). 0.8.0 headlined Wi-Fi
sync + multi-device USB/Wi-Fi picker + the A-series reliability/perf closes
(A2, A5–A9); 0.8.1 added audio loudnorm, the pre-Send "≈ N GB" estimate, and
clearer Wi-Fi failure messaging. Working tree clean, 75/75 unit tests green,
smoke-test PASS on akm16pro over both USB and Wi-Fi.

**Shipped since 0.8.1 (unreleased):** ✅ file list follows the active job
during a run (652a0f6, 2026-07-23) — in CHANGELOG under Unreleased.

**Open items:** **P3 #15** (expert ffmpeg flags — deliberately HELD) and the
fresh **B-series audit** (2026-07-26, below): B2 dlopen `fatalError` and B1
device-data force-unwraps are the two worth pulling first (consultant
consensus: B2 ≥ B1; suggested 0.8.2 scope at the end of the B-series). A-series "(orig)"
sections are historical records, not open work.

**0.8.2 shipped 2026-07-26. 0.9.0 shipped 2026-08-10** (large-batch sync,
folder-titled episodes, transcode reuse, TMDb match ranking). Next release:
cut a patch when enough QoL accumulates, or 0.10.0 on a feature headline.

**Carried into the next cycle, from the 0.9.0 work:**
- **Chunked sync sessions** — now known to be a UX improvement only, not a
  correctness requirement (the expiry clock counts silence, not elapsed
  time — CLAUDE.md #16, HISTORY 2026-08-10). Value: bytes start moving
  before the whole batch has encoded, and an interruption costs one chunk
  instead of the run. Needs verify+heal between chunks, since more sessions
  means more poison surface.
- **Heal can't touch the worst case** — `StuckAssetLedger` deliberately
  refuses to delete *bound* rows, but the ack-window failure produces
  exactly that: a bound, playable row that stays pending and blocks
  `SyncFinished` on every later sync. Rows the current run just created
  have stronger provenance than arbitrary bound rows, so rolling those back
  is defensible where a blanket rule isn't.
- **Re-measure the expiry thresholds over Wi-Fi.** Every number we have is
  USB, one device, one fixture per point.

---

## P0 — Ship now (small, isolated, high impact)

### 1. Episode-still artwork bug *(shipped)*
- `MetadataLookup.swift:20` now returns `e.posterData ?? e.showPosterData`
  (per-episode still wins) for the device-bound `posterData` path. The
  separate `tagPosterData` accessor (`:34`) intentionally keeps the show
  portrait for the embedded MP4 atom. Show-portrait-specific reads
  (`showPosterData` at `:50`, episode still at `:56`) are isolated accessors,
  so the flip didn't regress the two-artwork sync.
- Mirrors Python's `src/mediaporter/metadata.py:175`
  (`poster_url=ep_still_url or show_poster_url`).

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
- ✅ **VERIFIED 2026-06-08.** Synced the synthetic `Mediaporter.Alpha.S01E01`
  fixture (no TMDb match → no still, and its test-pattern frames aren't
  extractable) to akm16pro: the poster resolver took the
  **synthetic-landscape** branch, generated a 37 KB 1280×720 poster, stamped the
  S01E01 badge, and uploaded it on a clean sync. Branch logging added to
  `resolveEpisodePoster` (`poster.episode` tag) so the chosen fallback is now
  observable in `/tmp/mediaporter-debug.log`. Covers both the
  episode-without-TMDb-still and no-API-key cases (same code path).

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
opens the session before the upload loop and calls `registerFile` from
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

**Amended 2026-08-03.** "Before the upload loop" now means *after every
transcode finishes*, not before ffmpeg starts. Announced assets expire in
under a minute of post-manifest idle (idle 0 s binds, 60 s does not — see
HISTORY.md "2026-08-03" and CLAUDE.md #16), so holding the session open
across a multi-minute encode killed the whole batch. The interleave gain
this item shipped is unaffected: it came from per-file FileComplete
replacing the end-of-run register burst, not from overlapping ffmpeg with
the session. Open question for large batches: one session per ready file
would let episode 1 land without waiting on episode 20's encode, at the
cost of N handshakes/anchors. Grok's review (2026-08-05) preferred chunked
sessions (3–5 files each, opened once that chunk is encoded) over per-file
if the wait ever becomes the complaint.

**Detection + self-heal shipped 2026-08-05.** Because the wire accepts
every message whether or not the asset is still live, the failure was
invisible until a user found an unplayable row. Now: `atc.FileBegin` logs
`manifestAge=` (`.error` past 25 s / 45 s) and `pipeline.preflight` records
session/drainer/age before the first byte; `pipeline.verify` reads every
shipped row back by `item_store.sync_id` after `finish()` and marks
unbound ones failed; those rows are `delete_track`-ed immediately;
`StuckAssetLedger` + `healStuckAssets` clear assets a prior `FileError(0)`
failed on, gated on seen-twice + not-ours + row-exists + row-unbound.
CLI: `mediaporterctl heal [--dry-run]`, `mediaporterctl verify <syncID>…`.

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

### 12. Recommendation rework ✅ DONE 2026-06-08
- Default on-device-display framing kept; Settings toggle "I AirPlay/cast to a
  4K display" flips the banner to keep-originals copy
  (`DeviceColumnView.swift::recommendationCopy`, `pipeline.airplayTo4K`).
  Storage-aware banner shipped in 0.6.0.
- ✅ **DONE 2026-06-08.** Source bitrate shows in the per-file row
  (`FileRowView` — `fmtBitrate(job.mediaInfo.bitRate)`, was already wired), and
  the recommendation banner (`DeviceColumnView.recommendationCopy`) now appends
  "These files run ~N Mbps at full resolution" — the measured average across
  incoming jobs — when a downscale is on the table. The concrete "why downscale"
  signal.

### 13. Zombie ffmpeg sweep at launch *(shipped 0.6.0)*
- `ZombieSweep.sweep()` runs at launch (`App.swift:138`,
  `Sources/Transcode/ZombieSweep.swift`): SIGKILLs orphan ffmpeg processes whose
  command line references the app's temp prefix. Recovers from a prior
  SIGKILL/panic that bypassed `ActiveProcesses.cancelAll()`.


---

## P3 — QoL features (pull when an item bites)

10. ✅ **DONE.** Manual metadata override in the file row (title / year / SxxEyy)
    — `EditTitleSheet` (movies) / cluster show-picker (TV), already shipped.
11. ✅ **DONE 2026-06-08.** Pre-Send size estimate — the Send button now shows
    "≈ N GB to send" (sum of `estimateOutputBytes` over eligible jobs); the
    per-resolution picker already showed the per-file "≈".
12. ✅ **DONE.** Forced-subtitle flag in the per-file details — `FileRowView`
    `subtitleDispositionTags` surfaces "forced" / "SDH" / "default", already shipped.
13. ✅ **DONE 2026-06-08.** Audio loudnorm checkbox — Settings → Transcode
    "Normalize audio loudness (EBU R128)" (`PipelineController.normalizeLoudness`,
    persisted). Applies the ffmpeg `loudnorm` filter per-stream, only to
    re-encoded audio (copied tracks keep their levels). Verified the filter
    coexists with our aac/`-ac`/`-disposition:a default` flags without breaking
    the audio-switcher rule (CLAUDE.md #10).
14. ✅ **DONE** (36df5c6). Multi-device picker in DeviceColumn with USB/Wi-Fi
    transport badges.
15. **HELD — not shipped.** Expert-mode custom ffmpeg flags in Settings.
    Deliberately deferred: arbitrary user flags can silently override the
    documented safety-critical args (audio-switcher disposition #10, `-tag:v
    hvc1` / `-f mp4` #11) and produce broken syncs that are painful to
    diagnose. Lowest value of the P3 set, highest blast radius, no concrete
    demand yet. Revisit only with a clear use case + a guard that protects the
    critical flags.

---

## Audit findings — 2026-05-14 (untriaged)

Code-review pass against the shipping 0.6.0 codebase. Each item lists severity, file:line refs, root cause, and a fix sketch. Items aren't prioritized yet — promote into P0/P1 as you tackle them; close with a `*(shipped)*` line like the rest of the doc.

### A0. Wrong insert_track key placement for TV episodes — **High** *(shipped 2026-05-15)*
- Originally `Sources/Sync/ATCSession.swift` sent `tv_show_name` / `sort_tv_show_name` / `episode_number` at top-level of the `item` sub-dict. None of those keys exist anywhere in AMPDevicesAgent's parser. The first migration (2026-05-14) renamed them to `series_name` / `sort_series_name` / `episode` — still at item top-level. Live device DB confirmed those ALSO didn't populate (`item_artist.series_name` stayed empty for Chernobyl, The Bear, Succession, Veep across three sync attempts).
- **Root cause** (2026-05-15, via AMPDevicesAgent strings cluster at 0x784603-0x784711, decoded by walking the string table by offset): the accepted insert_track key-cluster for `video_info` sub-dict is `has_alternate_audio`, `has_subtitles`, `characteristics_valid`, `is_hd`, `season_number`, `series_name`, `sort_series_name`, `episode_id`, `episode_sort_id`, `network_name`, `extended_content_rating`, `movie_info`. **These live in `video_info`, not item top-level.** Kebab `show-name` / `season-number` / `episode-number` exist at strings 0x770800 but are iTunes Store metadata keys (different code path — parsed when downloading purchased content), so sending them in our ATC plist did nothing.
- **`episode_sort_id`** is in two places now: video_info cluster (legacy schema) AND `item` table top-level (current iOS — column migrated). We send it in both spots.
- **Verified via Fleabag S01E02 drop**: `item_artist.series_name="Fleabag"`, `album.season_number=1`, `item_video.season_number=1`, `item_video.episode_id="S01E02"`, `item.episode_sort_id=2`. TV.app shows "Fleabag" header + "Season 1" + "Episode 2" titled row.
- **Follow-up secondary fields worth adding** (in AMPDevicesAgent insert_track cluster, not yet sent):
  - `description` / `description_long` — TMDb episode overview row on show-detail.
  - `network_name` — TMDb show network ("HBO", "BBC One", etc.).
  - `extended_content_rating` — TMDb content rating ("TV-MA", "TV-14").
  These need TMDb plumbing (we don't currently pull overview/network/rating into `EpisodeMetadata`).
- **Remaining show-detail bug**: big portrait poster slot shows the landscape episode still, not the show portrait. This is separate — needs `insert_album` + Airlock Album-class artwork upload to populate `album.artwork_token`. Track-class artwork (what we send now) only drives episode-row thumbs.

### A1. AFC upload silently accepts a truncated local read — **High** *(shipped 0.7.0)*
- Closed by the post-write verification path: `AFCUploader.upload` re-stats the
  remote file after the AFC write and throws `AFCError.sizeMismatch` if the
  device-reported size ≠ local file size (`AFC.swift:170` adds
  `AFCError.readFailed` for local read errors; `:10` adds `.sizeMismatch`). The
  pipeline catches both and emits `FileError(0)` for the asset, so a truncated
  upload can no longer bind a partial row. Detail: CHANGELOG 0.7.0 "Unbound row
  → swept file". The original mid-loop `break` still logs `"TRUNCATED"` at
  `:149` but the post-write stat now backstops it.

### A2. ATC send failures swallowed by `check()` — ✅ RESOLVED 2026-06-07 (1810ae0)
- The fix keys on the DRAINER's liveness signal, not the send rc — Phase-2
  telemetry (438eeb5, since removed) proved rc is meaningless here: must-ack
  sends return wild nonzero rc (MetadataSyncFinished `0xf69a43c0`, Pong `1`) on
  perfectly successful syncs, so the originally-planned "throw on rc != 0" would
  have aborted every sync.
- `connectionDead` (guarded by `inboxLock`, reset per session) is set by the
  drainer when its blocking read returns nil for an UNEXPECTED reason
  (transport error / peer death, distinguished from our own `stopDrainer`).
  `checkOrThrow` throws `SyncError.connectionLost` when the flag is set; the
  must-ack sends (`FileBegin`/`FileComplete`/`MetadataSyncFinished`) use it, so a
  dropped connection aborts at the next send instead of the 120s `finishSync`
  deadline (which also short-circuits on death). Heartbeats stay on `check()`.
- Verified: Wi-Fi smoke-test still passes with zero false aborts.

### A3. Off-by-one in `registeredCount` skips abandon for in-flight failures — **High** *(mitigated 0.7.0; structural fix deferred)*
- The acute failure mode (detached task throws between `FileBegin` and
  `FileComplete` → asset never abandoned → `SyncFinished` blocks forever) is now
  covered: the detached task's catch path sends `FileError(0)` for its own asset
  (commit c73e141, `PipelineController.swift:1964–2031`), and the graceful-cancel
  flush drains pending abandons through a short-deadline `finishSync` (0.7.0).
- **Remaining (Low)**: the `registeredCount = idx + 1` bookkeeping at `:2103`
  was never renamed to the cleaner `dispatchedCount` / `completedCount` split.
  Functionally redundant now that each task self-abandons, but the variable
  still reads as an off-by-one trap for the next editor. Cosmetic cleanup.

### A4. ExternalMux deadlock on stderr-heavy ffmpeg runs — **High** *(shipped 0.6.2)*
- Fixed exactly as sketched: `ExternalMux.mux` now installs a `readabilityHandler`
  on `errPipe.fileHandleForReading` before `proc.run()`, accumulates into a
  `StderrTail` (last ~8 KB), resolves via a `terminationHandler`-driven
  continuation (not `waitUntilExit`), clears the handler, then drains the
  remainder (`ExternalMux.swift:212–236`). Same pattern as `Transcoder`'s main
  path. CHANGELOG 0.6.2 "External-mux failure tail".

### A5. probeFile blocks a cooperative-pool thread (not MainActor) — ✅ RESOLVED 2026-06-07 (f7c5c28)
Fixed via option (a): the blocking `Process.run`/read/`waitUntilExit` runs in
`Task.detached(.utility)`, off the cooperative pool. Added a lock-guarded
`ProbeProcessBox` + `withTaskCancellationHandler` so a cancelled analyze
terminates the ffprobe child (the CLAUDE.md #12 contract), which the old inline
form never did either. *(original finding below)*

### A5 (orig). probeFile blocks a cooperative-pool thread (not MainActor) — **Medium** *(historical — resolved above)*
- `Sources/Analysis/Probe.swift:126`. Still synchronous `proc.run()` + `readDataToEndOfFile()` (`:145`) + `waitUntilExit()` (`:146`). Called from `PipelineController.analyzeOne` (`PipelineController.swift:989`) which is `@MainActor`-isolated; called concurrently up to 4× by the TaskGroup at 956.
- Important correction to the original finding's framing: `probeFile` is a *nonisolated* `async` function. Swift 5.7+ hops nonisolated async calls off the caller's actor onto the generic cooperative executor. So UI does **not** freeze. What suffers: 4 concurrent probes each pin a cooperative-pool worker (pool size ≈ `activeProcessorCount`). On a quad-core MBA that's all of them; other concurrency (TMDb fetches, OpenSubtitles, file scanning) gets queued behind them.
- Consequence: parallel analyze is parallel, but during the probe window other async work in the app stalls. Not catastrophic — the analyze wave already coalesces network work via `resolveCluster` caching.
- Fix options: (a) wrap probe body in `Task.detached { … }.value` so blocking lives outside the cooperative pool, (b) switch to async pipe reading via `DispatchSource.makeReadSource(fileDescriptor:queue:)` or `for try await line in handle.bytes.lines`. Option (a) is one-line and good enough; (b) is correct but invasive. Same pattern recurs in: `Tagger`, `StillExtractor`, anywhere we use Process synchronously.

### A6. VideoToolbox detection runs a subprocess per transcode — ✅ RESOLVED 2026-06-07 (b2f131f)
`Transcoder.videoToolboxAvailable()` now memoizes behind `vtCacheLock`/`vtCache`
— one probe per app run. *(original finding below)*

### A6 (orig). VideoToolbox detection runs a subprocess per transcode — **Medium** *(historical — resolved above)*
- `Sources/Transcode/Transcoder.swift:126` (definition), was called inside the per-transcode hot path without caching.
- Consequence: every file pays ~50–150 ms + a stderr-free Process for a fact that never changes per app run.
- Fix: replace with `static let supportsVideoToolbox: Bool = detectVideoToolbox()` on `Transcoder` (or move into a launch-time capability struct alongside `FFmpegLocator`). One subprocess at first use, cached forever.

### A7. probeOutputForDebug unconditional per output file — ✅ RESOLVED 2026-06-07 (b2f131f)
`probeOutputForDebug` is now wrapped in `#if DEBUG` (`Transcoder.swift:~609`) —
release builds skip the per-output ffprobe entirely. *(original finding below)*

### A7 (orig). probeOutputForDebug unconditional per output file — **Medium** *(historical — resolved above)*
- `Sources/Transcode/Transcoder.swift` called `probeOutputForDebug(outputPath)` unconditionally after every successful transcode.
- Fix applied: gated behind `#if DEBUG`.

### A8. Disk preflight is over-conservative for the streaming pipeline — ✅ RESOLVED 2026-06-07 (f7c5c28)
Split the preflight by surface. **Key correction to the original framing:** the
Mac does NOT keep ~1 output in flight — `cleanupTempOutputs` only deletes temp
`.m4v` files once *every* job is `.synced` (no per-file delete in the upload
loop, transcode lookahead has no upload backpressure), so all outputs coexist
for the whole run. So the Mac figure is a *sum*, not largest-single:
`Σ(source × 1.1)` over transcode/remux jobs + mux-sidecar bytes + one
largest-source reserve, with copy-only jobs excluded (they stream from the
source, zero temp — the real over-rejection fix). Device = `Σ(predicted output)
× 1.05` over all jobs (downscale/HEVC/AC3→AAC shrink it; backstopped by the
upload loop's per-file device poll). codex+grok caught the copy-only over-count
and the mux-scratch gap; both folded in. *(original finding below)*

### A8 (orig). Disk preflight is over-conservative for the streaming pipeline — **Medium (Mac side); spec-debate (device side)** *(historical — resolved above)*
- `Sources/Pipeline/PipelineStats.swift:129` still computes `required = sourceBytesTotal × 1.1` for both Mac temp and the device; no `predictedOutputBytes` field yet.
- Mac side is over-conservative: `runPipelined` keeps ~1 transcoded output in flight at a time. The real requirement is `largest_single_output × 1.1 + headroom`, not the sum. Big drops (50+ files) can be rejected even when the pipeline would happily stream through with ~10 GB of free temp.
- Device side is more subtle. The actual need is sum of *output* bytes, not source — and outputs often shrink after downscale / H.265 / AC3→AAC. But output size isn't known until after `evaluateCompatibility` per file. Today's 1.1×source is the safe pessimistic bound. Better: after analyze, sum `decision.predictedOutputBytes` (add field if missing) and use that × 1.05 as the device-side check.
- Fix: split the preflight. Mac check on the largest source file; device check on sum of predicted outputs. Don't ship until you've cross-checked predicted vs actual on a real batch — under-estimating bites mid-sync.

### A9. SwiftUI recomputes `clusterExtrasOrdered` every progress tick — ✅ RESOLVED 2026-06-07 (f7c5c28)
Cached in `@State`, recomputed via `.onChange(of: clusterExtrasKey, initial:
true)`. The key is a content fingerprint (per-cluster hash of id + show name +
sorted dub/sub ids, the array sorted then hashed) — order-independent, no
XOR-linear collisions, and never stale on a re-cluster / show-rename, which a
count-only key missed (user-reachable via the show picker — codex+grok flagged
it). *(original finding below)*

### A9 (orig). SwiftUI recomputes `clusterExtrasOrdered` every progress tick — **Low** *(historical — resolved above)*
- `App/Sources/ContentView.swift:27` is still a computed property on the view, re-invoked from `body` (`:157`) on every `@Observable` tick. Not cached on the controller. SwiftUI re-invokes body on every `@Observable` change — `job.progress` ticks every 0.25 s during transcode/upload.
- Small N: invisible. Large drop (50+ jobs, 8+ clusters): noticeable CPU during sync, plus more invalidations downstream than necessary.
- Fix: cache the ordered list on the controller as `@Published var clusterExtrasOrdered: [(String, ReleaseExtras)]`, recompute only when `clusterExtras` / `jobs.count` / `tvShowResolutions` change. Or use `@State` on the view + `.onChange(of:)` of a stable derived key.

### Cross-refs to existing plan items
- **A5** is a refinement on shipped **P1.10 Parallel analyze** — the wave model works, but the worker still blocks a thread.
- **A4** *(shipped 0.6.2)* landed on **P2.11e Pipeline integration — mux step**.
- **A3** *(mitigated 0.7.0)* landed on **P1.8 Interleave registration with uploads** — only the cosmetic `registeredCount` rename remains.
- **A8** revisits the 0.5.0 preflight (mentioned in `project_macapp_next_phases` memory).
- **A2** is the last open protocol-correctness gap below the P-tier abstraction layer; it surfaces as the rare "stuck SyncFinished" failure mode (**A1** now closed by the post-write size verify).

### Suggested triage order if grouped *(updated 2026-06-07)*
**All A-series items resolved.** Audit-era closes: **A1** (post-write size
verify), **A3** (per-task self-abandon), **A4** (stderr drainer). 2026-06-07:
**A2** (1810ae0), **A6/A7** (b2f131f), **A5/A8/A9** (f7c5c28). Nothing left in
this tier; open audit work now lives in the **B-series (2026-07-26)** below.

---

## Audit findings — 2026-07-26 (untriaged)

Code-review sweep against the post-0.8.1 tree (652a0f6). No TODO/FIXME markers
exist in the codebase; these are latent robustness/hygiene items. Promote into
P-tier as they bite; close with a `*(shipped)*` line.

### B1. Force-unwraps on device-supplied data in the ATC path — ✅ SHIPPED 2026-07-26
Guarded `Int(anchorStr)` at all four sites (throws `SyncError.protocolError`);
all ~13 `messageCreate!` sites now go through `sendMsg`/`sendMsgOrThrow`
helpers; `try!` plist serialization → throwing builders (tests updated);
`as! Int` file-size cast guarded. *(original finding below)*

### B1 (orig). Force-unwraps on device-supplied data in the ATC path — **High** *(historical — resolved above)*
- `SyncEngine.swift:133/:216/:338` — `Int(anchorStr)!` where `anchorStr` comes
  from the device's `DataclassAnchors["Media"]` CFString. A non-numeric/empty
  anchor hard-crashes mid-sync instead of throwing `SyncError`. Same pattern in
  `GateTest.swift:172-173`.
- `ATCSession.swift:143` + ~12 more sites — `ATH.messageCreate(...)!`
  force-unwraps a private-framework return; nil ⇒ crash instead of
  `handshakeFailed`.
- `ATCSession.swift:334/:361` — `try! PropertyListSerialization.data(...)` on a
  throwing path; `AFC.swift:142` — `as! Int` on a file attribute.
- Fix: convert to guarded throws (`SyncError.protocolError`). Mechanical; the
  call sites are already inside throwing functions.

### B2. `dlopen`/`dlsym` failures crash the GUI (`fatalError`) — ✅ SHIPPED 2026-07-26
Handles are now thread-safe lazy `Result` globals; `preflightPrivateFrameworks()`
dlopens all three libs + dlsyms every table symbol. GUI checks at launch:
compatibility alert + Bugsink event + device features disabled (local
analyze/transcode still works); CLI exits 3 with a clear message. The loader
`fatalError`s remain only as unreachable backstops. *(original finding below)*

### B2 (orig). `dlopen`/`dlsym` failures crash the GUI (`fatalError`) — **High** *(historical — resolved above)*
- `Frameworks.swift:19/:42/:53/:56/:66` — missing `AirTrafficHost` on a future
  macOS, un-bundled `libcig.dylib`, or a renamed private symbol crashes at
  launch/first device touch. This is the most likely OS-upgrade failure mode and
  the one place a user-facing "MediaPorter isn't compatible with this macOS yet"
  alert would help most. Fix: make loaders throwing, surface an alert + Bugsink
  report.

### B3. Permanent stderr hijack kills crash diagnosability — ✅ SHIPPED 2026-07-26
stderr now redirects to `/tmp/mediaporter-stderr.log` (truncated per launch)
instead of `/dev/null` — framework spam stays out of the terminal but crash
reasons stay recoverable, and the file rides along in Send Diagnostic. CLI
user-facing errors write to the saved original stderr (`writeUserStderr`) so
they reach the terminal (they were silently swallowed before). The
`_md/_ath/_cig` double-dlopen race is closed by the lazy-global rewrite (B2).
*(original finding below)*

### B3 (orig). Permanent stderr hijack kills crash diagnosability — **Medium** *(historical — resolved above)*
- `Frameworks.swift:29 + :277-285` — `loadMobileDevice()` calls
  `suppressFrameworkStderr()`, `dup2`-ing fd 2 → `/dev/null` for the whole
  process; `restoreStderr()` (`:288`) is never called. After the first device
  touch, all Swift-runtime/crash output is lost. Also: `_md`/`_ath`/`_cig` are
  unsynchronized globals reachable from MainActor and detached uploaders —
  double-`dlopen` race. Fix: scope the redirect to framework calls (or restore
  after load) and guard the globals with a lock/`static let`.

### B4. Swallowed errors that silently degrade UX — **partially shipped 2026-07-26**
- ✅ **Duplicate detection** (shipped): a failed device-library pull now sets
  `PipelineController.duplicateCheckUnavailable` and the device column shows an
  amber "duplicate check is off for this batch" card, instead of the silent
  `?? []` that read as "nothing is a duplicate".
- ⏳ **Tagging** (deferred): `PipelineController.swift:~2420` `try? Tagger.tag`
  → unconditional `.ready` still ships an untagged file silently. Consensus:
  low priority — ATC artwork is independent of the MP4 atoms, so device
  artwork survives; wants a per-row "metadata not embedded" chip, don't fail
  the sync. Defer to a later patch.
- ⏳ **Subtitle cache write** (deferred): `OpenSubtitlesClient.swift:~299`
  silent drop — log-only fix, opportunistic.

### B5. Blocking sleeps on cooperative threads — **Low**
- `SyncEngine.swift:128/:210` POSIX `sleep(3…8)`; `ATCSession.swift:853`
  `Thread.sleep` in a 120 s poll loop. Both run in `Task.detached` contexts
  today, so impact is bounded; swap for `Task.sleep` when touching those files.

### B6. Dead/orphaned code + packaging hygiene — **partially shipped 2026-07-26**
- ✅ `Sync/PrivateFrameworks.h` — deleted (unreferenced, superseded by
  `Frameworks.swift` typealiases).
- ✅ `USBSpeed.swift` `usbSpeedLabel(mbps:)` — deleted (no callers).
- ⏳ `GateTest.swift`/`BenchUpload.swift` compile into the shipped GUI app but
  are reachable only from dev CLI subcommands; consider `#if DEBUG`/separate
  target. Deferred (packaging touch).
- ⏳ `scripts/make-icon.swift` vs `App/Sources/AppIcon.swift` — two drifting
  copies of the icon artwork; unify. Deferred.
- ⏳ Local-only cruft (gitignored, not in Package resources):
  `MediaPorter/Resources/grappa.bin`, `MacApp/Private/SyncAuthSeed.dat`, and
  multi-GB stale DMGs in `MacApp/build/` (release.sh only cleans the current
  version). Housekeeping — owner's call.
- ⏳ `Package.swift:40-44` — `MediaPorterCoreTests` is the only target without
  `.swiftLanguageMode(.v5)`: kept as the Swift-6 migration canary (consensus:
  fine as-is).

### B7. `DeviceCleanup.swift:24-35` binding-lag race — **documented, by design**
- The `item_extra.location=''` lag window is papered over by `pendingSlots`;
  underlying race unfixed by design. Keep the comment as the tracking record.

### B8. `finishSync` outcome is invisible to the caller — ✅ SHIPPED 2026-07-26
`finishSync` now returns `SyncFinishOutcome` (`finished`/`allowedFallback`/
`connectionLost`/`timeout`), threaded through `RegisterSession.finish`/
`finishGraceful`; `runPipelined` surfaces non-`finished` as "device didn't
confirm the final commit — check TV.app". *(original finding below)*

### B8 (orig). `finishSync` outcome is invisible to the caller — **High** *(historical — resolved above)*
- `ATCSession.finishSync` (`:808-858`) returns `Void` on every exit: real
  `SyncFinished`, the deliberate SyncAllowed-after-30s fallback, connection
  death, and the 120 s timeout all look identical to the pipeline, which then
  reports the run as a success (`PipelineController.swift:~2256`). The fallback
  itself is a documented escape hatch (fresh inbox drain + 30 s grace +
  `.notice`), NOT the old rule-#14 bug — but timeout/death exits deserve a
  distinct user-visible "sync may not have committed — check TV.app" state.
- Fix: return an enum (`finished` / `allowedFallback` / `connectionLost` /
  `timeout`), surface non-`finished` in the run summary.

### B9. `readMsg` abandons blocked readers that steal later messages — **High** *(codex, verified)*
- `ATCSession.swift:1086-1102` — on timeout, the global-queue
  `ATH.readMessage(c)` task is abandoned but stays blocked; when a message
  eventually arrives, the zombie reader consumes it instead of the drainer
  (the exact failure the drainer comment at `:878` warns about). Repeated
  timeouts stack multiple competing readers.
- Fix: single long-lived reader owned by the drainer; `readMsg` waits on the
  inbox instead of spawning its own read.

### B10. Handshake/manifest CF typing assumed, not checked — ✅ SHIPPED 2026-07-26
Handshake `DeviceInfo`/`Grappa`/anchor extraction now `CFGetTypeID`-guards
every device value before bridging (mistyped → `handshakeFailed`, not UB).
AssetManifest parsing already type-checked before bridging. *(original finding
below)*

### B10 (orig). Handshake/manifest CF typing assumed, not checked — **Medium** *(historical — resolved above)*
- `ATCSession.swift:153-171` assumed device params are
  `CFDictionary`/`CFData`/`CFString` without `CFGetTypeID` checks.

### B11. Drainer teardown races — **Medium** *(codex)*
- `drainerStop` read/written unsynchronized (`ATCSession.swift:872/:876/:892/:920`);
  `close()` invalidates/releases the connection without joining the blocking
  reader. Fix alongside B9's reader restructure.

### B12. `AFCConnectionSetSecureContext` failure logged but ignored — ✅ SHIPPED 2026-07-26
`AFCClient.init` now throws `AFCError.connectionFailed` when an SSL context
exists (Wi-Fi) and `afcSetSecureContext` returns nonzero — instead of
proceeding into the plaintext-into-SSL 60 s stall. Nil context (USB) still
no-ops.

### B13. Device-library sqlite3 pipe deadlock — ✅ SHIPPED 2026-07-26
All four `DeviceLibraryQuery` sqlite3 calls now go through a shared
`runSQLite3` helper that drains stdout to EOF BEFORE `waitUntilExit` (and
sets stdin to `/dev/null`), closing the >64 KB pipe-buffer deadlock per
CLAUDE.md #12.

### Consultant review (2026-07-26, codex + grok) — consensus priorities
Both agree B1/B2 lead, with reweights:
- **B2 ≥ B1** — the dlopen `fatalError` is the structural product risk (one
  macOS update can strand every user with a silent crash, and framework load
  actually happens at app-appearance via DeviceMonitor, before diagnostics
  init). B2 fix should also cover *lazy* `lookup` calls, not just `dlopen`,
  and preflight all symbols into one cached `Result` + a "not compatible with
  this macOS yet" alert + one Bugsink event (device features disabled, local
  transcode still usable).
- **B1 internal order**: `Int(anchorStr)!` and B10's CF-typing first (true
  device input), `as! Int` file-size cast next, `messageCreate!`/`try!` plist
  last (local data, fix for consistency).
- **B3 stderr promoted** — with no auto-crash SDK, the permanent fd-2 →
  `/dev/null` redirect guts the only support channel. Note (codex): a scoped
  save/restore does NOT work — later AFC traffic writes stderr too, and dup2
  is process-global; either rely on `AMDSetLogLevel(0)` alone, or drain a
  process-lifetime pipe to the saved stderr + a bounded file.
- **B4 dups > tagging > subtitle-cache** — silent duplicate rows in TV.app are
  the worst outcome (hard for users to clean). Tagging failure keeps device
  artwork (ATC artwork is independent of MP4 atoms) — chip, don't fail.
- **B5/B6 stay opportunistic**; test-target Swift-6 mode is a fine migration
  canary as-is.

**0.8.2 scope ("doesn't hard-crash on bad protocol / OS drift") — ✅ SHIPPED
2026-07-26 (unreleased):** B2 (throwing loaders + alert + Bugsink), B1+B10
device-input guards, B3 stderr redirect, B4 duplicate-detection banner, B8
outcome enum, B12 secure-context, B13 pipe drain, plus B6 dead-code deletions
(PrivateFrameworks.h, usbSpeedLabel). Build clean, 75/75 tests green.
**Still open:** B5 (blocking sleeps), B9/B11 (drainer/reader restructure —
bigger surgery, own change), B4-tagging/subtitle chips, B6 packaging
(GateTest/Bench `#if DEBUG`, icon unify, cruft cleanup).

**Original suggested scope (for reference):**
B2 (throwing loaders + alert + Bugsink), B1+B10 device-input guards, B3
stderr, B4 duplicate-detection banner, B8 outcome enum, B13 pipe drain.
Defer: B9/B11 reader restructure (bigger surgery — own change), B5, B6,
B4-tagging chip. Rough effort for the ship set: ~1–2 days.

---

## Release polish — untriaged (2026-05-14)

Cosmetic / packaging items captured against v0.6.1 shipping artifacts. Pull into the next release cycle.

### R1. DMG window cosmetics — pipeline shipped 2026-05-14 (cb1ad3b)

**Shipped.** `release.sh::build_dmg` now delegates to `MacApp/scripts/build-dmg.sh`:
UDRW image → mount → Finder AppleScript (icon view, 96-pt icons, 540×380
content area via outer bounds `{200,200,740,608}`, `.app` at `{136,185}`,
`Applications` at `{396,185}`, background = `MacApp/Resources/dmg-background.png`)
→ detach → UDZO convert. Mount-point parser switched from xmllint xpath to
grep-the-string because xmllint choked on Apple's plist namespace.

**Constraint discovered.** Finder DMG windows can't be locked from resize —
`resizable` is read-only on the Finder window class in AppleScript, no
`.DS_Store` flag honors it, AXResizable is r/o through System Events.
Accepted: every shipping Mac DMG installer has the same property.

### R1b. Final DMG background design — ✅ RESOLVED (superseded) 2026-06-08

**Outcome: no background.** The painted-background approach was abandoned —
`build-dmg.sh` ships an intentionally **plain** install window (icon view,
96-pt icons, `.app` at `{136,185}` + `Applications` at `{396,185}`, no
background image; see its header comment "No background — install window is
intentionally plain"). The AppleScript is the sole source of truth for icon
positions, which sidesteps the slot-alignment drift that made the placeholder
fragile. So there is nothing to redraw.

The orphaned placeholder `MacApp/Resources/dmg-background.png` (committed at
cb1ad3b, 1 MB, referenced by no script/Swift/plist after the plain-window
switch) was removed as cleanup. Recoverable from cb1ad3b if a branded
background is ever wanted again. *(R1's shipped-notes above still mention the
old background= arg; that arg is gone from the current build-dmg.sh.)*

### R2. `.app` filename inside the DMG should be `MediaPorter.app` regardless of variant — **Done 2026-05-14 (0.6.2)**

**Shipped.** Both DMG variants now contain `MediaPorter.app`; the DMG filename keeps `-with-ffmpeg` for download discoverability. Install shortcut and Spotlight see one canonical name. CHANGELOG 0.6.2 "In-DMG `.app` name".

### R3. Show "bundled vs system ffmpeg" inside the app, not in the DMG name — **Done 2026-05-14 (0.6.2)**

**Shipped.** Settings → FFmpeg source shows `.bundled` / `.system` / `.missing` with a stateful icon, the resolved ffmpeg path (monospaced, truncating middle), and a `How to install ffmpeg` link to porter.md/setup#ffmpeg when missing. CHANGELOG 0.6.2.

### R4. USB-speed hint when connection is below device capability — **Done 2026-05-14**

**Shipped.** `Sync/USBSpeed.swift` walks `IOUSBHostDevice` registry (public IOKit, no entitlements, no admin prompt), matches by USB Serial Number against the device UDID, reads the negotiated `Device Speed` code, and pairs it with a `productType → max-capability` table covering iPhone 15/16 Pro line (10 Gbps), iPad Air 4/5/M2 (10 Gbps), iPad mini 6 (5 Gbps), iPad Pro M1+ (Thunderbolt). `ConnectionCardView` in `DeviceColumnView.swift` shows the live negotiated speed (e.g. "USB 3 (10 Gbps) · Apple TV app") and a subtle amber bolt-badge icon with hover tooltip when the cable is bottlenecking a faster device. USB-C-but-USB-2 devices (iPhone 15/16 base/Plus, iPad 10th gen) correctly suppress the hint — the cable can't help.

---

## Future / Platform expansion — research notes (not committed)

Speculative work. Each item has a stated unknown that needs device verification before we'd commit engineering effort. Captured here so we don't redo the research.

### F1. Wi-Fi transport (USB-less sync) — ✅ SHIPPED 2026-06-07 (a18dcf9)

Full AFC+ATC sync works over Wi-Fi (USB unplugged), verified end-to-end via
`mediaporterctl smoke-test` (sync+verify+cleanup PASS) on akm16pro over **both**
Wi-Fi and USB with one unified code path.

**Root cause was a single API choice.** Enumeration + lockdown already worked
over Wi-Fi (`idevice_id -n`, `ideviceinfo -n`); the blocker was AFC. The legacy
`AMDeviceStartService` skips the SSL service handshake that network lockdown
sessions require → `0xE8000012` over Wi-Fi (works over USB). Proven the OS
supports AFC-over-Wi-Fi: libimobiledevice `afcclient -n ls /` lists the AFC root
over the same link.

**The fix (three-step secure path in `Sync/AFC.swift::AFCClient.init`):**
1. `AMDeviceSecureStartService("com.apple.afc")` — does the SSL handshake.
2. `AFCConnectionOpen` takes the service connection's **socket fd**
   (`AMDServiceConnectionGetSocket`), not the `AMDServiceConnectionRef` — passing
   the ref → AFC error 11 (service-not-connected) on the first file op. Matches
   `research/scripts/afc_plus_atc.py:153`.
3. `AFCConnectionSetSecureContext(conn, AMDServiceConnectionGetSecureIOContext(svc))`
   — routes AFC I/O through the SSL context. Without it, Wi-Fi I/O pushes
   plaintext into the SSL stream → 60s stalls/hangs. Over USB the context is nil
   → harmless no-op (plaintext), so one path serves both transports.

**Remaining polish (not blocking):**
- ✅ **UI hint removal + multi-device picker** (36df5c6). Per-device USB/Wi-Fi
  transport via `AMDeviceGetInterfaceType` (replaces the global
  `anyAppleMobileDeviceOnUSB` heuristic, now deleted); picker shows a transport
  badge; the wrong "Wi-Fi not supported" warning is gone; DeviceMonitor tracks
  transports per UDID (prefer USB, promote Wi-Fi on asymmetric detach).
- ✅ **Discovery timeout for Wi-Fi** (f7c5c28). `discoverDevice` default 5s→15s
  (Wi-Fi Bonjour re-announce regularly exceeds 5s; USB still fires on the first
  100ms poll so the ceiling is free), and it now returns the always-on
  DeviceMonitor's device the moment it appears mid-poll.
- ✅ **Throughput bench over Wi-Fi** (f7c5c28). `bench-upload` now reports the
  transport. Measured on akm16pro / 152 MB over Wi-Fi: **~56–63 MB/s** (1 MB
  chunk wins), *above* the old ~30 MB/s USB-2 baseline — Wi-Fi is not the
  bottleneck on this link. Large-file sync over Wi-Fi confirmed via smoke-test.
- ✅ **Device-sleep caveat** (shipped 0.8.1, 8f26f40): Wi-Fi drop failures now
  surface a user-facing hint (sleeping device stops advertising
  `_apple-mobdev2._tcp` and drops off within ~2 min; Auto-Lock Never isn't
  always enough).
- One-time `wifi-connections` enable (over USB) is the precondition for a device
  to advertise for network sync.

### F2. Apple Vision Pro support — researched 2026-05-14, conclusion: don't ship

Two independent load-bearing blockers.

**Blocker 1 — TV.app on visionOS has no synced-library concept.**
Apple Support docs + multiple Apple Discussions / MacRumors threads confirm: the visionOS TV app surfaces only iCloud-purchased content + iCloud downloads. No "From This Mac" library, no Finder sync UI, no documented import path. Even if our ATC writes succeed at medialibraryd, TV.app likely won't surface the rows. Apple's own thread "Transferring Movies from Mac TV app to Vision Pro TV app" closed unresolved; community workarounds are Files.app + iCloud + third-party players (Infuse, Moon Player) — no native Mac-sync path exists.

**Blocker 2 — transport story is unfavorable.**
- Vision Pro ↔ Mac default is Wi-Fi only. USB-C requires the $299 Developer Strap (gen1 USB 2.0 / 480 Mbps; gen2 released 2025-10 hits 20 Gbps but still niche). Assuming customers own the strap is unrealistic.
- Wi-Fi path inherits all of F1's unknowns plus a device-pairing flow with no public documentation on whether `usbmuxd`/`remoted` enumerate Vision Pro identically to iOS.
- pymobiledevice3 has no documented visionOS support — we'd be the first to map which lockdown services are exposed.

**Cheap discovery experiment, if we ever revisit.**
1. Plug Vision Pro via Developer Strap (or pair over Wi-Fi).
2. `pymobiledevice3 lockdown service-list` — does `com.apple.atc` appear? Does `com.apple.afc` mount the same `/iTunes_Control/...` paths?
3. If yes: try Grappa replay handshake. `ErrorCode 4/12` here = challenge changed per platform; `ErrorCode 0` = seed transfers.
4. If handshake works: send a single `MetadataSyncFinished` + `insert_track` + tiny file. Then check whether TV.app surfaces the row, or only Files.app sees the bytes.

Steps 1–3 are necessary preconditions; step 4 is the real question.

**Realistic ship path if demand emerges** is not ATC-based — it's a visionOS-native app that accepts files via Files.app sharing / AirDrop and plays them in-app (Infuse model). Different product, different binary, no shared code with the Mac sync engine.

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
