"""Tests for pipeline orchestration."""

import tempfile
from pathlib import Path

from mediaporter.compat import TranscodeDecision
from mediaporter.metadata import EpisodeMetadata, MovieMetadata
from mediaporter.pipeline import FileJob, _build_sync_item, collect_video_files
from mediaporter.probe import MediaInfo, StreamInfo


def test_collect_video_files_single():
    with tempfile.TemporaryDirectory() as tmpdir:
        mkv = Path(tmpdir) / "movie.mkv"
        mkv.touch()
        result = collect_video_files([str(mkv)])
        assert len(result) == 1
        assert result[0].name == "movie.mkv"


def test_collect_video_files_directory():
    with tempfile.TemporaryDirectory() as tmpdir:
        (Path(tmpdir) / "a.mkv").touch()
        (Path(tmpdir) / "b.mp4").touch()
        (Path(tmpdir) / "c.txt").touch()
        result = collect_video_files([tmpdir])
        assert len(result) == 2
        names = {r.name for r in result}
        assert "a.mkv" in names
        assert "b.mp4" in names


def test_collect_filters_non_video_extensions():
    with tempfile.TemporaryDirectory() as tmpdir:
        (Path(tmpdir) / "photo.jpg").touch()
        (Path(tmpdir) / "doc.pdf").touch()
        result = collect_video_files([tmpdir])
        assert len(result) == 0


def _make_job(metadata=None, title="Test", duration=120.0, output_name="test.m4v"):
    with tempfile.NamedTemporaryFile(suffix=".m4v", delete=False) as f:
        f.write(b"\x00" * 100)
        output = Path(f.name)

    job = FileJob(
        input_path=Path("/tmp/test.mkv"),
        media_info=MediaInfo(
            path=Path("/tmp/test.mkv"),
            format_name="matroska",
            duration=duration,
            video_streams=[StreamInfo(
                index=0, codec_type="video", codec_name="hevc",
                width=1920, height=1080,
            )],
            audio_streams=[StreamInfo(
                index=1, codec_type="audio", codec_name="aac", channels=2,
            )],
        ),
        decision=TranscodeDecision(stream_actions={0: "copy", 1: "copy"}),
        metadata=metadata,
        output_path=output,
        status="ready",
    )
    return job


def test_build_sync_item_movie():
    meta = MovieMetadata(title="The Matrix", year="1999")
    job = _make_job(metadata=meta, duration=8100.0)
    item = _build_sync_item(job)

    assert item.is_movie is True
    assert item.is_tv_show is False
    assert item.title == "The Matrix"
    assert item.sort_name == "the matrix"
    assert item.duration_ms == 8100000
    assert item.is_hd is True  # 1920x1080


def test_build_sync_item_tv():
    meta = EpisodeMetadata(
        show_name="Breaking Bad",
        season=1,
        episode=1,
        episode_title="Pilot",
        episode_id="S01E01",
    )
    job = _make_job(metadata=meta, duration=3600.0)
    item = _build_sync_item(job)

    assert item.is_movie is False
    assert item.is_tv_show is True
    assert item.tv_show_name == "Breaking Bad"
    assert item.sort_tv_show_name == "breaking bad"
    assert item.season_number == 1
    assert item.episode_number == 1
    assert item.artist == "Breaking Bad"
    assert item.album == "Breaking Bad, Season 1"
    assert item.title == "Pilot"


def test_build_sync_item_no_metadata():
    job = _make_job(metadata=None)
    job.input_path = Path("/tmp/cool_video.mkv")
    item = _build_sync_item(job)

    assert item.is_movie is True
    assert item.title == "cool_video"


def test_build_sync_item_tv_no_episode_title():
    meta = EpisodeMetadata(show_name="Lost", season=2, episode=5)
    job = _make_job(metadata=meta)
    item = _build_sync_item(job)

    assert item.title == "Episode 5"
