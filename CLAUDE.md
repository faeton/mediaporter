# mediaporter

macOS app for transferring video to iOS devices' TV app. Smart transcoding, ATC protocol sync. Shipping target: Swift MacApp (`MacApp/MediaPorter/`). Python under `python-reference/` is frozen — protocol reference only. Distribution: signed + notarized DMG on porter.md.

## Critical rules

Non-obvious — breaking any silently fails. Trace-level evidence in `research/docs/HISTORY.md`.

1. **Don't modify `MediaLibrary.sqlitedb` directly** — medialibraryd reverts within seconds. Use the ATC protocol (`com.apple.atc`).
2. **Grappa is replayable** — the 84-byte blob in `traces/grappa.bin` (= go-tunes `deviceGrapa`) works across sessions. ErrorCode 12 = no Grappa, 4 = invalid, 23 = wrong sequence.
3. **Wire names ≠ API names**. `MetadataSyncFinished` on the wire is `FinishedSyncingMetadata`. Anchor and AssetID are STRINGS, never ints.
4. **Sync plist is binary plist** (not XML) at `/iTunes_Control/Sync/Media/Sync_NNNN.plist` + `.cig`.
5. **Movie/TV media-type fields**: `is_movie: True` (or `is_tv_show: True`) + `location.kind: "MPEG-4 video file"` in insert_track → `media_type=2048, media_kind=2, location_kind_id=4`. Airlock staging not required.
6. **TV-episode wire keys live in `video_info` sub-dict, snake_case**: `series_name`, `sort_series_name`, `season_number`, `episode_id` ("S03E07" string), `episode_sort_id` (int). Plus `artist`/`album`/`album_artist` (+ sorts) in `item` sub-dict, AND `episode_sort_id` ALSO at item-top-level (column moved from video_info → item in current iOS). Empirics 2026-05-15: snake-case keys at item top-level → silently dropped. Kebab `show-name`/`season-number` in video_info → also dropped (kebab is iTunes Store metadata, different code path at strings 0x770800). Canonical insert_track key map is the AMPDevicesAgent strings cluster at 0x784603-0x784711. Missing `series_name` → TV.app header label blank. Missing `season_number` → "Season 0" card. Missing `item.episode_sort_id` → "0." prefix on episode rows. **`tv_show_name`/`episode_number` snake keys do NOT exist** — they're iTunes Store kebab `show-name`/`episode-number` (wrong code path); ignore any prior reference to them.
7. **Send order**: `MetadataSyncFinished` BEFORE file upload, not after. Sending after a long upload times out the ATC session.
8. **Clear stale pending assets** — parse `AssetManifest`, send `FileError(ErrorCode=0)` for any AssetID that isn't ours, or device blocks `SyncFinished` forever.
9. **Ping/Pong keepalive** during long ops — respond to every `Ping` with a `Pong` or the session drops.
10. **AC3 audio is dropped from iPad TV-app audio switcher** (not a uniformity rule). Transcode AC3→AAC, copy AAC/EAC3. Set `-disposition:a:0 default` + `-disposition:a:N 0` for N>0 (multiple defaults break the switcher entirely). Detail: `research/docs/AUDIO_SWITCHER_RULE.md`.
11. **ffmpeg .m4v output needs `-f mp4`** (the `.m4v` extension picks the ipod muxer which can't do HEVC). HEVC copy still needs `-tag:v hvc1`.
12. **ffmpeg subprocess gotchas**: drain stderr in a thread (full pipe deadlocks ffmpeg); set stdin to `/dev/null` (else SIGTTIN freezes); register Process / Popen handles globally so Cancel can reach them.
13. **Artwork via Airlock**: poster JPEG → `/Airlock/Media/Artwork/<AssetID>` + `artwork_cache_id` in plist item dict.
14. **`SyncAllowed` is NOT `SyncFinished`**. `SyncAllowed` arrives early (after MetadataSyncFinished / FileBegin) as "you may proceed" and accumulates in the drainer inbox during long uploads. Only `SyncFinished` confirms medialibraryd has committed the row. Treating `SyncAllowed` as terminal returns before the bind → row exists with `base_location_id=0`, file gets swept by background GC, TV.app shows the title with no playable file. Detail: `research/docs/HISTORY.md` "2026-05-14 — SyncAllowed is NOT terminal".

## References

- **Roadmap, next steps, audit findings** → `plan.md` (P0–P3 + untriaged)
- **What shipped per version** → `CHANGELOG.md`
- **Sync wire detail + message dicts** → `research/docs/ATC_SYNC_FLOW.md`, `research/docs/IMPLEMENTATION_GUIDE.md`
- **Chronological findings log** → `research/docs/HISTORY.md`
- **Audio switcher rule evidence** → `research/docs/AUDIO_SWITCHER_RULE.md`

## Design priorities

- **No admin prompts ever.** Swift app `dlopen`s Apple's `MobileDevice.framework` + `AirTrafficHost.framework` (talks to system `remoted`/`usbmuxd`) — no sudo, no helper install, no `SMAppService` dialog. The `sudo pymobiledevice3 remote start-tunnel` step is Python-reference-only (it reimplements the tunnel in userspace).
- **Notarization-friendly framework loading.** Private frameworks are `dlopen`-ed at runtime, not linked — see `MacApp/MediaPorter/Sources/Sync/Frameworks.swift`. Linking would fail App Store review; `dlopen` passes notarization (it's a malware scan, not API review).

## Dev setup

```bash
cd MacApp && swift build && .build/debug/MediaPorter
```

Requires `ffmpeg` on `$PATH` (`brew install ffmpeg`); release builds will bundle it. Python reference: `cd python-reference && pip install -e ".[dev]" && mediaporter devices` — needs `sudo pymobiledevice3 remote start-tunnel` once per boot, MacApp does not.

## Where things live

- `MacApp/MediaPorter/` — Swift core. Modules: `Sync/` (ATC + AFC + framework loading), `Pipeline/`, `Transcode/`, `Analysis/`, `Metadata/`, `Tagger/`
- `MacApp/App/Sources/` — SwiftUI app target
- `MacApp/MediaPorter/Resources/` — bundled `libcig.dylib` (arm64) + `SyncAuthSeed.dat` (XOR-masked 84-byte replay blob; un-masked in `Sync/Frameworks.swift::SyncAuthSeed`)
- `python-reference/` — frozen Python implementation
- `scripts/cig/` — CIG source (`cig.cpp/.h`, `cig_wrapper.cpp`) + compiled `libcig.dylib` (arm64)
- `research/docs/` — protocol analysis, traces, history
- `site/` — porter.md (Astro); `brand/` — brand assets
