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

## Audit findings — 2026-05-14 (untriaged)

Code-review pass against the shipping 0.6.0 codebase. Each item lists severity, file:line refs, root cause, and a fix sketch. Items aren't prioritized yet — promote into P0/P1 as you tackle them; close with a `*(shipped)*` line like the rest of the doc.

### A1. AFC upload silently accepts a truncated local read — **High**
- `Sources/Sync/AFC.swift:102-117`. The `while sent < fileSize` loop reads from `InputStream`; on `read == 0` (EOF before fileSize) or `read < 0` (local read error) it just `break`s. After the loop it logs `"TRUNCATED"` but **returns success**.
- Consequence: caller sends `FileComplete` for an incomplete file. medialibraryd binds a partial row; on device the file is corrupt but the TV-app row exists — worst possible state for diagnostics.
- Fix: distinguish `read == 0` before EOF (truncation of local file mid-upload) vs `read < 0` (`stream.streamError`). Throw `AFCError.readFailed(sent, …)` / `AFCError.truncated(expected, got)`. Caller propagates → `runPipelined` abandons the asset.

### A2. ATC send failures swallowed by `check()` — **High**
- `Sources/Sync/ATCSession.swift:838`. `check(_ tag:, _ rc:)` only logs `rc != 0` and returns `rc`. Used by `beginFile` (567), `completeFile` (594, 603), `abandonAsset` (625), and others. These functions are marked `throws` but `check()` never throws.
- Consequence: if ATC connection dies mid-session (drainer-detected or transport-level), every subsequent send returns nonzero and gets logged-then-ignored. We keep uploading bytes over AFC, send `FileComplete` into the void, and only notice on `finishSync` timeout. Rows from after the drop are unbound.
- Fix: convert `check` for the `FileBegin`/`FileComplete`/`FileError`/`FileProgress` callsites into `try checkOrThrow(...) throws -> Void`. Other ATC sends (`PowerAssertion`, `MetadataSyncFinished`) where rc != 0 isn't necessarily fatal can keep the logging-only variant under a different name.

### A3. Off-by-one in `registeredCount` skips abandon for in-flight failures — **High**
- `Sources/Pipeline/PipelineController.swift:1626-1688`. `registeredCount = idx + 1` is set **immediately after** dispatching the detached task that does `beginFile` + AFC upload + `completeFile`. If that task fails between `FileBegin` and `FileComplete`, the cleanup loop `for i in registeredCount..<preparedPairs.count` skips this index — no `abandonAsset` is sent.
- Secondary: the status filter at 1684 (`!= .syncing && != .uploaded`) also excludes a job that *did* enter the loop range, so even reaching the abandon branch wouldn't fire for a freshly-failed in-flight upload.
- Consequence: device gets `FileBegin` without `FileComplete` and without `FileError`. medialibraryd waits forever; `SyncFinished` never arrives. Exactly the failure mode CLAUDE.md #8 warns against.
- Fix: rename to `dispatchedCount` and track a separate `completedCount` flipped from inside the detached task after `completeFile` returns. Cleanup loop iterates `dispatchedCount..<preparedPairs.count` to abandon never-started items, plus inspects each dispatched task's outcome to abandon any that failed mid-flight before `FileComplete`. Status filter needs to keep `.failed` / mid-flight jobs in scope.

### A4. ExternalMux deadlock on stderr-heavy ffmpeg runs — **High**
- `Sources/Transcode/ExternalMux.swift:158-174` (`mux`) and `:177-194` (`convertAssToSrt`). `errPipe` is a `Pipe`; `proc.run()` + `proc.waitUntilExit()` runs first, then `readDataToEndOfFile()` is called **after exit only on the failure path** (`guard … else { let data = … }`).
- macOS pipe buffer is ~64 KB. ffmpeg verbose stderr (especially with `-v info`, complex filtergraphs, ASS parse warnings) can fill this. Once full, ffmpeg blocks on write → `waitUntilExit` blocks → entire pipeline thread parks. Directly violates CLAUDE.md #12 ("drain stderr in a thread").
- Note about the "blocks UI" framing in the original finding: `mux` is a free `async throws` function, not `@MainActor`-isolated. Swift hops the await off MainActor onto the cooperative pool, so the main thread isn't pinned. What hangs is a cooperative-pool worker plus the upstream `Task` awaiting it — pipeline progress freezes, UI stays responsive.
- Fix: install `readabilityHandler` on `errPipe.fileHandleForReading` before `proc.run()`, append to a tail-only buffer (last ~8 KB), clear the handler after `waitUntilExit`, drain remainder. Pattern already used correctly in `Transcoder.swift` main path — copy it.

