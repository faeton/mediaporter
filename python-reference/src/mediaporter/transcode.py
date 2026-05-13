"""FFmpeg transcoding engine — command building and execution."""

from __future__ import annotations

import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

# Registry of active ffmpeg processes so callers (e.g. the pipeline) can
# terminate them on Ctrl+C without having to plumb a handle through every call.
_active_procs: set[subprocess.Popen] = set()
_active_procs_lock = threading.Lock()


def cancel_all() -> None:
    """Terminate every ffmpeg process currently running under transcode()."""
    with _active_procs_lock:
        procs = list(_active_procs)
    for p in procs:
        try:
            p.terminate()
        except Exception:
            pass
    # Give them a moment to exit cleanly, then hard-kill stragglers.
    for p in procs:
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                p.kill()
            except Exception:
                pass

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

    # Audio codecs (per output track).
    #
    # AAC and EAC3 are iPad-compatible AND appear in the TV app's audio
    # selector — copy them through untouched. AC3 decodes but is silently
    # excluded from the selector, so we transcode it to AAC (with every
    # other incompatible codec). See research/docs/AUDIO_SWITCHER_RULE.md.
    selected_actions = [audio_actions[i] for i in audio_indices]
    selected_streams = [media_info.audio_streams[i] for i in audio_indices]

    for out_idx, (action, _stream) in enumerate(zip(selected_actions, selected_streams)):
        if action.action == "copy":
            cmd.extend([f"-c:a:{out_idx}", "copy"])
        else:
            cmd.extend([f"-c:a:{out_idx}", "aac"])
            if action.target_bitrate:
                cmd.extend([f"-b:a:{out_idx}", action.target_bitrate])
            if action.target_channels:
                cmd.extend([f"-ac:a:{out_idx}", str(action.target_channels)])

    # Audio disposition — exactly one default track.
    #
    # The TV app switcher breaks if multiple audio tracks carry the `default`
    # flag (variant A in the test matrix). The mp4 muxer will happily copy
    # multiple defaults through from the source, so we pin a:0 as the only
    # default and clear the rest regardless of what the source had.
    for out_idx in range(len(audio_indices)):
        flag = "default" if out_idx == 0 else "0"
        cmd.extend([f"-disposition:a:{out_idx}", flag])

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
    verbose: bool = False,
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
            bufsize=1,  # line-buffered so progress updates arrive promptly
        )
    except FileNotFoundError:
        raise TranscodeError("ffmpeg not found. Install ffmpeg: brew install ffmpeg")

    with _active_procs_lock:
        _active_procs.add(process)

    # Drain stderr on a background thread. If we don't, ffmpeg will block on
    # stderr writes once the OS pipe buffer fills (~64 KB on macOS) — which
    # freezes its stdout progress output and appears as a stuck % in the UI.
    # We also expose the tail in verbose mode so the user can see what ffmpeg
    # is actually doing when something gets stuck.
    stderr_tail: list[str] = []
    tag = output_path.name

    def _drain_stderr() -> None:
        if not process.stderr:
            return
        try:
            for line in process.stderr:
                stderr_tail.append(line)
                if len(stderr_tail) > 200:
                    del stderr_tail[:100]  # keep a rolling tail
                if verbose:
                    sys.stderr.write(f"[{tag}] {line}")
                    sys.stderr.flush()
        except Exception:
            pass

    stderr_thread = threading.Thread(target=_drain_stderr, daemon=True)
    stderr_thread.start()

    duration = media_info.duration or 1.0

    try:
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
    except BaseException:
        # KeyboardInterrupt or any other unwind: make sure ffmpeg dies so we
        # don't leave a zombie transcoding a 15 GB file in the background.
        try:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        except Exception:
            pass
        raise
    finally:
        with _active_procs_lock:
            _active_procs.discard(process)
        stderr_thread.join(timeout=2)

    if return_code != 0:
        err = "".join(stderr_tail[-50:]).strip() or "unknown error"
        raise TranscodeError(f"ffmpeg exited with code {return_code}: {err}")

    if not output_path.exists():
        raise TranscodeError(f"Output file was not created: {output_path}")

    return output_path
