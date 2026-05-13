"""Tests for ATC sync plist building — critical for protocol correctness."""

import datetime
import plistlib
from pathlib import Path

import pytest

from mediaporter.sync.atc import ATCSession, SyncItem, _SyncFileInfo
from mediaporter.sync.device import DeviceInfo


def _movie_item(**overrides):
    defaults = dict(
        file_path=Path("/tmp/test.m4v"),
        title="Test Movie",
        sort_name="test movie",
        duration_ms=7200000,
        file_size=1000000,
        is_movie=True,
        is_tv_show=False,
    )
    defaults.update(overrides)
    return SyncItem(**defaults)


def _tv_item(**overrides):
    defaults = dict(
        file_path=Path("/tmp/test.m4v"),
        title="Pilot",
        sort_name="pilot",
        duration_ms=3600000,
        file_size=1000000,
        is_movie=False,
        is_tv_show=True,
        tv_show_name="Breaking Bad",
        sort_tv_show_name="breaking bad",
        season_number=1,
        episode_number=1,
        episode_sort_id=1,
        artist="Breaking Bad",
        sort_artist="breaking bad",
        album="Breaking Bad, Season 1",
        sort_album="breaking bad, season 1",
        album_artist="Breaking Bad",
        sort_album_artist="breaking bad",
    )
    defaults.update(overrides)
    return SyncItem(**defaults)


def _file_info(item, asset_id=123456789012345678):
    return _SyncFileInfo(
        item=item,
        asset_id=asset_id,
        device_path="/iTunes_Control/Music/F23/ABCD.mp4",
        slot="F23",
    )


def _build(items, anchor=1):
    """Helper to build and parse a sync plist."""
    # Create a dummy session just for the build method
    dummy_device = DeviceInfo(udid="test", handle=None)
    session = ATCSession.__new__(ATCSession)
    session._cf = None  # not needed for plist building
    files = [_file_info(item, asset_id=100000000000000000 + i) for i, item in enumerate(items)]
    data = session.build_sync_plist(files, anchor)
    return data, plistlib.loads(data)


class TestMoviePlist:
    def test_is_binary_format(self):
        data, _ = _build([_movie_item()])
        assert data[:6] == b"bplist"

    def test_has_revision(self):
        _, plist = _build([_movie_item()], anchor=10)
        assert plist["revision"] == 10

    def test_has_timestamp(self):
        _, plist = _build([_movie_item()])
        assert isinstance(plist["timestamp"], datetime.datetime)

    def test_naive_datetime(self):
        _, plist = _build([_movie_item()])
        assert plist["timestamp"].tzinfo is None

    def test_has_update_db_info_first(self):
        _, plist = _build([_movie_item()])
        assert plist["operations"][0]["operation"] == "update_db_info"

    def test_has_insert_track(self):
        _, plist = _build([_movie_item()])
        assert plist["operations"][1]["operation"] == "insert_track"

    def test_is_movie_true(self):
        _, plist = _build([_movie_item()])
        item = plist["operations"][1]["item"]
        assert item["is_movie"] is True
        assert "is_tv_show" not in item

    def test_location_kind(self):
        _, plist = _build([_movie_item()])
        location = plist["operations"][1]["location"]
        assert location["kind"] == "MPEG-4 video file"

    def test_has_video_info(self):
        _, plist = _build([_movie_item()])
        vi = plist["operations"][1]["video_info"]
        assert "has_alternate_audio" in vi
        assert "is_anamorphic" in vi
        assert "has_subtitles" in vi
        assert "is_hd" in vi

    def test_has_avformat_info(self):
        _, plist = _build([_movie_item()])
        af = plist["operations"][1]["avformat_info"]
        assert "bit_rate" in af
        assert "audio_format" in af
        assert "channels" in af

    def test_has_item_stats(self):
        _, plist = _build([_movie_item()])
        stats = plist["operations"][1]["item_stats"]
        assert stats["has_been_played"] is False

    def test_title_and_sort_name(self):
        _, plist = _build([_movie_item(title="My Movie", sort_name="my movie")])
        item = plist["operations"][1]["item"]
        assert item["title"] == "My Movie"
        assert item["sort_name"] == "my movie"

    def test_duration(self):
        _, plist = _build([_movie_item(duration_ms=5000)])
        item = plist["operations"][1]["item"]
        assert item["total_time_ms"] == 5000

    def test_remember_bookmark(self):
        _, plist = _build([_movie_item()])
        item = plist["operations"][1]["item"]
        assert item["remember_bookmark"] is True

    def test_is_hd_flag(self):
        _, plist = _build([_movie_item(is_hd=True)])
        vi = plist["operations"][1]["video_info"]
        assert vi["is_hd"] is True


class TestTVPlist:
    def test_is_tv_show_true(self):
        _, plist = _build([_tv_item()])
        item = plist["operations"][1]["item"]
        assert item["is_tv_show"] is True
        assert "is_movie" not in item

    def test_tv_show_name(self):
        _, plist = _build([_tv_item()])
        item = plist["operations"][1]["item"]
        assert item["tv_show_name"] == "Breaking Bad"
        assert item["sort_tv_show_name"] == "breaking bad"

    def test_season_episode(self):
        _, plist = _build([_tv_item()])
        item = plist["operations"][1]["item"]
        assert item["season_number"] == 1
        assert item["episode_number"] == 1
        assert item["episode_sort_id"] == 1

    def test_artist_album(self):
        _, plist = _build([_tv_item()])
        item = plist["operations"][1]["item"]
        assert item["artist"] == "Breaking Bad"
        assert item["album"] == "Breaking Bad, Season 1"


class TestMultiFilePlist:
    def test_multiple_insert_tracks(self):
        items = [_movie_item(title="Movie 1"), _movie_item(title="Movie 2")]
        _, plist = _build(items)
        ops = plist["operations"]
        assert ops[0]["operation"] == "update_db_info"
        assert ops[1]["operation"] == "insert_track"
        assert ops[2]["operation"] == "insert_track"
        assert ops[1]["item"]["title"] == "Movie 1"
        assert ops[2]["item"]["title"] == "Movie 2"

    def test_unique_pids(self):
        items = [_movie_item(), _movie_item()]
        _, plist = _build(items)
        pids = [op["pid"] for op in plist["operations"] if op["operation"] == "insert_track"]
        assert len(set(pids)) == 2

    def test_mixed_movie_tv(self):
        items = [_movie_item(title="A Movie"), _tv_item(title="A TV Episode")]
        _, plist = _build(items)
        ops = [o for o in plist["operations"] if o["operation"] == "insert_track"]
        assert ops[0]["item"]["is_movie"] is True
        assert ops[1]["item"]["is_tv_show"] is True
