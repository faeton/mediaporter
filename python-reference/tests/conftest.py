"""Shared test fixtures."""

from __future__ import annotations

import pytest
from pathlib import Path

from mediaporter.probe import MediaInfo, StreamInfo


@pytest.fixture
def sample_video_stream() -> StreamInfo:
    return StreamInfo(
        index=0,
        codec_type="video",
        codec_name="hevc",
        width=1920,
        height=1080,
        pix_fmt="yuv420p",
    )


@pytest.fixture
def sample_audio_stream() -> StreamInfo:
    return StreamInfo(
        index=1,
        codec_type="audio",
        codec_name="aac",
        channels=2,
        sample_rate=48000,
        language="eng",
    )


@pytest.fixture
def sample_dts_audio_stream() -> StreamInfo:
    return StreamInfo(
        index=1,
        codec_type="audio",
        codec_name="dts",
        channels=6,
        sample_rate=48000,
        language="eng",
        title="5.1",
    )


@pytest.fixture
def sample_media_info(sample_video_stream, sample_audio_stream) -> MediaInfo:
    return MediaInfo(
        path=Path("/tmp/test.mkv"),
        format_name="matroska,webm",
        duration=7200.0,
        bit_rate=5000000,
        video_streams=[sample_video_stream],
        audio_streams=[sample_audio_stream],
    )


@pytest.fixture
def mp4_media_info(sample_video_stream, sample_audio_stream) -> MediaInfo:
    return MediaInfo(
        path=Path("/tmp/test.mp4"),
        format_name="mov,mp4,m4a,3gp,3g2,mj2",
        duration=3600.0,
        bit_rate=5000000,
        video_streams=[sample_video_stream],
        audio_streams=[sample_audio_stream],
    )
