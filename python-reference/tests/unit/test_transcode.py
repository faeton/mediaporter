"""Tests for ffmpeg command building."""

from pathlib import Path

from mediaporter.audio import classify_all_audio
from mediaporter.compat import TranscodeDecision
from mediaporter.probe import MediaInfo, StreamInfo
from mediaporter.transcode import build_ffmpeg_command


def _mi(video_codec="hevc", audio_codec="aac", fmt="matroska,webm"):
    return MediaInfo(
        path=Path("/tmp/test.mkv"),
        format_name=fmt,
        duration=100.0,
        video_streams=[StreamInfo(
            index=0, codec_type="video", codec_name=video_codec,
            width=1920, height=1080,
        )],
        audio_streams=[StreamInfo(
            index=1, codec_type="audio", codec_name=audio_codec,
            channels=2,
        )],
    )


def test_copy_hevc_adds_hvc1_tag():
    mi = _mi("hevc", "aac")
    decision = TranscodeDecision(stream_actions={0: "copy", 1: "copy"})
    audio_actions = classify_all_audio(mi.audio_streams)

    cmd = build_ffmpeg_command(mi, decision, audio_actions, Path("/tmp/out.m4v"), hw_accel=False)

    assert "-c:v" in cmd
    idx = cmd.index("-c:v")
    assert cmd[idx + 1] == "copy"
    assert "-tag:v" in cmd
    tag_idx = cmd.index("-tag:v")
    assert cmd[tag_idx + 1] == "hvc1"


def test_uses_mp4_format():
    mi = _mi()
    decision = TranscodeDecision(stream_actions={0: "copy", 1: "copy"})
    audio_actions = classify_all_audio(mi.audio_streams)

    cmd = build_ffmpeg_command(mi, decision, audio_actions, Path("/tmp/out.m4v"), hw_accel=False)

    assert "-f" in cmd
    idx = cmd.index("-f")
    assert cmd[idx + 1] == "mp4"


def test_faststart():
    mi = _mi()
    decision = TranscodeDecision(stream_actions={0: "copy", 1: "copy"})
    audio_actions = classify_all_audio(mi.audio_streams)

    cmd = build_ffmpeg_command(mi, decision, audio_actions, Path("/tmp/out.m4v"), hw_accel=False)

    assert "-movflags" in cmd
    idx = cmd.index("-movflags")
    assert cmd[idx + 1] == "+faststart"


def test_transcode_video_uses_libx265():
    mi = _mi("vp9", "aac")
    decision = TranscodeDecision(
        stream_actions={0: "transcode", 1: "copy"}, needs_transcode=True
    )
    audio_actions = classify_all_audio(mi.audio_streams)

    cmd = build_ffmpeg_command(mi, decision, audio_actions, Path("/tmp/out.m4v"), hw_accel=False)

    idx = cmd.index("-c:v")
    assert cmd[idx + 1] == "libx265"
    assert "-tag:v" in cmd


def test_transcode_audio_to_aac():
    mi = _mi("hevc", "dts")
    mi.audio_streams[0].channels = 6
    decision = TranscodeDecision(
        stream_actions={0: "copy", 1: "transcode"}, needs_transcode=True
    )
    audio_actions = classify_all_audio(mi.audio_streams)

    cmd = build_ffmpeg_command(mi, decision, audio_actions, Path("/tmp/out.m4v"), hw_accel=False)

    assert "-c:a:0" in cmd
    idx = cmd.index("-c:a:0")
    assert cmd[idx + 1] == "aac"


def test_skip_subtitles():
    mi = _mi()
    decision = TranscodeDecision(stream_actions={0: "copy", 1: "copy"})
    audio_actions = classify_all_audio(mi.audio_streams)

    cmd = build_ffmpeg_command(
        mi, decision, audio_actions, Path("/tmp/out.m4v"),
        hw_accel=False, subtitle_mode="skip",
    )

    assert "-sn" in cmd
