# mediaporter

Transfer video files to iPhone and iPad over USB — no iTunes, no Finder, no cloud. Videos appear in the native Apple TV app with full metadata, artwork, and playback support.

An open-source alternative to iTunes/Finder video sync. Push any video from your Mac to your iOS device with automatic transcoding, metadata lookup, and native TV app integration.

## What it does

```bash
mediaporter movie.mkv
```

That's it. mediaporter handles the entire pipeline:

1. **Analyze** — probes video streams, checks iPad codec compatibility
2. **Metadata** — looks up title, year, and poster art from TMDb
3. **Transcode** — converts to Apple-compatible format if needed (HEVC/H.264 via ffmpeg)
4. **Tag** — writes MP4 metadata atoms (title, artwork, HD flag, stik type)
5. **Sync** — transfers to device over USB using native ATC protocol

Videos appear in the TV app immediately — movies in the Movies tab, TV episodes grouped by show and season.

## Features

- **Any format in, TV app out** — MKV, AVI, MP4, HEVC, H.264, VP9, multi-audio, subtitles
- **Smart transcoding** — only re-encodes incompatible streams; copies the rest as-is
- **Hardware acceleration** — Apple VideoToolbox for fast HEVC encoding on Mac
- **Pipelined transcode + upload** — each file streams to the device as soon as its transcode finishes, overlapping with ongoing transcodes of other files. No waiting for the whole batch
- **Smart audio normalization** — mixed-codec files normalize to the best codec already present (EAC3 > AC3 > AAC), so your EAC3 surround track copies through bit-perfect while only the mismatched track gets re-encoded
- **Parallel transcoding** — process multiple files simultaneously with `-j N`, saturating all cores
- **Disk space preflight** — checks Mac temp and device free space before any ffmpeg runs. Fail fast, not mid-transcode
- **Run summary** — wall-clock totals, peak and average transfer speed, Mac + device free-space deltas at the end of every run
- **Movies and TV shows** — automatic detection, TMDb metadata, season/episode grouping
- **Poster artwork** — downloaded from TMDb and displayed in the TV app; auto-generated fallback posters when no match is found
- **Interactive audio selection** — choose which dub/translation per language when multiple exist
- **Interactive subtitle selection** — checkbox picker for which subtitle tracks to embed
- **Interactive metadata correction** — manually enter title/year when filenames are unrecognizable
- **Interactive drag-and-drop mode** — just run `mediaporter` with no args, drop a file on the terminal, press enter
- **Multiple audio & subtitle tracks** — iPad audio language switcher and CC subtitle support
- **Rich device info** — `mediaporter devices` shows model name (e.g., "iPad Pro 12.9\" (3rd gen)"), iOS version, native display resolution, and recommended transcode target
- **Direct USB transfer** — no Wi-Fi, no cloud, no Apple ID required
- **No iTunes or Finder needed** — uses the native ATC sync protocol directly
- **CLI-first** — scriptable, no GUI needed

## Requirements

- macOS (uses Apple private frameworks via ctypes)
- Python 3.11+
- ffmpeg (`brew install ffmpeg`)
- iOS device connected via USB

## Quick start

```bash
git clone https://github.com/user/mediaporter.git
cd mediaporter
python -m venv .venv
source .venv/bin/activate
pip install -e .
```

Then:

```bash
# Transfer a movie
mediaporter movie.mkv

# Transfer multiple files with parallel transcoding
mediaporter movie1.mkv movie2.mkv -j 2

# Analyze without transferring
mediaporter probe movie.mkv

# Check connected devices
mediaporter devices

# Save locally without syncing
mediaporter movie.mkv -o output.m4v

# Skip interactive prompts
mediaporter movie.mkv -y

# Dry run (show plan, don't execute)
mediaporter movie.mkv --dry-run
```

## Usage

```
mediaporter [OPTIONS] [FILES]...

Options:
  -y, --yes          Skip confirmation prompts
  -q, --quality      Encoding quality: fast, balanced (default), quality
  -j, --jobs N       Parallel transcode workers
  --hw / --no-hw     VideoToolbox hardware encoding (default: on)
  --no-metadata      Skip TMDb metadata lookup
  --tmdb-key KEY     TMDb API key (or set TMDB_API_KEY env var)
  --dry-run          Show plan without executing
  -o, --output PATH  Save M4V locally instead of syncing to device
  -v, --verbose      Verbose output
  --version          Show version

Commands:
  probe    Analyze a video file's streams and iPad compatibility
  devices  List connected iOS devices
```

## How it works

mediaporter communicates with iOS devices using the ATC (AirTrafficControl) protocol — the same native protocol used by Finder for media sync.

### Upload-first architecture

Large files (5GB+) are handled reliably using an upload-first approach:

1. **AFC upload** — file bytes are transferred to device storage first, with no ATC session active. Safe to interrupt (no ghost entries).
2. **ATC session** — short handshake + metadata registration + asset linking. Takes seconds, not minutes. No timeout risk.

This eliminates the main failure mode of traditional sync tools where metadata gets registered before the file transfer completes, leaving unplayable ghost entries.

### Pipelined transcode + upload

When multiple files are queued, mediaporter runs transcoding and uploading in parallel:

- Parallel ffmpeg workers handle transcoding (`-j N` or auto).
- A dedicated uploader thread streams each file to the device over AFC the moment its transcode finishes — no waiting for the whole batch.
- A single short ATC session at the very end registers every file at once.

On a USB-C iPad Pro, file transfers hit ~150–180 MB/s (1.2–1.5 Gbps), so the upload phase typically finishes well inside the transcode phase for parallel runs.

### Protocol details

- **ATC handshake** with Grappa authentication over USB
- **Binary plist** sync metadata with CIG cryptographic signatures
- **AFC** (Apple File Conduit) for file upload to device storage
- **Asset registration** via FileBegin/FileComplete protocol messages
- **Ping/Pong keepalive** during device processing

The result is a native media library entry — videos appear in the TV app with correct `media_type=2048`, artwork, and full playback functionality. No jailbreak, no third-party apps on the device.

## Roadmap

- **macOS native app** — Swift/SwiftUI GUI with drag-and-drop, built on the same protocol engine
- **Batch TV series sync** — drag a season folder, auto-detect episodes
- **Device cleanup** — remove orphan files from previous failed syncs

## Interactive workflow

When you run `mediaporter` on a file with multiple audio or subtitle tracks, it offers interactive selection:

**Audio selection** — when multiple dubs exist for the same language (e.g., three Russian translations), you pick one per language with arrow keys. Single-track languages are auto-included.

**Subtitle selection** — checkbox picker showing all embeddable subtitle tracks (internal + external). Toggle with space, confirm with enter.

**Metadata correction** — if the filename can't be matched on TMDb (e.g., `xz-puzzl3.mkv`), you're prompted to enter the correct title and year. If still no poster is found, a fallback poster is auto-generated.

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

## Interoperability notice

This project is the result of independent interoperability research into Apple's ATC media sync protocol, conducted under DMCA Section 1201(f) for the purpose of enabling users to transfer their own media to their own devices.

Certain protocol constants (authentication handshake, signature engine) were derived from publicly available open-source implementations of the same protocol on GitHub. See the research documentation for full methodology, protocol analysis, and references to prior public work.

This software is intended exclusively for legitimate personal use: transferring media you own to devices you own.

## License

[GPL v3](LICENSE)
