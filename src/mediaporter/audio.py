"""Audio track analysis and transcode decisions."""

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
    else:
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


# Preference order when normalizing mixed-codec audio tracks. The iPad TV
# app's audio language switcher only shows tracks when every track uses the
# same codec, so mixed files must be normalized. Higher index = lower quality;
# the best codec that is already present in the file is chosen as the target.
# EAC3/AC3 preserve surround quality far better than re-encoding to AAC.
_NORMALIZATION_RANKING = ("eac3", "ac3", "aac")


def pick_normalization_codec(streams: list[StreamInfo]) -> str | None:
    """Pick the target codec when normalizing mixed-codec audio for iPad.

    Returns None if no normalization is needed (≤1 track or all same codec).
    Otherwise returns the best codec already present in the file, preferring
    EAC3 > AC3 > AAC. Falls back to "aac" if none of the ranked codecs are
    present (exotic mixes like dts + truehd).
    """
    if len(streams) <= 1:
        return None
    codecs = {s.codec_name.lower() for s in streams}
    if len(codecs) <= 1:
        return None
    for preferred in _NORMALIZATION_RANKING:
        if preferred in codecs:
            return preferred
    return "aac"


def target_bitrate_for(codec: str, channels: int) -> str:
    """Recommended bitrate for encoding `channels` into `codec`.

    Values match commonly-used streaming/broadcast defaults: EAC3 640k 5.1 is
    the Atmos/Dolby Digital Plus reference; AC3 448k 5.1 is DVD/Blu-ray; AAC
    384k 5.1 is the iTunes Store high-quality surround target.
    """
    c = codec.lower()
    if c == "eac3":
        return "640k" if channels >= 6 else "192k"
    if c == "ac3":
        return "448k" if channels >= 6 else "192k"
    return "384k" if channels >= 6 else "256k"
