# mediaporter Architecture

## Project Goal

Open-source CLI tool to transfer video files to iOS devices over USB-C with:
- Smart transcoding (MKV → M4V, only re-encode when needed)
- Multi-audio track preservation with language tags
- Subtitle detection (embedded + external sidecar) with language markup
- TMDb metadata lookup (movie/TV) with poster art
- TV series grouping (show → season → episode)
- Native TV app integration via ATC protocol

## Module Overview

```
mediaporter/
├── cli.py          ─── Click CLI entry point
├── pipeline.py     ─── End-to-end orchestrator
│
├── probe.py        ─── ffprobe wrapper → MediaInfo dataclass
├── compat.py       ─── iPad codec compatibility matrix → TranscodeDecision
├── transcode.py    ─── ffmpeg command builder + executor
│
├── subtitles.py    ─── External subtitle scanner + language detection
├── audio.py        ─── Audio track classification (copy vs transcode)
│
├── metadata.py     ─── guessit filename parser + TMDb API lookup
├── tagger.py       ─── mutagen M4V tag writer (movie + TV atoms)
│
├── device.py       ─── pymobiledevice3 async wrapper (detect, AFC, tunnel)
├── transfer.py     ─── AFC file push to iTunes_Control/Music/Fxx/
├── mediadb.py      ─── MediaLibrary.sqlitedb analysis (experimental, see notes)
├── atc.py          ─── ATC protocol client for native TV app sync (see also scripts/atc_proper_sync.py)
│
├── progress.py     ─── Rich terminal UI
├── config.py       ─── TOML config loader
└── exceptions.py   ─── Custom exception hierarchy
```

## Data Flow

```
Input file (MKV/AVI/MP4)
    │
    ▼
probe.py ──→ MediaInfo (streams, codecs, languages)
    │
    ▼
subtitles.py ──→ MediaInfo + external subtitle files
    │
    ▼
compat.py ──→ TranscodeDecision (per-stream: copy/transcode/skip)
    │
    ▼
transcode.py ──→ M4V file (ffmpeg, VideoToolbox HW accel)
    │           - Video: copy H.264/H.265, transcode VP9/AV1
    │           - Audio: copy AAC/AC3, transcode DTS/FLAC → AAC
    │           - Subs: convert SRT/ASS → mov_text, skip bitmap
    │
    ▼
metadata.py ──→ MovieMetadata or EpisodeMetadata
    │           - guessit: parse filename → title, year, S/E
    │           - tmdbsimple: TMDb API → plot, genre, poster
    │           - CLI overrides: --show, --season, --episode
    │
    ▼
tagger.py ──→ Tagged M4V (mutagen)
    │           Movies:  stik=9, ©nam, covr, desc, hdvd
    │           TV:      stik=10, tvsh, tvsn, tves, ©alb, sosn
    │
    ▼
device.py ──→ Connected iPad (pymobiledevice3, tunnel for iOS 17+)
    │
    ▼
transfer.py ──→ File on device at iTunes_Control/Music/Fxx/XXXX.m4v
    │
    ▼
atc.py [TODO] ──→ Registered in TV app via ATC protocol
```

## Key Technical Decisions

### ffmpeg via subprocess (not Python bindings)
- No fragile native bindings
- System ffmpeg (brew install ffmpeg) always up to date
- Homebrew formula just needs `depends_on "ffmpeg"`

### Persistent async event loop for pymobiledevice3
- pymobiledevice3 v9.x is fully async
- Single background thread with persistent event loop
- All lockdown/AFC operations use the same loop to avoid context issues

### M4V format with forced mp4 muxer
- `.m4v` extension triggers ffmpeg's `ipod` muxer which doesn't support HEVC
- We force `-f mp4` to use the standard mp4 muxer with `.m4v` extension
- Always add `-tag:v hvc1` for HEVC (required by Apple devices)

### iOS 17+ tunnel requirement
- iOS 17+ requires `sudo pymobiledevice3 remote start-tunnel`
- Creates a utun network interface (kernel operation = root required)
- Can be daemonized: `sudo pymobiledevice3 remote tunneld -d`
- Or set up as LaunchDaemon for permanent background service

## TV App Metadata Atoms

### Movies (stik=9)
```python
video["stik"]    = [9]          # Movie
video["\xa9nam"] = ["Title"]    # Title
video["\xa9day"] = ["2024"]     # Year
video["\xa9gen"] = ["Action"]   # Genre
video["desc"]    = ["Short..."] # Short description (≤255)
video["ldes"]    = ["Long..."]  # Long description
video["covr"]    = [JPEG_data]  # Poster art
video["hdvd"]    = [2]          # 0=SD, 1=720p, 2=1080p
```

### TV Episodes (stik=10)
```python
video["stik"]    = [10]                    # TV Show (MANDATORY)
video["tvsh"]    = ["Show Name"]           # Show name (MANDATORY)
video["tvsn"]    = [1]                     # Season (MANDATORY)
video["tves"]    = [1]                     # Episode number
video["tven"]    = ["S01E01"]              # Episode ID
video["tvnn"]    = ["Network"]             # Network
video["\xa9nam"] = ["Episode Title"]       # Episode title
video["\xa9alb"] = ["Show, Season 1"]      # Album
video["sosn"]    = ["Show Name"]           # Sort show name
```

## iOS Device Communication

### Service Stack
```
USB-C cable
    │
    ▼
usbmuxd (macOS daemon, always running)
    │
    ▼
Tunnel (iOS 17+): utun interface via pymobiledevice3
    │
    ▼
Lockdown: SSL pairing, service discovery
    │
    ├──→ com.apple.afc: File access to /var/mobile/Media/
    ├──→ com.apple.atc: Media sync (AirTrafficControl) [TARGET]
    ├──→ com.apple.mobile.notification_proxy: Post notifications
    └──→ com.apple.mobile.diagnostics: Device diagnostics
```

### ATC Protocol Status (Updated 2026-04-06) — FULLY WORKING
- Connection: ✅ Working
- Capabilities exchange: ✅ Working
- Asset metrics query: ✅ Working
- Grappa auth (84-byte replayed blob): ✅ Working
- Sync request (RequestingSync + Grappa): ✅ ReadyForSync received
- Metadata sync (binary plist + CIG): ✅ AssetManifest received (AssetType=Movie)
- File transfer (Airlock staging + AFC): ✅ Working
- DB entry creation (media_type=2048, media_kind=2): ✅ Correct, visible in TV app

See `docs/ATC_PROTOCOL.md` for full protocol documentation.
Working implementation: `scripts/atc_proper_sync.py`

## Dependencies

| Package | Version | Purpose | License |
|---------|---------|---------|---------|
| pymobiledevice3 | ≥4.0 | iOS device communication | GPL-3.0 |
| click | ≥8.1 | CLI framework | BSD |
| rich | ≥13.0 | Terminal UI | MIT |
| mutagen | ≥1.47 | MP4 metadata writing | GPL-2.0 |
| guessit | ≥3.8 | Filename parsing | LGPL-3.0 |
| tmdbsimple | ≥2.9 | TMDb API client | GPL-3.0 |
| ffmpeg | system | Transcoding | LGPL/GPL |

**Project license: GPL-3.0** (forced by pymobiledevice3)
