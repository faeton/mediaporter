"""Tests for codec compatibility matrix."""

from pathlib import Path

from mediaporter.compat import evaluate_compatibility, get_hd_flag
from mediaporter.probe import MediaInfo, StreamInfo


def _mi(video_codec="hevc", audio_codec="aac", fmt="matroska,webm", sub_codec=None):
    streams = [StreamInfo(index=0, codec_type="video", codec_name=video_codec, width=1920, height=1080)]
    audio = [StreamInfo(index=1, codec_type="audio", codec_name=audio_codec, channels=2)]
    subs = []
    if sub_codec:
        subs = [StreamInfo(index=2, codec_type="subtitle", codec_name=sub_codec)]
    return MediaInfo(
        path=Path("/tmp/test.mkv"), format_name=fmt, duration=100.0,
        video_streams=streams, audio_streams=audio, subtitle_streams=subs,
    )


def test_h264_copy():
    d = evaluate_compatibility(_mi(video_codec="h264"))
    assert d.stream_actions[0] == "copy"
    assert not d.needs_transcode


def test_hevc_copy():
    d = evaluate_compatibility(_mi(video_codec="hevc"))
    assert d.stream_actions[0] == "copy"


def test_h265_copy():
    d = evaluate_compatibility(_mi(video_codec="h265"))
    assert d.stream_actions[0] == "copy"


def test_vp9_transcode():
    d = evaluate_compatibility(_mi(video_codec="vp9"))
    assert d.stream_actions[0] == "transcode"
    assert d.needs_transcode


def test_av1_transcode():
    d = evaluate_compatibility(_mi(video_codec="av1"))
    assert d.stream_actions[0] == "transcode"


def test_aac_copy():
    d = evaluate_compatibility(_mi(audio_codec="aac"))
    assert d.stream_actions[1] == "copy"


def test_ac3_copy():
    d = evaluate_compatibility(_mi(audio_codec="ac3"))
    assert d.stream_actions[1] == "copy"


def test_eac3_copy():
    d = evaluate_compatibility(_mi(audio_codec="eac3"))
    assert d.stream_actions[1] == "copy"


def test_dts_transcode():
    d = evaluate_compatibility(_mi(audio_codec="dts"))
    assert d.stream_actions[1] == "transcode"
    assert d.needs_transcode


def test_mp4_no_remux():
    d = evaluate_compatibility(_mi(fmt="mov,mp4,m4a,3gp,3g2,mj2"))
    assert not d.needs_remux


def test_mkv_needs_remux():
    d = evaluate_compatibility(_mi(fmt="matroska,webm"))
    assert d.needs_remux


def test_srt_convert():
    d = evaluate_compatibility(_mi(sub_codec="subrip"))
    assert d.stream_actions[2] == "convert_to_mov_text"


def test_pgs_skip():
    d = evaluate_compatibility(_mi(sub_codec="hdmv_pgs_subtitle"))
    assert d.stream_actions[2] == "skip"


def test_mov_text_copy():
    d = evaluate_compatibility(_mi(sub_codec="mov_text"))
    assert d.stream_actions[2] == "copy"


def test_hd_flag_1080p():
    assert get_hd_flag(1920, 1080) == 2


def test_hd_flag_720p():
    assert get_hd_flag(1280, 720) == 1


def test_hd_flag_sd():
    assert get_hd_flag(720, 480) == 0


def test_hd_flag_none():
    assert get_hd_flag(None, None) == 0


def test_hd_flag_4k():
    assert get_hd_flag(3840, 2160) == 2