### A5. probeFile blocks a cooperative-pool thread (not MainActor) — **Medium**
- `Sources/Analysis/Probe.swift:126`. Synchronous `proc.run()` + `readDataToEndOfFile()` + `waitUntilExit()`. Called from `PipelineController.analyzeOne` (`PipelineController.swift:989`) which is `@MainActor`-isolated; called concurrently up to 4× by the TaskGroup at 956.
- Important correction to the original finding's framing: `probeFile` is a *nonisolated* `async` function. Swift 5.7+ hops nonisolated async calls off the caller's actor onto the generic cooperative executor. So UI does **not** freeze. What suffers: 4 concurrent probes each pin a cooperative-pool worker (pool size ≈ `activeProcessorCount`). On a quad-core MBA that's all of them; other concurrency (TMDb fetches, OpenSubtitles, file scanning) gets queued behind them.
- Consequence: parallel analyze is parallel, but during the probe window other async work in the app stalls. Not catastrophic — the analyze wave already coalesces network work via `resolveCluster` caching.
- Fix options: (a) wrap probe body in `Task.detached { … }.value` so blocking lives outside the cooperative pool, (b) switch to async pipe reading via `DispatchSource.makeReadSource(fileDescriptor:queue:)` or `for try await line in handle.bytes.lines`. Option (a) is one-line and good enough; (b) is correct but invasive. Same pattern recurs in: `Tagger`, `StillExtractor`, anywhere we use Process synchronously.

### A6. VideoToolbox detection runs a subprocess per transcode — **Medium**
- `Sources/Transcode/Transcoder.swift:126` (definition) and `:309` (`buildCommand`). `detectVideoToolbox()` shells out to `ffmpeg -encoders` and grep-parses the output. Called inside the hot path of every transcode.
- Consequence: every file pays ~50–150 ms + a stderr-free Process for a fact that never changes per app run.
- Fix: replace with `static let supportsVideoToolbox: Bool = detectVideoToolbox()` on `Transcoder` (or move into a launch-time capability struct alongside `FFmpegLocator`). One subprocess at first use, cached forever.

### A7. probeOutputForDebug unconditional per output file — **Medium**
- `Sources/Transcode/Transcoder.swift:565` calls `probeOutputForDebug(outputPath)` after every successful transcode; the function at `:570-591` shells out to ffprobe and writes per-stream lines to `DebugLog`. Comment at 561 calls it "temporary, for the binding bug" — that bug shipped in 0.6.0, this hasn't been retired.
- Fix: gate behind `Tweaks.debug` (or remove). Cheap, but visible per-file overhead and noise in the debug log.

### A8. Disk preflight is over-conservative for the streaming pipeline — **Medium (Mac side); spec-debate (device side)**
- `Sources/Pipeline/PipelineStats.swift:123-147` requires `1.1 × sourceBytesTotal` free on **both** Mac temp and the device.
- Mac side is over-conservative: `runPipelined` keeps ~1 transcoded output in flight at a time. The real requirement is `largest_single_output × 1.1 + headroom`, not the sum. Big drops (50+ files) can be rejected even when the pipeline would happily stream through with ~10 GB of free temp.
- Device side is more subtle. The actual need is sum of *output* bytes, not source — and outputs often shrink after downscale / H.265 / AC3→AAC. But output size isn't known until after `evaluateCompatibility` per file. Today's 1.1×source is the safe pessimistic bound. Better: after analyze, sum `decision.predictedOutputBytes` (add field if missing) and use that × 1.05 as the device-side check.
- Fix: split the preflight. Mac check on the largest source file; device check on sum of predicted outputs. Don't ship until you've cross-checked predicted vs actual on a real batch — under-estimating bites mid-sync.

### A9. SwiftUI recomputes `clusterExtrasOrdered` every progress tick — **Low**
- `App/Sources/ContentView.swift:21-33`. Computed property on the view referenced from `body`; filters `pipeline.clusterExtras`, lookups against `pipeline.tvShowResolutions`, sorts. SwiftUI re-invokes body on every `@Observable` change — `job.progress` ticks every 0.25 s during transcode/upload.
- Small N: invisible. Large drop (50+ jobs, 8+ clusters): noticeable CPU during sync, plus more invalidations downstream than necessary.
- Fix: cache the ordered list on the controller as `@Published var clusterExtrasOrdered: [(String, ReleaseExtras)]`, recompute only when `clusterExtras` / `jobs.count` / `tvShowResolutions` change. Or use `@State` on the view + `.onChange(of:)` of a stable derived key.

### Cross-refs to existing plan items
- **A5** is a refinement on shipped **P1.10 Parallel analyze** — the wave model works, but the worker still blocks a thread.
- **A4** lands on shipped **P2.11e Pipeline integration — mux step** — fix is small.
- **A3** lands on shipped **P1.8 Interleave registration with uploads** — the cancel-path cleanup needs a second pass.
- **A8** revisits the 0.5.0 preflight (mentioned in `project_macapp_next_phases` memory).
- **A1 / A2** are below the abstraction layer of any existing P-tier item; they're protocol-correctness gaps that surface as the rare "stuck SyncFinished" failure mode.

