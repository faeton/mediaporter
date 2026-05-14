# mediaporter

Transfer video files to iPhone and iPad over USB — no iTunes, no Finder, no cloud. Videos appear in the native Apple TV app with full metadata, artwork, and playback support.

An open-source alternative to iTunes/Finder video sync. Push any video from your Mac to your iOS device with automatic transcoding, metadata lookup, and native TV app integration.

## Two implementations

- **`MacApp/`** — Swift / SwiftUI desktop app. **This is the shipping target.** Drag-and-drop, smart transcoding, OpenSubtitles fetch, TV-series detection, device cleanup. Distributed signed and notarized from [porter.md](https://porter.md).
- **`python-reference/`** — the original Python CLI that proved the ATC protocol. Frozen reference for protocol details. Functional but no longer the active focus.

If you want to use the app, get it from porter.md. If you want to read the code to understand how iOS media sync actually works, both implementations are here and the wire-level docs live in `research/docs/`.

## What it does

1. **Analyze** — probes video streams, checks iOS codec compatibility
2. **Metadata** — looks up title, year, and poster art from TMDb
3. **Transcode** — converts to Apple-compatible format if needed (HEVC/H.264 via ffmpeg, with VideoToolbox hardware acceleration)
4. **Tag** — writes MP4 metadata atoms (title, artwork, HD flag, stik type, TV-episode fields)
5. **Sync** — transfers to device over USB using the native ATC protocol

Videos appear in the TV app immediately — movies in the Movies tab, TV episodes grouped by show and season.

## Features

- **Any format in, TV app out** — MKV, AVI, MP4, HEVC, H.264, VP9, multi-audio, subtitles
- **Smart transcoding** — only re-encodes incompatible streams; copies the rest as-is
- **Hardware acceleration** — Apple VideoToolbox for fast HEVC encoding (with libx265 toggle for slower / smaller files)
- **Pipelined transcode + upload** — each file streams to the device as soon as its transcode finishes, overlapping with ongoing transcodes of other files
- **Streaming registration** — per-file `FileBegin/FileComplete` fires as each upload finishes; medialibraryd commits rows continuously instead of waiting for one big batch at the end
- **Surgical audio re-encoding** — AAC and EAC3 tracks copy through bit-perfect; only AC3 tracks are transcoded to AAC (the iPad TV app silently drops AC3 from its audio-language switcher); the user's "default" audio choice survives through every pass
- **Parallel transcoding + parallel analyze** — multiple ffmpeg + ffprobe workers saturate all cores during both phases
- **Disk space preflight + mid-sync watchdog** — checks Mac temp and device free space before any ffmpeg runs, then polls every 10 s during upload so a runaway iCloud / Photos sync aborts cleanly instead of blowing up AFC
- **TV-show clustering** — a season drop hits TMDb once per show (not per episode), and one show-pick re-applies across the whole cluster; per-episode picks are surfaced as a single resolvable conflict instead of N modal prompts
- **External dub & sub mux** — drop a `Show.S01/AniLibria/*.mka` (or `Subs/*.srt`) tree next to your videos and Mediaporter detects the studios / sub labels, lets you toggle them per cluster (with a "Burn in" option for hardsubbing), and muxes them into each episode before the transcode pass. ASS / SSA convert to SRT automatically since TV.app doesn't render ASS
- **Cluster propagation popover** — change audio / sub / resolution / burn-in on one episode, get an "Apply to all N other episodes?" prompt that auto-dismisses after 5 s. Toggle "Always" inside the popover (or in Settings) for silent propagation. Falls back to all-audio when a sibling has no matching `(lang, codec)` rather than bricking the output
- **OpenSubtitles auto-fetch** — when configured, missing-language SRTs are pulled by TMDb id / moviehash into a per-user cache and applied before muxing
- **Burn-in subtitles** — embedded text, sidecar SRT/ASS, **and** cluster-extras subs can all be burned into the video (no extra ffmpeg pass; uses the transcode that's already happening). PGS / VOBSUB bitmap burn-in works with proper canvas sizing and post-overlay downscale
- **Duplicate skip** — files already on the device (matched on title + duration ±2 s) are filtered out by default; per-row override puts them back in the queue
- **Movies and TV shows** — automatic detection, TMDb metadata, season/episode grouping, per-episode stills and show portraits; fallback posters when TMDb has nothing
- **Storage-aware recommendation** — banner respects the device's panel resolution by default; a Settings toggle ("I AirPlay to a 4K display") flips to keeping originals
- **Direct USB transfer** — no Wi-Fi, no cloud, no Apple ID required
- **No iTunes, Finder, or admin prompts** — the shipping app `dlopen`s Apple's private `MobileDevice.framework` directly, so there's no sudo, no helper install, no `SMAppService` dialog
- **Sign-and-go distribution** — release builds are signed + notarized via Developer ID, stapled, and shipped as a DMG from [porter.md](https://porter.md). First-launch ffmpeg precheck explains the one external dependency
- **Resilient lifecycle** — zombie ffmpeg children from a hard crash are swept at next launch; cancel during mux or transcode actually kills the running ffmpeg; orphan AFC bytes can be re-registered without re-uploading; leftover transcoded outputs in temp are surfaced with a one-click cleanup
- **Help menu** — one click captures a redacted diagnostic report (app version, OS, device, last debug log) and opens a pre-filled GitHub issue

## What's inside the Mac app

Three columns: drop zone on the left, queued files in the middle (with inline expansion for stream selection and resolution / burn-in controls), connected device on the right. Drop on the middle column to analyze only; drop on the device column to analyze + send.

- **Drop zone** parses filenames into movies vs TV episodes, groups episodes by show into clusters, runs ffprobe in parallel (capped at 4), and resolves TMDb metadata once per cluster.
- **File rows** show the parsed title, detected streams, the planned action ("transcode" / "remux" / "copy"), and any cluster-extras that would be muxed in. Hold-to-preview a poster for the full artwork.
- **Cluster header** (visible when the dropped folder has external dubs / subs) lists every detected studio + sub label with include checkboxes, a radio for default audio dub, and a Burn-in toggle per sub. Selections propagate to every episode in the cluster.
- **Bottom timeline** is the live three-stage pill — Analyze → Transcode → Upload — with per-stage active counts (muxing rolls up under Transcode), a synced/on-device counter, and Cancel / Clear buttons.
- **Settings** covers TMDb / OpenSubtitles credentials, encoder (VideoToolbox vs libx265), the AirPlay-to-4K toggle, and the "Always propagate per-episode changes" switch.
- **Menu bar** wires Cmd-Q guard during sync, manual "Retry Registration" when a previous run left bytes on the device but skipped the final commit, "Clean Up Staged Media Files" for surfaced orphans / leftovers, and a Help submenu for one-click bug reports with diagnostic info.

## How it works

mediaporter communicates with iOS devices using the ATC (AirTrafficControl) protocol — the same native protocol used by Finder for media sync.

### Upload-first architecture

Large files (5GB+) are handled reliably using an upload-first approach:

1. **AFC upload** — file bytes are transferred to device storage first, with no ATC session active. Safe to interrupt (no ghost entries).
2. **ATC session** — short handshake + metadata registration + asset linking. Takes seconds, not minutes. No timeout risk.

This eliminates the main failure mode of traditional sync tools where metadata gets registered before the file transfer completes, leaving unplayable ghost entries.

### Pipelined transcode + upload

When multiple files are queued, transcoding and uploading run in parallel. Parallel ffmpeg workers handle the encode; a dedicated uploader streams each finished file to the device over AFC immediately. Registration is **streaming**: the ATC session opens before the first upload, sends each file's `FileBegin/FileComplete` the moment its AFC upload completes, and ends with a short `SyncFinished` — medialibraryd commits each row in seconds instead of buffering the whole batch.

On a USB-C iPad Pro, file transfers hit ~150–180 MB/s (1.2–1.5 Gbps), so the upload phase typically finishes well inside the transcode phase for parallel runs.

### External-track mux

When the dropped folder contains nested `Studio/*.mka` (extra dubs) or `Subs/*.srt` (extra subtitles), the analyze pass scans the directory tree (depth ≤ 4), groups files by parent folder = label, infers language from path tokens, and detects "forced" subs by token (`forced`, `signs`, `songs`, `надписи`, `форсированные`). Once the user toggles studios / sub labels on, each episode's extras are muxed into an intermediate MKV (codec-copy, chapters and data streams stripped) right before its transcode pass. ASS / SSA subs are pre-converted to SRT since TV.app can't render ASS. The user-picked "default" audio survives all the way through to the final `.m4v`.

### Signing + distribution

Release builds run through `MacApp/scripts/release.sh`: arm64 SwiftPM build → bundle assembly via `build-app.sh` → sign nested binaries + the outer app with Developer ID → submit to `notarytool` (keychain profile `porter-notarization`) → staple → DMG. Private frameworks are `dlopen`-ed at runtime (not linked), which passes notarization while keeping the app App-Store-rejection-free.

### Protocol details

- **ATC handshake** with Grappa authentication over USB
- **Binary plist** sync metadata with CIG cryptographic signatures
- **AFC** (Apple File Conduit) for file upload to device storage
- **Asset registration** via FileBegin/FileComplete protocol messages
- **Ping/Pong keepalive** during device processing

The result is a native media library entry — videos appear in the TV app with correct `media_type=2048`, artwork, and full playback functionality. No jailbreak, no third-party apps on the device.

## Diagnostics & logging

Every diagnostic event the app produces (ATC wire traffic, AFC upload progress, ffmpeg invocations, TMDb / OpenSubtitles lookups, device-library snapshots) goes to **two** sinks at once:

1. **Apple Unified Logging** under subsystem **`md.porter.MediaPorter`** (matches the app's bundle identifier). The category is the tag prefix before the first dot — currently `afc`, `atc`, `cleanup`, `device`, `extracts`, `ffmpeg`, `ffprobe`, `opensubs`, `prereq`, `tmdb`, `zombie`. Inspect with:

   ```bash
   # live tail
   log stream --predicate 'subsystem == "md.porter.MediaPorter"' --info

   # last hour, ATC wire traffic only
   log show --predicate 'subsystem == "md.porter.MediaPorter" AND category == "atc"' \
            --info --last 1h

   # open Console.app and filter on the subsystem
   open -a Console
   ```

   Entries are emitted at one of four levels — `.debug`, `.info`, `.notice`, `.error`. `.debug` and `.info` are volatile (memory only, kept lean for users who never look) and require `--info` (or `--debug`) to surface in `log show`. `.notice` and `.error` are persisted by OSLog: recovery actions (stale-asset clears, abandoned assets, SyncAllowed fallback, device-trust recovery, zombie-ffmpeg kills) emit at `.notice`, and hard failures (finishSync timeout, TMDb fetch threw) at `.error`. To filter to just the persistent layer post-incident:

   ```bash
   log show --predicate 'subsystem == "md.porter.MediaPorter"' --last 1h
   ```

2. **`/tmp/mediaporter-debug.log`** — plaintext mirror, append-mode, persistent until macOS clears `/tmp`. Easiest path for `tail -f` during a sync and for attaching to bug reports without needing `log show` privileges:

   ```bash
   tail -f /tmp/mediaporter-debug.log
   ```

   The "Submit Bug Report" item in the Help menu captures the tail of this file (redacted) into the GitHub-issue body.

## Research and documentation

This project includes extensive protocol research and reverse engineering documentation:

| Document | Description |
|----------|-------------|
| [ATC Sync Flow](research/docs/ATC_SYNC_FLOW.md) | Complete reverse-engineered sync flow with Grappa, CIG, and plist format |
| [Implementation Guide](research/docs/IMPLEMENTATION_GUIDE.md) | Full specification with code examples |
| [ATC Protocol](research/docs/ATC_PROTOCOL.md) | Wire format, message flow, observed commands |
| [Trace Analysis](research/docs/TRACE_ANALYSIS.md) | Protocol trace analysis from LLDB sessions |
| [Media Library DB](research/docs/MEDIA_LIBRARY_DB.md) | MediaLibrary.sqlitedb schema analysis |
| [Architecture](research/docs/ARCHITECTURE.md) | Module overview and technical decisions |
| [History](research/docs/HISTORY.md) | Chronological findings log |

## Repository layout

```
MacApp/                  Swift / SwiftUI app — primary shipping target
python-reference/        Original Python CLI — frozen reference
research/                Protocol docs (shared)
scripts/cig/             CIG signing engine: source + compiled arm64 dylib (shared)
traces/                  Captured protocol traces (gitignored, local)
site/                    porter.md (Astro)
brand/                   Brand assets
```

## Interoperability notice

This project is the result of independent interoperability research into Apple's ATC media sync protocol, conducted under DMCA Section 1201(f) for the purpose of enabling users to transfer their own media to their own devices.

Certain protocol constants (authentication handshake, signature engine) were derived from publicly available open-source implementations of the same protocol on GitHub. See the research documentation for full methodology, protocol analysis, and references to prior public work.

This software is intended exclusively for legitimate personal use: transferring media you own to devices you own.

## License

[GPL v3](LICENSE)
