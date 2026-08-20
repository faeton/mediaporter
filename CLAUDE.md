# mediaporter

macOS app: transfers video to iOS devices' TV app. Smart transcoding + ATC protocol sync. Ship target: Swift `MacApp/MediaPorter/`. `python-reference/` is frozen (protocol reference only). Distribution: signed + notarized DMG on porter.md.

## Critical rules

Non-obvious — each silently fails if broken. Trace evidence in `research/docs/HISTORY.md`.

1. **Never write `MediaLibrary.sqlitedb` directly** — medialibraryd reverts it within seconds. Use the ATC protocol (`com.apple.atc`).
2. **Grappa is replayable** — the 84-byte blob (`traces/grappa.bin` = go-tunes `deviceGrapa`) works across sessions. ErrorCodes: 12=no Grappa, 4=invalid, 23=wrong sequence.
3. **Wire names ≠ API names** — `MetadataSyncFinished` (wire) = `FinishedSyncingMetadata` (API). Anchor and AssetID are STRINGS, never ints.
4. **Sync plist is binary plist** (not XML): `/iTunes_Control/Sync/Media/Sync_NNNN.plist` + `.cig`.
5. **Movie/TV media-type**: `is_movie`/`is_tv_show: True` + `location.kind: "MPEG-4 video file"` in insert_track → `media_type=2048, media_kind=2, location_kind_id=4`. No Airlock staging.
6. **TV-episode keys** (canonical map = AMPDevicesAgent strings `0x784603-0x784711`):
   - In `video_info` sub-dict (snake_case): `series_name`, `sort_series_name`, `season_number`, `episode_id` ("S03E07" str), `episode_sort_id` (int).
   - In `item` sub-dict: `artist`/`album`/`album_artist` (+ sorts), AND `episode_sort_id` again at item-top-level (column moved video_info→item in current iOS).
   - Silently dropped: snake keys at item-top-level (except `episode_sort_id`); kebab `show-name`/`season-number` (those are iTunes Store path, strings `0x770800`). `tv_show_name`/`episode_number` do NOT exist.
   - Symptoms: missing `series_name`→blank TV.app header; `season_number`→"Season 0" card; `item.episode_sort_id`→"0." prefix on rows.
   - **`sort_album` must be the season number as a string** (`String(season)`), never the show name, and never zero-padded. medialibraryd resolves `item.album_order` from `sort_album` on the batch that CREATES the album, but from the item's own `video_info.season_number` on every later batch, and does not backfill — so a show synced in two sittings gets two `album_order` values and TV.app draws two "Season N" headers, each listing every episode. `album_order` is column 2 of the partial index `ItemSeries … WHERE in_my_library`. Every season of a show shares ONE album row (`item.album` = show name, no season suffix), so season separation rests entirely on `album_order` — which is why the old show-name key also collapsed two singly-synced seasons into one section. Keep `PipelineController.makeSyncItem` and `OrphanRecovery.makeSyncItem` identical here. Detect with `mediaporterctl heal`, which reports BOTH directions — one season spread over two `album_order`s (split), and two seasons sharing one (collapse, the shape the old show-name key produced when both arrived in one batch). Repair either by deleting the named rows and re-syncing them. See HISTORY.md "2026-08-14 — A season synced in two sittings".
