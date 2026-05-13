"""Tests for metadata parsing and lookup."""

from pathlib import Path
from unittest.mock import patch, MagicMock

from mediaporter.metadata import (
    EpisodeMetadata,
    MovieMetadata,
    lookup_metadata,
    parse_filename,
)


def test_parse_movie_filename():
    result = parse_filename(Path("The.Matrix.1999.1080p.BluRay.mkv"))
    assert result.get("title") == "The Matrix"
    assert result.get("year") == 1999


def test_parse_tv_filename():
    result = parse_filename(Path("Breaking.Bad.S01E01.720p.mkv"))
    assert result.get("title") == "Breaking Bad"
    assert result.get("season") == 1
    assert result.get("episode") == 1
    assert result.get("type") == "episode"


def test_parse_tv_filename_alt():
    result = parse_filename(Path("Game.of.Thrones.S08E06.1080p.mkv"))
    assert result.get("title") == "Game of Thrones"
    assert result.get("season") == 8
    assert result.get("episode") == 6


def test_lookup_movie_no_api_key():
    meta = lookup_metadata(Path("The.Matrix.1999.mkv"))
    assert isinstance(meta, MovieMetadata)
    assert meta.title == "The Matrix"
    assert meta.year == "1999"


def test_lookup_tv_no_api_key():
    meta = lookup_metadata(Path("Breaking.Bad.S01E01.mkv"))
    assert isinstance(meta, EpisodeMetadata)
    assert meta.show_name == "Breaking Bad"
    assert meta.season == 1
    assert meta.episode == 1
    assert meta.episode_id == "S01E01"


def test_lookup_with_show_override():
    meta = lookup_metadata(
        Path("random_file.mkv"),
        show_override="The Wire",
        season_override=3,
        episode_override=5,
    )
    assert isinstance(meta, EpisodeMetadata)
    assert meta.show_name == "The Wire"
    assert meta.season == 3
    assert meta.episode == 5


def test_lookup_movie_with_type_override():
    meta = lookup_metadata(
        Path("Breaking.Bad.S01E01.mkv"),
        media_type="movie",
    )
    assert isinstance(meta, MovieMetadata)
