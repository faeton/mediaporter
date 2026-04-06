# mediaporter

Transfer video files to iPhone and iPad over USB — no iTunes, no Finder, no cloud. Videos appear in the native Apple TV app with full metadata.

An open-source alternative to iTunes/Finder video sync. Push any video from your Mac to your iOS device with automatic transcoding, metadata lookup, and native TV app integration.

**Keywords:** transfer video to iPad, send movie to iPhone without iTunes, sideload video iOS, copy video to iPad over USB, iTunes alternative for video, push video to Apple TV app, video to iPhone CLI, ffmpeg iPad transfer, iOS video sync tool, transfer MKV to iPad, HEVC to iPhone

## What it does

mediaporter lets you send video files to your iPad or iPhone and have them appear directly in the native TV app — no iTunes, no Finder sync, no cloud services. It handles the entire pipeline:

1. **Probe** — analyzes your video file (codec, resolution, duration)
2. **Transcode** — converts to Apple-compatible format if needed (HEVC/H.264, via ffmpeg)
3. **Tag** — sets correct metadata for TV app recognition
4. **Transfer** — syncs to the device over USB using the native ATC protocol

Videos appear in the TV app with correct metadata, artwork, and playback support — the same result as commercial sync tools, but free and open source.

## Features

- **Any format in, TV app out** — MKV, AVI, MP4, HEVC, H.264, multi-audio, subtitles — mediaporter handles it all
- **Smart transcoding** — only re-encodes what's needed; copies compatible streams as-is
- **Hardware acceleration** — uses Apple VideoToolbox for fast HEVC/H.264 encoding on Mac
- **Movies and TV shows** — proper metadata, season/episode info, show grouping in the TV app
- **Direct USB transfer** — no Wi-Fi, no cloud, no Apple ID required
- **No iTunes or Finder needed** — uses the native ATC sync protocol directly
- **CLI-first** — scriptable, pipeable, automate your media library
- **Open source** — GPL v3, built on publicly documented protocol research

## Requirements

- macOS (uses Apple frameworks via ctypes)
- Python 3.11+
- ffmpeg (`brew install ffmpeg`)
- iOS device connected via USB

## Quick start

```bash
git clone https://github.com/user/mediaporter.git
cd mediaporter
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

For iOS 17+, the tunnel service needs to be started once:

```bash
sudo pymobiledevice3 remote start-tunnel
```

Then:

```bash
# Check connected devices
mediaporter devices

# Transfer a video
mediaporter send movie.mp4
```

## How it works

mediaporter communicates with iOS devices using the ATC (AirTrafficControl) protocol — the same native protocol used by Finder and commercial tools for media sync. The implementation was developed through independent interoperability research, documented extensively in the `docs/` directory.

The sync flow:
- Establishes an authenticated ATC session over USB
- Writes sync metadata (binary plists with CIG signatures) to the device
- Stages media files via AFC (Apple File Conduit)
- Completes the transfer with proper asset registration

The result is a native media library entry — videos appear in the TV app with correct `media_type`, artwork support, and full playback functionality.

## Research and documentation

This project includes extensive protocol research and reverse engineering documentation in the `research/` directory:

| Document | Description |
|----------|-------------|
| [ATC Protocol](research/docs/ATC_PROTOCOL.md) | Wire format, message flow, observed commands |
| [ATC Sync Flow](research/docs/ATC_SYNC_FLOW.md) | Complete reverse-engineered sync flow |
| [Implementation Guide](research/docs/IMPLEMENTATION_GUIDE.md) | Full specification with code examples |
| [Media Library DB](research/docs/MEDIA_LIBRARY_DB.md) | MediaLibrary.sqlitedb schema analysis |
| [Architecture](research/docs/ARCHITECTURE.md) | Module overview and technical decisions |

## Interoperability notice

This project is the result of independent interoperability research into Apple's ATC media sync protocol, conducted under DMCA Section 1201(f) for the purpose of enabling users to transfer their own media to their own devices.

Certain protocol constants (authentication handshake, signature engine) were derived from publicly available open-source implementations of the same protocol on GitHub. See the `docs/` directory for full research methodology, protocol analysis, and references to prior public work.

This software is intended exclusively for legitimate personal use: transferring media you own to devices you own.

## License

[GPL v3](LICENSE)