7. **Send order**: `MetadataSyncFinished` BEFORE file upload — sending after a long upload times out the ATC session.
8. **Clear stale pending assets** — parse `AssetManifest`, send `FileError(ErrorCode=0)` for any AssetID not ours, or device blocks `SyncFinished` forever.
9. **Ping/Pong keepalive** — answer every `Ping` with a `Pong` during long ops or the session drops.
10. **AC3 dropped from iPad TV-app audio switcher** — transcode AC3→AAC, copy AAC/EAC3. Set `-disposition:a:0 default` + `-disposition:a:N 0` for N>0 (multiple defaults break the switcher). See `research/docs/AUDIO_SWITCHER_RULE.md`.
11. **ffmpeg .m4v needs `-f mp4`** — the `.m4v` extension picks the ipod muxer (no HEVC). HEVC copy also needs `-tag:v hvc1`.
12. **ffmpeg subprocess**: drain stderr in a thread (full pipe deadlocks); set stdin to `/dev/null` (else SIGTTIN freeze); register Process/Popen handles globally so Cancel reaches them.
13. **Artwork via Airlock** — poster JPEG → `/Airlock/Media/Artwork/<AssetID>` + `artwork_cache_id` in plist item dict.
14. **`SyncAllowed` ≠ `SyncFinished`** — `SyncAllowed` arrives early ("you may proceed") and accumulates in the drainer inbox. Only `SyncFinished` confirms the row is committed. Treating `SyncAllowed` as terminal → row with `base_location_id=0`, file GC-swept, TV.app shows title with no playable file. See HISTORY.md "2026-05-14 — SyncAllowed is NOT terminal".
15. **Wi-Fi AFC needs the secure-service path** — `AMDeviceSecureStartService` (NOT `AMDeviceStartService` → `0xE8000012` on network sessions), then `AFCConnectionOpen` on the service connection's **socket fd** via `AMDServiceConnectionGetSocket` (passing the `AMDServiceConnectionRef` instead → AFC error 11 on first file op), then `AFCConnectionSetSecureContext` with `AMDServiceConnectionGetSecureIOContext` (skipping it → plaintext into the SSL stream → 60 s Wi-Fi stalls). Over USB the secure context is nil → harmless no-op; one path serves both transports. See CHANGELOG 0.8.0 + plan.md F1.
16. **Announced assets expire on SILENCE, not on elapsed time. Never let an open session go quiet for ~25 s.** Assets listed in the sync plist die if the session stops exchanging messages. Two thresholds, measured 2026-08-05 (`idle-test`, one fixture, only the post-manifest idle varies):
    - **ack threshold ≈ (25 s, 30 s] of silence** — past it the device never sends `SyncFinished`. Rows still BIND and play, so the sync looks fine, but our own asset stays pending and blocks `SyncFinished` for every later sync. **This is the poisoning mechanism and it bites ~20 s before anything is visibly wrong.**
    - **bind threshold ≈ (45 s, 50 s] of silence** — past it the row lands UNBOUND (`base_location_id=0`, `location=''`), bytes GC-swept.

    Data: 0/15/20/25 s → BOUND + `SyncFinished`; 30/45 s → BOUND, no ack; 50/55/60/120/180 s → UNBOUND, no ack.

    **Corrected 2026-08-10 — the clock is idle time, NOT age since the manifest.** The original experiment varied dead air, so what it measured was how long the device tolerates *silence*; it was written up as an absolute delivery window, which is wrong. A 39-file / 73.6 GB run settled it: every file after the first began far past both thresholds measured from the manifest (file 2 at 72.6 s, file 39 at 371.3 s), yet **all 39 rows bound and `SyncFinished` arrived instantly**. The absolute-age reading predicts 38 failures; there were none. A session that keeps working — `FileBegin`, bytes, `FileProgress`, `FileComplete`, `Ping`/`Pong` — stays alive indefinitely.

    Consequences: a big single session is safe, so **chunking is a UX choice (earlier first byte, less lost on interruption), not a correctness requirement**. The full `readyGates` barrier before `RegisterSession.open` is still correct — it exists so an encode never stalls an *open* session — but it is not load-bearing for batch size. Dead assets stay pending on the device and block `SyncFinished` for **every later sync**; `FileError(0)` does NOT clear them, only `delete_track` on the row does. Re-measure with `mediaporterctl idle-test <file> --idle 0,60,120`. See HISTORY.md "2026-08-03" and "2026-08-10".

    **Detection + recovery** (all silent before — the wire accepts every message either way):
    - `atc.FileBegin` logs `idle=` and `manifestAge=` per file, at `.error` past `ATCSession.idleAckSeconds` (25 s) and again past `idleBindSeconds` (45 s). Thresholds compare against `lastActivityAt` (stamped on every send and read), never against `manifestReceivedAt` — an absolute-age check fires on every large batch and is pure noise. `pipeline.preflight` records session/drainer/idle before the first byte.
    - `pipeline.verify` reads every shipped row back by `item_store.sync_id` after `finish()` and reports BOUND / UNBOUND / NO ROW. Never infer bound-ness from the joined path: `base_location_id=0` is a real row with `path=''`, so `bl.path || '/' || e.location` yields `"//"`, not NULL. Check the columns (`DeleteCandidate.isBound`).
    - Unbound rows the run just created are `delete_track`-ed immediately (`pipeline.verify.cleanup`) and their jobs marked failed — otherwise they poison every later sync.
    - `StuckAssetLedger` remembers stale IDs across sessions; one that reappears after its `FileError(0)` is escalated to `delete_track` by `healStuckAssets` **before** the next `RegisterSession.open` (deletes need their own session). Gated: seen ≥2×, not ours, row exists, row unbound. Manual: `mediaporterctl heal [--dry-run]`, `mediaporterctl verify <syncID>…`.

