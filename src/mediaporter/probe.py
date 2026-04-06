"""FFprobe wrapper for media file analysis."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from mediaporter.exceptions import ProbeError


@dataclass
class StreamInfo:
    """Information about a single stream in a media file."""
    index: int
    codec_type: str  # video, audio, subtitle
    codec_name: str  # h264, hevc, aac, ac3, subrip, hdmv_pgs_subtitle, etc.
    profile: str | None = None
    level: int | None = None
    width: int | None = None
    height: int | None = None
    pix_fmt: str | None = None
    channels: int | None = None
    channel_layout: str | None = None
    sample_rate: int | None = None
    bit_rate: int | None = None
    language: str | None = None
    title: str | None = None
    is_default: bool = False
    is_forced: bool = False


@dataclass
class ExternalSubtitle:
    """An external subtitle file found alongside the video."""
    path: Path
    language: str  # ISO 639-2 (eng, fra, etc.) or "und"
    format: str  # srt, ass, ssa


@dataclass
class MediaInfo:
    """Complete information about a media file."""
    path: Path
    format_name: str  # matroska, avi, mov
    duration: float  # seconds
    bit_rate: int | None = None
    video_streams: list[StreamInfo] = field(default_factory=list)
    audio_streams: list[StreamInfo] = field(default_factory=list)
    subtitle_streams: list[StreamInfo] = field(default_factory=list)
    external_subtitles: list[ExternalSubtitle] = field(default_factory=list)


def _parse_stream(raw: dict) -> StreamInfo:
    """Parse a single stream from ffprobe JSON output."""
    tags = raw.get("tags", {})
    disposition = raw.get("disposition", {})

    return StreamInfo(
        index=raw["index"],
        codec_type=raw["codec_type"],
        codec_name=raw.get("codec_name", "unknown"),
        profile=raw.get("profile"),
        level=int(raw["level"]) if raw.get("level") is not None else None,
        width=int(raw["width"]) if raw.get("width") else None,
        height=int(raw["height"]) if raw.get("height") else None,
        pix_fmt=raw.get("pix_fmt"),
        channels=int(raw["channels"]) if raw.get("channels") else None,
        channel_layout=raw.get("channel_layout"),
        sample_rate=int(raw["sample_rate"]) if raw.get("sample_rate") else None,
        bit_rate=int(raw["bit_rate"]) if raw.get("bit_rate") else None,
        language=tags.get("language"),
        title=tags.get("title"),
        is_default=bool(disposition.get("default", 0)),
        is_forced=bool(disposition.get("forced", 0)),
    )


def probe_file(path: str | Path) -> MediaInfo:
    """Probe a media file with ffprobe and return structured info."""
    path = Path(path)
    if not path.exists():
        raise ProbeError(f"File not found: {path}")

    cmd = [
        "ffprobe",
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        str(path),
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        raise ProbeError("ffprobe not found. Install ffmpeg: brew install ffmpeg")
    except subprocess.CalledProcessError as e:
        raise ProbeError(f"ffprobe failed for {path}: {e.stderr}")

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ProbeError(f"ffprobe returned invalid JSON for {path}")

    fmt = data.get("format", {})
    streams = data.get("streams", [])

    video_streams = []
    audio_streams = []
    subtitle_streams = []

    for raw in streams:
        stream = _parse_stream(raw)
        if stream.codec_type == "video":
            # Skip attached pictures (album art in MKV)
            if raw.get("disposition", {}).get("attached_pic", 0):
                continue
            video_streams.append(stream)
        elif stream.codec_type == "audio":
            audio_streams.append(stream)
        elif stream.codec_type == "subtitle":
            subtitle_streams.append(stream)

    return MediaInfo(
        path=path,
        format_name=fmt.get("format_name", "unknown"),
        duration=float(fmt.get("duration", 0)),
        bit_rate=int(fmt["bit_rate"]) if fmt.get("bit_rate") else None,
        video_streams=video_streams,
        audio_streams=audio_streams,
        subtitle_streams=subtitle_streams,
    )
