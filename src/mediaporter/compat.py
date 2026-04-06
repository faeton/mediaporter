"""iPad codec compatibility matrix and transcode decision logic."""

from __future__ import annotations

from dataclasses import dataclass, field

from mediaporter.probe import MediaInfo

# Video codecs that can be remuxed directly (no re-encoding needed)
COMPATIBLE_VIDEO_CODECS = {"h264", "hevc", "h265"}

# Audio codecs that iPad plays natively
COMPATIBLE_AUDIO_CODECS = {"aac", "ac3", "eac3", "alac", "mp3"}

# Text-based subtitle codecs that can be converted to mov_text
TEXT_SUBTITLE_CODECS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt"}

# Bitmap subtitle codecs that CANNOT be converted to mov_text
BITMAP_SUBTITLE_CODECS = {"hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "pgssub"}


@dataclass
class TranscodeDecision:
    """Per-stream transcode decisions for a media file."""
    # Maps stream index → action: "copy", "transcode", "convert_to_mov_text", "burn", "skip"
    stream_actions: dict[int, str] = field(default_factory=dict)
    needs_transcode: bool = False  # True if any stream needs transcoding (not just remux)
    needs_remux: bool = False  # True if container change is needed


def evaluate_compatibility(media_info: MediaInfo) -> TranscodeDecision:
    """Evaluate which streams are iPad-compatible and what needs transcoding."""
    decision = TranscodeDecision()

    # Check if container is already MP4/M4V
    is_mp4 = media_info.format_name in ("mov,mp4,m4a,3gp,3g2,mj2", "mp4", "mov")
    if not is_mp4:
        decision.needs_remux = True

    # Video streams
    for stream in media_info.video_streams:
        codec = stream.codec_name.lower()
        if codec in COMPATIBLE_VIDEO_CODECS:
            decision.stream_actions[stream.index] = "copy"
        else:
            decision.stream_actions[stream.index] = "transcode"
            decision.needs_transcode = True

    # Audio streams
    for stream in media_info.audio_streams:
        codec = stream.codec_name.lower()
        if codec in COMPATIBLE_AUDIO_CODECS:
            decision.stream_actions[stream.index] = "copy"
        else:
            decision.stream_actions[stream.index] = "transcode"
            decision.needs_transcode = True

    # Subtitle streams
    for stream in media_info.subtitle_streams:
        codec = stream.codec_name.lower()
        if codec == "mov_text":
            decision.stream_actions[stream.index] = "copy"
        elif codec in TEXT_SUBTITLE_CODECS:
            decision.stream_actions[stream.index] = "convert_to_mov_text"
        elif codec in BITMAP_SUBTITLE_CODECS:
            decision.stream_actions[stream.index] = "skip"  # default: skip bitmap subs
        else:
            decision.stream_actions[stream.index] = "skip"

    return decision


def get_hd_flag(width: int | None, height: int | None) -> int:
    """Return the hdvd atom value based on resolution. 0=SD, 1=720p, 2=1080p+."""
    if not height:
        return 0
    if height >= 1080:
        return 2
    if height >= 720:
        return 1
    return 0