## Design priorities

- **No admin prompts ever** — Swift app `dlopen`s Apple's `MobileDevice.framework` + `AirTrafficHost.framework` (talks to system `remoted`/`usbmuxd`): no sudo, helper, or `SMAppService` dialog. The `sudo pymobiledevice3 remote start-tunnel` step is python-reference only.
- **Notarization-friendly loading** — private frameworks are `dlopen`-ed at runtime, not linked (`Sync/Frameworks.swift`). Linking fails App Store review; `dlopen` passes notarization (malware scan, not API review).

## Dev setup

```bash
cd MacApp && swift build && .build/debug/MediaPorter
```

Needs `ffmpeg` on `$PATH` (`brew install ffmpeg`; release builds bundle it). Python reference: `cd python-reference && pip install -e ".[dev]" && mediaporter devices` — needs `sudo pymobiledevice3 remote start-tunnel` once per boot; MacApp does not.

## Code intelligence (codanna)

Optional but recommended for navigation. `codanna serve --watch` (user-scope MCP) re-indexes EDITS to known files automatically, but does NOT discover newly added files/dirs and does NOT full-scan on startup (verified codanna 0.9.22). So: `codanna init` once → `codanna index .` baseline → re-run `codanna index .` after ADDING/renaming/moving files. A local `.git/hooks/post-commit` runs `codanna index .` for you — set it up per clone (it's not tracked). `.codannaignore` is committed; `.codanna/` is gitignored (holds absolute machine paths). Treat any codanna "no results" as suspect — confirm with grep before assuming code is unused.

The `search_documents`/`semantic_search_docs` MCP tools need a separate **document collection** (markdown isn't covered by `codanna index .`). Set up per clone: `codanna documents add-collection research research/docs` + `codanna documents add-collection planning . --pattern "*.md"`, then `codanna documents index` (re-run after editing `.md` files). Config lands in gitignored `.codanna/settings.toml`.

## Where things live

- `MacApp/MediaPorter/` — Swift core: `Sync/` (ATC + AFC + framework loading), `Pipeline/`, `Transcode/`, `Analysis/`, `Metadata/`, `Tagger/`
- `MacApp/App/Sources/` — SwiftUI app target
- `MacApp/MediaPorter/Resources/` — `libcig.dylib` (arm64) + `SyncAuthSeed.dat` (XOR-masked 84-byte replay blob; un-masked in `Sync/Frameworks.swift::SyncAuthSeed`)
- `python-reference/` — frozen Python impl
- `scripts/cig/` — CIG source (`cig.cpp/.h`, `cig_wrapper.cpp`) + compiled `libcig.dylib` (arm64)
- `research/docs/` — protocol analysis, traces, history
- `site/` — porter.md (Astro); `brand/` — brand assets

## References

- Roadmap / next steps / audit → `plan.md`
- Shipped per version → `CHANGELOG.md`
- Sync wire detail + message dicts → `research/docs/ATC_SYNC_FLOW.md`, `research/docs/IMPLEMENTATION_GUIDE.md`
- Chronological findings → `research/docs/HISTORY.md`
- On-device test harness (screenshot + tap/Play a real iPhone to verify a sync) → `research/docs/IOS_TEST_HARNESS.md` + `scripts/ios/mp-ios.sh`
