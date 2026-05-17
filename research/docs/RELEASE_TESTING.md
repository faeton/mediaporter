# Release Testing

Pre-tag checklist for MediaPorter. Run both gates before cutting a notarized DMG.

## 1. Unit tests (no device)

```bash
cd MacApp
swift test
```

Expected: **71/71 passed in <100ms**. Highlights:

- `SyncPlistTests` (12) — pins CLAUDE.md rule #6 wire-key placement on
  `buildSyncPlist` and `buildDeletePlist`. Catches regressions where a
  TV-episode key slips into the wrong sub-dict (silent drop on device).
- `EpisodeArtworkTests` (6) — episode poster preference + landscape
  fallback.
- `ClusterSelectionCaptureTests` (3) — apply-to-all preservation across
  re-analyze.
- `CompatibilityTests` (18) — transcode decisions for codec/container
  combinations.
- `AudioClassifierTests` (9) — AC3/EAC3/AAC routing.
- `FilenameParserTests` (19) — title/year/season/episode extraction.
- `MetricsCollectorTests` (4) — run-stats accumulation.

These are correctness gates, not perf gates. They block tag if red.

## 2. Smoke test (device required)

Connect an iPhone or iPad with TV.app present, then:

```bash
cd MacApp
.build/debug/mediaporterctl smoke-test
```

What it does:

```
[1/3] sync         — runs full PipelineController on the bundled
                     Mediaporter.Alpha.S01E01.mp4 fixture (TV episode,
                     ~66 KB, no transcode needed).
[2/3] verify       — pulls MediaLibrary.sqlitedb (+ WAL/SHM), confirms
                     the row landed with base_location_id != 0 and the
                     MP4 is at the bound path.
[3/3] cleanup      — deletes via ATC delete_track + AFC remove,
                     re-queries to confirm row + file are gone.
```

Expected output ends with `✓ SMOKE TEST PASSED`. Exit 0.

Failure modes the smoke test catches:

- **Sync hangs / TLS handshake fails** → fails phase 1.
- **Row inserted but unbound** (e.g. `SyncAllowed` returned too early, the
  2026-05-14 regression) → fails phase 2 with "row unbound".
- **MP4 swept by background GC** (file uploaded but row never bound) →
  fails phase 2 with "MP4 missing on device".
- **delete_track resolves but file lingers** → fails phase 3.
- **Wire-key changes that pass unit tests but break on device** (e.g.
  iOS schema migration) → row appears with wrong title and the LIKE
  filter misses → fails phase 2 with "row not found".

Use `--keep` to leave the synced row on the device (manual inspection
in TV.app). Use `--fixture <path>` to point at a different MP4 (e.g.
a movie file to exercise the non-TV path).

```bash
.build/debug/mediaporterctl smoke-test --keep
.build/debug/mediaporterctl smoke-test --fixture /path/to/movie.mp4
```

## 3. Throughput sanity (optional)

If suspicious of AFC regression after changing AFC code:

```bash
.build/debug/mediaporterctl bench-upload <large_file> \
    --chunks 4M,16M --passes 2
```

Expected ~30–40 MB/s on Lightning, 100+ MB/s on USB-3. Big drop in
`>>> Winner` MB/s vs. the prior session is a red flag.

## 4. UI smoke (manual)

The CLI doesn't exercise the SwiftUI app. Before tag:

1. Launch `.build/debug/MediaPorter` (or the release `.app`).
2. Drop a TV episode and a movie onto the queue.
3. Confirm cluster picker shows for TV, dub/sub pickers populate.
4. Hit Send. Watch the progress bar reach 100%.
5. Open TV.app on the device. Episode in show; movie in Films.

If steps 3–5 pass, ship.

## Where this lives in CI

We don't have CI gating today — these are operator-run before
`git tag` / DMG sign. If you wire CI later, `swift test` is the only
piece that doesn't need a real device. The smoke test is the device-
attached gate that must run from the operator's machine.
