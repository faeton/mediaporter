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

### 2. ffmpeg still fallback for episodes
- When TMDb has no `still_path` (anime-only releases, obscure shows, no API
  key), today we drop to `PosterGenerator` synthetic portrait.
- Plan: extract a frame from the source.
  - Skip first 5% of duration (intro/black frames).
  - Sample 3 frames at distinct offsets (e.g. 5%, 35%, 65% of remaining).
  - Pick the brightest (avoids title cards, fades, transitional shots).
  - Output 1280×720 JPEG.
- Wire into `resolveTVEpisode` and `refreshEpisodes`
  (`PipelineController.swift`) before the synthetic generator.

### 3. Landscape synthetic fallback for TV episodes
- `PosterGenerator.generate` produces 500×750 portrait. Add 1280×720 landscape
  variant.
- Route TV-episode fallbacks (no TMDb match, no extractable frame) through
  landscape so text-only fallbacks aren't squished. Keep portrait for movies.

### 4. Test P0 end-to-end
- `swift build` clean.
- Sync 3 AoT episodes → distinct 16:9 stills in TV.app. **2026-05-10: confirmed
  per-episode tiles are now distinct.** Side-effect surfaced as P0.5 #6 below.
- Sync an episode TMDb has no still for → ffmpeg-extracted frame appears.
- Sync without TMDb API key → landscape synthetic fallback appears.

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

### 6. Show-level portrait artwork *(P0.5 — discovered after #1 ship)*
- After fixing per-episode stills, TV.app's show landing page on iOS picks
  one of those 16:9 stills as the show hero and letterboxes it into a 2:3
  portrait container — looks bad. Old behavior was the inverse trade
  (show hero looked OK, per-episode tiles all squished).
- Need *both* artworks to reach the device: per-episode landscape stills
  AND a show-level portrait. We currently upload one artwork per asset.
- Research before coding:
  - Inspect the iTunes/TV-app metadata schema (insert_track plist) for a
    `tv_show_artwork` / `is_show_artwork=1` flag, or a separate show-level
    record we can create.
  - Check go-tunes `deviceGrapa` traces for show-poster uploads.
  - Confirm whether Airlock supports a separate `/Airlock/Media/Artwork/<showID>`
    path that TV.app picks up implicitly.
- Until that's understood, don't iterate the synthetic copy.

### 7. Clear button after run *(shipped 2026-05-10)*
- `BatchTimelineView` showed Stop while active and nothing in the all-done
  state, so finished rows piled up and the next drag-drop grew the queue
  without bound. Wired the existing `PipelineController.clearCompleted()`
  to a Clear pill that replaces Stop when every job is `.synced`.

---

## P1 — Engine work (next, gated on each other)

### 8. Interleave registration with uploads
*(was #5 before P0.5 items landed; renumbered)*
- Today: `upload×N → register×1`. medialibraryd commits the whole batch on
  terminal `SyncFinished` (~30 s/file), seen as a long "finalizing" dead phase.
- Plan: open ATC session before uploads, receive `AssetManifest`, send each
  file's `FileBegin`/`FileComplete` the moment its AFC upload finishes.
- Touch points: split
  `MacApp/MediaPorter/Sources/Sync/SyncEngine.swift::registerUploadedFiles`
  into open / per-file / close; rework `PipelineController.runPipelined` to
  start the session before the upload loop.
- **Gating experiment first**: send one `FileComplete`, sleep 60 s, query
  `MediaLibrary.sqlitedb`. If row absent → medialibraryd still buffers until
  terminal `SyncFinished` → gain is zero → abort plan.
- Risk: Ping/Pong keepalive holds across multi-minute sessions (existing, but
  untested at that duration).
- Port to Python after Swift validation.

### 9. Mid-sync device-disk poll
- `checkDiskSpace()` preflight runs once at PipelineController.swift:1066.
  Nothing watches device free space during the AFC upload loop.
- Re-query `queryDeviceDiskSpace` once per file (or every Nth chunk) and abort
  cleanly with a "device filled up" status before AFC errors cryptically.
- Easier once #5 lands — already a per-file checkpoint.

### 10. Parallel analyze
- `analyzeAll` (PipelineController.swift:693) loops sequentially. Probe is
  I/O-bound, TMDb is network-bound. `TaskGroup` with concurrency ~4 cuts
  "Analyzing…" wall time on big drops.
- Hazard: cluster cache. N episodes of the same show must not fire N parallel
  TMDb searches.
- Two viable shapes:
  - (a) Two-pass: serially resolve unique clusters, then fan out per-file
    probes + episode lookups.
  - (b) Per-cluster `actor` so the first lookup populates the cache and
    subsequent lookups await it.

---

## P2 — UX polish

### 11. Recommendation rework
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

### 12. Zombie ffmpeg sweep at launch
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
