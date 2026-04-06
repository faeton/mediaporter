"""FFmpeg transcoding engine — command building and execution."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from mediaporter.audio import AudioAction, classify_all_audio
from mediaporter.compat import TEXT_SUBTITLE_CODECS, TranscodeDecision
from mediaporter.exceptions import TranscodeError
from mediaporter.probe import MediaInfo


@dataclass
class QualityPreset:
    """Encoding quality settings."""
    crf: int
    preset: str
    vt_quality: int


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
    selected_audio: list[int] | None = None,
    selected_subtitles: list[int] | None = None,
    selected_external_subs: list[int] | None = None,
) -> list[str]:
    """Build the complete ffmpeg command for transcoding."""
    preset = QUALITY_PRESETS[quality]
    use_vt = hw_accel and _detect_videotoolbox()

    cmd: list[str] = ["ffmpeg", "-hide_banner", "-y"]

    cmd.extend(["-i", str(media_info.path)])

    # Track which external subs are included (for correct ffmpeg input indices)
    ext_sub_input_map: dict[int, int] = {}  # ext_idx -> ffmpeg_input_idx
    if subtitle_mode == "embed":
        next_input = 1
        for ext_idx, ext_sub in enumerate(media_info.external_subtitles):
            if selected_external_subs is not None and ext_idx not in selected_external_subs:
                continue
            cmd.extend(["-i", str(ext_sub.path)])
            ext_sub_input_map[ext_idx] = next_input
            next_input += 1

    if media_info.video_streams:
        cmd.extend(["-map", "0:v:0"])

    # Audio: map selected tracks (or all if no selection)
    audio_indices = selected_audio if selected_audio is not None else list(range(len(media_info.audio_streams)))
    for i in audio_indices:
        cmd.extend(["-map", f"0:a:{i}"])

    sub_output_idx = 0
    if subtitle_mode == "embed":
        for i, stream in enumerate(media_info.subtitle_streams):
            if selected_subtitles is not None and i not in selected_subtitles:
                continue
            action = decision.stream_actions.get(stream.index, "skip")
            if action in ("copy", "convert_to_mov_text"):
                cmd.extend(["-map", f"0:s:{i}"])
                sub_output_idx += 1

        for ext_idx in ext_sub_input_map:
            input_idx = ext_sub_input_map[ext_idx]
            cmd.extend(["-map", f"{input_idx}:0"])
            sub_output_idx += 1

    if media_info.video_streams:
        v_stream = media_info.video_streams[0]
        v_action = decision.stream_actions.get(v_stream.index, "transcode")

        if v_action == "copy":
            cmd.extend(["-c:v", "copy"])
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

    # Audio codecs (per output track)
    # If multiple audio tracks have mixed codecs, normalize all to AAC
    # (iPad won't show audio switcher for mixed codec tracks)
    selected_actions = [audio_actions[i] for i in audio_indices]
    selected_streams = [media_info.audio_streams[i] for i in audio_indices]
    codecs_used = {s.codec_name.lower() for s in selected_streams}
    force_aac = len(audio_indices) > 1 and len(codecs_used) > 1

    for out_idx, (action, stream) in enumerate(zip(selected_actions, selected_streams)):
        if force_aac:
            # Normalize all tracks to AAC for iPad compatibility
            cmd.extend([f"-c:a:{out_idx}", "aac"])
            channels = stream.channels or 2
            if channels >= 6:
                cmd.extend([f"-b:a:{out_idx}", "384k"])
                cmd.extend([f"-ac:a:{out_idx}", "6"])
            else:
                cmd.extend([f"-b:a:{out_idx}", "256k"])
                cmd.extend([f"-ac:a:{out_idx}", str(channels)])
        elif action.action == "copy":
            cmd.extend([f"-c:a:{out_idx}", "copy"])
        else:
            cmd.extend([f"-c:a:{out_idx}", "aac"])
            if action.target_bitrate:
                cmd.extend([f"-b:a:{out_idx}", action.target_bitrate])
            if action.target_channels:
                cmd.extend([f"-ac:a:{out_idx}", str(action.target_channels)])

    # Audio metadata (per output track)
    for out_idx, src_idx in enumerate(audio_indices):
        stream = media_info.audio_streams[src_idx]
        if stream.language:
            cmd.extend([f"-metadata:s:a:{out_idx}", f"language={stream.language}"])
        if stream.title:
            cmd.extend([f"-metadata:s:a:{out_idx}", f"handler_name={stream.title}"])
        elif stream.channels and stream.language:
            ch_label = f"{stream.channels}.0" if stream.channels <= 2 else f"{stream.channels - 1}.1"
            cmd.extend([f"-metadata:s:a:{out_idx}", f"handler_name={ch_label}"])

    if subtitle_mode == "embed":
        cmd.extend(["-c:s", "mov_text"])

        out_sub_idx = 0
        for i, stream in enumerate(media_info.subtitle_streams):
            if selected_subtitles is not None and i not in selected_subtitles:
                continue
            action = decision.stream_actions.get(stream.index, "skip")
            if action in ("copy", "convert_to_mov_text"):
                if stream.language:
                    cmd.extend([f"-metadata:s:s:{out_sub_idx}", f"language={stream.language}"])
                if stream.title:
                    cmd.extend([f"-metadata:s:s:{out_sub_idx}", f"handler_name={stream.title}"])
                out_sub_idx += 1

        for ext_idx in ext_sub_input_map:
            ext_sub = media_info.external_subtitles[ext_idx]
            cmd.extend([f"-metadata:s:s:{out_sub_idx}", f"language={ext_sub.language}"])
            out_sub_idx += 1

    elif subtitle_mode == "skip":
        cmd.extend(["-sn"])

    cmd.extend(["-movflags", "+faststart"])
    cmd.extend(["-f", "mp4"])
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
    selected_audio: list[int] | None = None,
    selected_subtitles: list[int] | None = None,
    selected_external_subs: list[int] | None = None,
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
        selected_audio=selected_audio,
        selected_subtitles=selected_subtitles,
        selected_external_subs=selected_external_subs,
    )

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
