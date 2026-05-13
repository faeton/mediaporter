"""Tests for subtitle handling."""

import tempfile
from pathlib import Path

from mediaporter.probe import MediaInfo
from mediaporter.subtitles import (
    is_bitmap_subtitle,
    is_text_subtitle,
    normalize_language,
    scan_external_subtitles,
)


def test_normalize_en():
    assert normalize_language("en") == "eng"


def test_normalize_eng():
    assert normalize_language("eng") == "eng"


def test_normalize_english():
    assert normalize_language("english") == "eng"


def test_normalize_fre():
    assert normalize_language("fre") == "fra"


def test_normalize_german():
    assert normalize_language("german") == "deu"


def test_normalize_none():
    assert normalize_language(None) == "und"


def test_normalize_unknown():
    assert normalize_language("xxx") == "xxx"


def test_normalize_case():
    assert normalize_language("EN") == "eng"
    assert normalize_language("English") == "eng"


def test_is_bitmap_pgs():
    assert is_bitmap_subtitle("hdmv_pgs_subtitle")


def test_is_bitmap_dvdsub():
    assert is_bitmap_subtitle("dvd_subtitle")


def test_is_not_bitmap_srt():
    assert not is_bitmap_subtitle("subrip")


def test_is_text_srt():
    assert is_text_subtitle("subrip")


def test_is_text_ass():
    assert is_text_subtitle("ass")


def test_is_not_text_pgs():
    assert not is_text_subtitle("hdmv_pgs_subtitle")


def test_scan_external_subtitles():
    with tempfile.TemporaryDirectory() as tmpdir:
        video = Path(tmpdir) / "movie.mkv"
        video.touch()
        srt_eng = Path(tmpdir) / "movie.eng.srt"
        srt_eng.write_text("1\n00:00:01,000 --> 00:00:02,000\nHello\n")
        srt_fra = Path(tmpdir) / "movie.fr.srt"
        srt_fra.write_text("1\n00:00:01,000 --> 00:00:02,000\nBonjour\n")
        unrelated = Path(tmpdir) / "other.srt"
        unrelated.write_text("nope")

        mi = MediaInfo(path=video, format_name="matroska", duration=100.0)
        mi = scan_external_subtitles(mi)

        assert len(mi.external_subtitles) == 2
        langs = {s.language for s in mi.external_subtitles}
        assert "eng" in langs
        assert "fra" in langs


def test_scan_no_subs():
    with tempfile.TemporaryDirectory() as tmpdir:
        video = Path(tmpdir) / "movie.mkv"
        video.touch()

        mi = MediaInfo(path=video, format_name="matroska", duration=100.0)
        mi = scan_external_subtitles(mi)
        assert len(mi.external_subtitles) == 0
