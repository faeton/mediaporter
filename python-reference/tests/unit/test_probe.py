"""Tests for ffprobe wrapper."""

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from mediaporter.exceptions import ProbeError
from mediaporter.probe import probe_file, _parse_stream


SAMPLE_FFPROBE_OUTPUT = json.dumps({
    "format": {
        "format_name": "matroska,webm",
        "duration": "7200.000000",
        "bit_rate": "5000000",
    },
    "streams": [
        {
            "index": 0,
            "codec_type": "video",
            "codec_name": "hevc",
            "profile": "Main 10",
            "level": 150,
            "width": 1920,
            "height": 1080,
            "pix_fmt": "yuv420p10le",
            "tags": {},
            "disposition": {"default": 1, "forced": 0},
        },
        {
            "index": 1,
            "codec_type": "audio",
            "codec_name": "dts",
            "channels": 6,
            "channel_layout": "5.1(side)",
            "sample_rate": "48000",
            "bit_rate": "1536000",
            "tags": {"language": "eng", "title": "DTS-HD MA 5.1"},
            "disposition": {"default": 1, "forced": 0},
        },
        {
            "index": 2,
            "codec_type": "subtitle",
            "codec_name": "subrip",
            "tags": {"language": "eng"},
            "disposition": {"default": 0, "forced": 0},
        },
    ],
})


@patch("mediaporter.probe.subprocess.run")
@patch("mediaporter.probe.Path.exists", return_value=True)
def test_probe_file(mock_exists, mock_run):
    mock_run.return_value = MagicMock(
        stdout=SAMPLE_FFPROBE_OUTPUT,
        returncode=0,
    )

    mi = probe_file("/tmp/test.mkv")

    assert mi.format_name == "matroska,webm"
    assert mi.duration == 7200.0
    assert len(mi.video_streams) == 1
    assert mi.video_streams[0].codec_name == "hevc"
    assert mi.video_streams[0].width == 1920
    assert len(mi.audio_streams) == 1
    assert mi.audio_streams[0].codec_name == "dts"
    assert mi.audio_streams[0].channels == 6
    assert mi.audio_streams[0].language == "eng"
    assert len(mi.subtitle_streams) == 1
    assert mi.subtitle_streams[0].codec_name == "subrip"


def test_probe_file_not_found():
    with pytest.raises(ProbeError, match="File not found"):
        probe_file("/nonexistent/path.mkv")


@patch("mediaporter.probe.subprocess.run")
@patch("mediaporter.probe.Path.exists", return_value=True)
def test_probe_skips_attached_pic(mock_exists, mock_run):
    output = json.dumps({
        "format": {"format_name": "matroska", "duration": "100"},
        "streams": [
            {"index": 0, "codec_type": "video", "codec_name": "mjpeg",
             "disposition": {"attached_pic": 1}},
            {"index": 1, "codec_type": "video", "codec_name": "hevc",
             "width": 1920, "height": 1080, "disposition": {}},
        ],
    })
    mock_run.return_value = MagicMock(stdout=output, returncode=0)

    mi = probe_file("/tmp/test.mkv")
    assert len(mi.video_streams) == 1
    assert mi.video_streams[0].codec_name == "hevc"