### Suggested triage order if grouped
1. **A1 + A2 + A3** as one session — all on the AFC/ATC reliability axis, all silent-failure modes that share testing infrastructure (force a mid-sync disconnect, observe that the device recovers).
2. **A4** standalone, ~30 min — copy the stderr drainer pattern from Transcoder.
3. **A6 + A7** as cleanup batch, ~15 min total.
4. **A5** when ready — wrap in `Task.detached`, validate analyze wall time on a 20-file drop doesn't regress.
5. **A8** after A5, since predicted-output-size requires the analyze decision to expose it.
6. **A9** only if a large drop measurably stalls during sync.

---

## Release polish — untriaged (2026-05-14)

Cosmetic / packaging items captured against v0.6.1 shipping artifacts. Pull into the next release cycle.

### R1. DMG window cosmetics — **Medium**

**Today.** `release.sh::build_dmg` produces a default Finder DMG: stock background, default icon layout, generic mini-arrow Finder icon in the titlebar. Reference: porter.md/release v0.6.1 screenshot 2026-05-14.

**Want.** A branded DMG window — background image with the porter.md mark + a positioned arrow from the `.app` icon to the `Applications` shortcut. Mirror Apple/Sketch/Transmission convention.

**How.** Either `create-dmg` (npm package, wraps `hdiutil` + AppleScript) or hand-roll AppleScript that runs after `hdiutil create` and before `hdiutil convert`. Background PNG should live at `MacApp/Resources/dmg-background.png` (or similar) and be referenced from release.sh. Brand assets in `brand/logo/` are SVG — pre-rasterize to PNG at 540×380 (standard DMG window size) + @2x.

### R2. `.app` filename inside the DMG should be `MediaPorter.app` regardless of variant — **High**

**Today.** `release.sh::build_dmg` does `ditto "$app" "$staging/$(basename "$app")"` — so the with-ffmpeg DMG shows `MediaPorter-with-ffmpeg.app` in the window. End-user-visible artifact name. The DMG filename can keep `-with-ffmpeg` for downloads, but the contained `.app` must be `MediaPorter.app` either way (otherwise the install shortcut copies an unusual name into /Applications).

**Fix.** One-liner — replace the basename call with the literal `MediaPorter.app`. Both variants ship the same Swift binary; the variant is fully captured by the presence/absence of `Contents/Helpers/ffmpeg`.

### R3. Show "bundled vs system ffmpeg" inside the app, not in the DMG name — **Low**

**Today.** Users see the variant in the DMG filename, but once `MediaPorter.app` is moved to /Applications that hint is gone. The `MissingFFmpegBanner` only surfaces when ffmpeg is *unavailable*.

**Want.** Surface the current `ffmpegSource` (`.bundled` / `.system` / `.missing`) in Settings → About or Settings → Diagnostics. Read off `Prerequisites.ffmpegSource`; the path resolution is already there. Free of code complexity — pure SwiftUI addition.

### R4. USB-speed hint when connection is below device capability — **Done 2026-05-14**

**Shipped.** `Sync/USBSpeed.swift` walks `IOUSBHostDevice` registry (public IOKit, no entitlements, no admin prompt), matches by USB Serial Number against the device UDID, reads the negotiated `Device Speed` code, and pairs it with a `productType → max-capability` table covering iPhone 15/16 Pro line (10 Gbps), iPad Air 4/5/M2 (10 Gbps), iPad mini 6 (5 Gbps), iPad Pro M1+ (Thunderbolt). `ConnectionCardView` in `DeviceColumnView.swift` shows the live negotiated speed (e.g. "USB 3 (10 Gbps) · Apple TV app") and a subtle amber bolt-badge icon with hover tooltip when the cable is bottlenecking a faster device. USB-C-but-USB-2 devices (iPhone 15/16 base/Plus, iPad 10th gen) correctly suppress the hint — the cable can't help.

---

## Future / Platform expansion — research notes (not committed)

Speculative work. Each item has a stated unknown that needs device verification before we'd commit engineering effort. Captured here so we don't redo the research.

### F1. Wi-Fi transport (USB-less sync)

**Today.** Sync path is USB → `usbmuxd` → `MobileDevice.framework` lockdown → `com.apple.atc`. Wi-Fi-paired devices are visible on the bus, but the session opener (`Sync/Frameworks.swift::AMDeviceConnect`) implicitly assumes USB.

**Hypothesis.** AMDevice handles Wi-Fi pairing transparently — same `AMDeviceConnect` / `AMDeviceStartService` calls should work if the device is Wi-Fi-paired. Throughput will drop (per-`FileProgress` ack RTT over Wi-Fi), but small files should complete.

**Unknowns to verify.**
- Whether `AirTrafficHost.framework` opens ATC channels the same way over Wi-Fi-only `AMDevice` handles.
- Real upload rate vs USB baseline (~30 MB/s today).
- Whether Ping/Pong keepalive cadence (CLAUDE.md #9) survives Wi-Fi jitter on long uploads.

**Why we're not doing it.** USB wins on every axis and porter.md customers have the cable. Pull only if a segment shifts (untethered shoot floor, etc.).

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
