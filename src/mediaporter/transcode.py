"""FFmpeg transcoding engine — command building and execution."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from mediaporter.audio import AudioAction, classify_all_audio
from mediaporter.compat import TranscodeDecision, TEXT_SUBTITLE_CODECS
from mediaporter.exceptions import TranscodeError
from mediaporter.probe import MediaInfo


@dataclass
class QualityPreset:
    """Encoding quality settings."""
    crf: int
    preset: str
    vt_quality: int  # VideoToolbox quality (0-100, lower=better)


QUALITY_PRESETS = {
    "fast": QualityPreset(crf=28, preset="fast", vt_quality=55),
    "balanced": QualityPreset(crf=23, preset="medium", vt_quality=65),
    "quality": QualityPreset(crf=18, preset="slow", vt_quality=75),
}


def _detect_videotoolbox() -> bool:
    """Check if VideoToolbox hardware encoders are available."""
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            capture_output=True, text=True,
        )
        return "hevc_videotoolbox" in result.stdout
    except FileNotFoundError:
        return False


def build_ffmpeg_command(
    media_info: MediaInfo,
    decision: TranscodeDecision,
    audio_actions: list[AudioAction],
    output_path: Path,
    quality: str = "balanced",
    hw_accel: bool = True,
    subtitle_mode: str = "embed",
    burn_bitmap_subs: bool = False,
) -> list[str]:
    """Build the complete ffmpeg command for transcoding."""
    preset = QUALITY_PRESETS[quality]
    use_vt = hw_accel and _detect_videotoolbox()

    cmd: list[str] = ["ffmpeg", "-hide_banner", "-y"]

    # Input file
    cmd.extend(["-i", str(media_info.path)])

    # External subtitle inputs
    if subtitle_mode == "embed":
        for ext_sub in media_info.external_subtitles:
            cmd.extend(["-i", str(ext_sub.path)])

    # Stream mapping
    # Video: map first video stream
    if media_info.video_streams:
        cmd.extend(["-map", "0:v:0"])

    # Audio: map all audio streams
    for i, _ in enumerate(media_info.audio_streams):
        cmd.extend(["-map", f"0:a:{i}"])

    # Subtitles: map compatible subtitle streams from source
    sub_output_idx = 0
    if subtitle_mode == "embed":
        for i, stream in enumerate(media_info.subtitle_streams):
            action = decision.stream_actions.get(stream.index, "skip")
            if action in ("copy", "convert_to_mov_text"):
                cmd.extend(["-map", f"0:s:{i}"])
                sub_output_idx += 1
            elif action == "skip" and burn_bitmap_subs:
                pass  # handled via complex filter below

        # Map external subtitle files
        for ext_idx, ext_sub in enumerate(media_info.external_subtitles):
            input_idx = 1 + ext_idx  # external subs start at input 1
            cmd.extend(["-map", f"{input_idx}:0"])
            sub_output_idx += 1

    # Video codec
    if media_info.video_streams:
        v_stream = media_info.video_streams[0]
        v_action = decision.stream_actions.get(v_stream.index, "transcode")

        if v_action == "copy":
            cmd.extend(["-c:v", "copy"])
            # HEVC in MP4 requires hvc1 tag even when copying
            if v_stream.codec_name.lower() in ("hevc", "h265"):
                cmd.extend(["-tag:v", "hvc1"])
        elif use_vt:
            cmd.extend([
                "-c:v", "hevc_videotoolbox",
                "-q:v", str(preset.vt_quality),
                "-tag:v", "hvc1",
            ])
        else:
            cmd.extend([
                "-c:v", "libx265",
                "-crf", str(preset.crf),
                "-preset", preset.preset,
                "-tag:v", "hvc1",
                "-pix_fmt", "yuv420p",
            ])

    # Audio codecs (per-track)
    for i, action in enumerate(audio_actions):
        if action.action == "copy":
            cmd.extend([f"-c:a:{i}", "copy"])
        else:
            cmd.extend([f"-c:a:{i}", "aac"])
            if action.target_bitrate:
                cmd.extend([f"-b:a:{i}", action.target_bitrate])
            if action.target_channels:
                cmd.extend([f"-ac:a:{i}", str(action.target_channels)])

    # Audio metadata (language + title)
    for i, stream in enumerate(media_info.audio_streams):
        if stream.language:
            cmd.extend([f"-metadata:s:a:{i}", f"language={stream.language}"])
        if stream.title:
            cmd.extend([f"-metadata:s:a:{i}", f"title={stream.title}"])
        elif stream.channels and stream.language:
            # Auto-generate title from language and channels
            ch_label = f"{stream.channels}.0" if stream.channels <= 2 else f"{stream.channels - 1}.1"
            cmd.extend([f"-metadata:s:a:{i}", f"title={ch_label}"])

    # Subtitle codec
    if subtitle_mode == "embed":
        cmd.extend(["-c:s", "mov_text"])

        # Subtitle metadata (language)
        out_sub_idx = 0
        for stream in media_info.subtitle_streams:
            action = decision.stream_actions.get(stream.index, "skip")
            if action in ("copy", "convert_to_mov_text"):
                if stream.language:
                    cmd.extend([f"-metadata:s:s:{out_sub_idx}", f"language={stream.language}"])
                if stream.title:
                    cmd.extend([f"-metadata:s:s:{out_sub_idx}", f"title={stream.title}"])
                out_sub_idx += 1

        for ext_sub in media_info.external_subtitles:
            cmd.extend([f"-metadata:s:s:{out_sub_idx}", f"language={ext_sub.language}"])
            out_sub_idx += 1

    elif subtitle_mode == "skip":
        cmd.extend(["-sn"])

    # MP4 optimizations
    cmd.extend(["-movflags", "+faststart"])

    # Force mp4 format (m4v extension triggers 'ipod' muxer which doesn't support HEVC)
    cmd.extend(["-f", "mp4"])

    # Output
    cmd.append(str(output_path))

    return cmd


def transcode(
    media_info: MediaInfo,
    decision: TranscodeDecision,
    output_path: Path,
    quality: str = "balanced",
    hw_accel: bool = True,
    subtitle_mode: str = "embed",
    burn_bitmap_subs: bool = False,
    progress_callback: Callable[[float], None] | None = None,
) -> Path:
    """Transcode a media file to iPad-compatible M4V."""
    audio_actions = classify_all_audio(media_info.audio_streams)

    cmd = build_ffmpeg_command(
        media_info=media_info,
        decision=decision,
        audio_actions=audio_actions,
        output_path=output_path,
        quality=quality,
        hw_accel=hw_accel,
        subtitle_mode=subtitle_mode,
        burn_bitmap_subs=burn_bitmap_subs,
    )

    # Add progress reporting flag
    cmd.insert(1, "-progress")
    cmd.insert(2, "pipe:1")

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        raise TranscodeError("ffmpeg not found. Install ffmpeg: brew install ffmpeg")

    duration = media_info.duration or 1.0

    # Parse progress from ffmpeg
    if process.stdout:
        for line in process.stdout:
            line = line.strip()
            if line.startswith("out_time_ms="):
                try:
                    time_ms = int(line.split("=")[1])
                    pct = min(time_ms / (duration * 1_000_000), 1.0)
                    if progress_callback:
                        progress_callback(pct)
                except (ValueError, ZeroDivisionError):
                    pass

    return_code = process.wait()
    if return_code != 0:
        stderr = process.stderr.read() if process.stderr else "unknown error"
        raise TranscodeError(f"ffmpeg exited with code {return_code}: {stderr}")

    if not output_path.exists():
        raise TranscodeError(f"Output file was not created: {output_path}")

    return output_path
