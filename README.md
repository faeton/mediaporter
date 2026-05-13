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
- **Hardware acceleration** — Apple VideoToolbox for fast HEVC encoding
- **Pipelined transcode + upload** — each file streams to the device as soon as its transcode finishes, overlapping with ongoing transcodes of other files
- **Surgical audio re-encoding** — AAC and EAC3 tracks copy through bit-perfect; only AC3 tracks are transcoded to AAC (the iPad TV app silently drops AC3 from its audio-language switcher)
- **Parallel transcoding** — multiple files at once, saturating all cores
- **Disk space preflight** — checks Mac temp and device free space before any ffmpeg runs
- **Movies and TV shows** — automatic detection, TMDb metadata, season/episode grouping
- **Poster artwork** — downloaded from TMDb and displayed in the TV app; auto-generated fallback posters when no match is found
- **Direct USB transfer** — no Wi-Fi, no cloud, no Apple ID required
- **No iTunes or Finder needed** — uses the native ATC sync protocol directly

## How it works

mediaporter communicates with iOS devices using the ATC (AirTrafficControl) protocol — the same native protocol used by Finder for media sync.

### Upload-first architecture

Large files (5GB+) are handled reliably using an upload-first approach:

1. **AFC upload** — file bytes are transferred to device storage first, with no ATC session active. Safe to interrupt (no ghost entries).
2. **ATC session** — short handshake + metadata registration + asset linking. Takes seconds, not minutes. No timeout risk.

This eliminates the main failure mode of traditional sync tools where metadata gets registered before the file transfer completes, leaving unplayable ghost entries.

### Pipelined transcode + upload

When multiple files are queued, transcoding and uploading run in parallel. Parallel ffmpeg workers handle the encode; a dedicated uploader streams each finished file to the device over AFC immediately. A single short ATC session registers everything at the end.

On a USB-C iPad Pro, file transfers hit ~150–180 MB/s (1.2–1.5 Gbps), so the upload phase typically finishes well inside the transcode phase for parallel runs.

### Protocol details

- **ATC handshake** with Grappa authentication over USB
- **Binary plist** sync metadata with CIG cryptographic signatures
- **AFC** (Apple File Conduit) for file upload to device storage
- **Asset registration** via FileBegin/FileComplete protocol messages
- **Ping/Pong keepalive** during device processing

The result is a native media library entry — videos appear in the TV app with correct `media_type=2048`, artwork, and full playback functionality. No jailbreak, no third-party apps on the device.

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
