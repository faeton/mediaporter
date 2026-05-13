"""Audio track analysis and transcode decisions.

The iPad TV app's audio-language switcher lists AAC and EAC3 tracks but
silently drops AC3 tracks from the selectable list (though it still decodes
and plays AC3). The fix is to transcode AC3 to AAC while copying AAC and
EAC3 through unchanged. See research/docs/AUDIO_SWITCHER_RULE.md for the
experimental evidence.
"""

from __future__ import annotations

from dataclasses import dataclass

from mediaporter.compat import COMPATIBLE_AUDIO_CODECS
from mediaporter.probe import StreamInfo


@dataclass
class AudioAction:
    """Transcode decision for a single audio track."""
    stream: StreamInfo
    action: str  # "copy" or "transcode"
    target_codec: str | None = None
    target_channels: int | None = None
    target_bitrate: str | None = None


def classify_audio_stream(stream: StreamInfo) -> AudioAction:
    """Determine what to do with an audio stream for iPad compatibility."""
    codec = stream.codec_name.lower()

    if codec in COMPATIBLE_AUDIO_CODECS:
        return AudioAction(stream=stream, action="copy")

    channels = stream.channels or 2

    if channels >= 6:
        return AudioAction(
            stream=stream,
            action="transcode",
            target_codec="aac",
            target_channels=6,
            target_bitrate="384k",
        )
    return AudioAction(
        stream=stream,
        action="transcode",
        target_codec="aac",
        target_channels=2,
        target_bitrate="256k",
    )


def classify_all_audio(streams: list[StreamInfo]) -> list[AudioAction]:
    """Classify all audio streams and return their actions."""
    return [classify_audio_stream(s) for s in streams]
