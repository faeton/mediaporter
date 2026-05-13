"""Subtitle detection, scanning, and language handling."""

from __future__ import annotations

from pathlib import Path

from mediaporter.probe import ExternalSubtitle, MediaInfo

SUB_EXTENSIONS = {".srt", ".ass", ".ssa"}

_LANG_MAP: dict[str, str] = {
    "en": "eng", "fr": "fra", "de": "deu", "es": "spa", "it": "ita",
    "pt": "por", "ru": "rus", "ja": "jpn", "ko": "kor", "zh": "zho",
    "ar": "ara", "hi": "hin", "nl": "nld", "pl": "pol", "sv": "swe",
    "no": "nor", "da": "dan", "fi": "fin", "cs": "ces", "sk": "slk",
    "hu": "hun", "ro": "ron", "bg": "bul", "hr": "hrv", "sr": "srp",
    "sl": "slv", "uk": "ukr", "el": "ell", "tr": "tur", "th": "tha",
    "vi": "vie", "he": "heb", "id": "ind", "ms": "msa",
    "eng": "eng", "fra": "fra", "fre": "fra", "deu": "deu", "ger": "deu",
    "spa": "spa", "ita": "ita", "por": "por", "rus": "rus", "jpn": "jpn",
    "kor": "kor", "zho": "zho", "chi": "zho", "ara": "ara", "hin": "hin",
    "nld": "nld", "dut": "nld", "pol": "pol", "swe": "swe", "nor": "nor",
    "dan": "dan", "fin": "fin", "ces": "ces", "cze": "ces", "slk": "slk",
    "slo": "slk", "hun": "hun", "ron": "ron", "rum": "ron", "bul": "bul",
    "hrv": "hrv", "srp": "srp", "slv": "slv", "ukr": "ukr", "ell": "ell",
    "gre": "ell", "tur": "tur", "tha": "tha", "vie": "vie", "heb": "heb",
    "ind": "ind", "msa": "msa", "may": "msa",
    "english": "eng", "french": "fra", "german": "deu", "spanish": "spa",
    "italian": "ita", "portuguese": "por", "russian": "rus", "japanese": "jpn",
    "korean": "kor", "chinese": "zho", "arabic": "ara", "hindi": "hin",
    "dutch": "nld", "polish": "pol", "swedish": "swe", "norwegian": "nor",
    "danish": "dan", "finnish": "fin", "czech": "ces", "slovak": "slk",
    "hungarian": "hun", "romanian": "ron", "bulgarian": "bul", "croatian": "hrv",
    "serbian": "srp", "slovenian": "slv", "ukrainian": "ukr", "greek": "ell",
    "turkish": "tur", "thai": "tha", "vietnamese": "vie", "hebrew": "heb",
    "indonesian": "ind", "malay": "msa",
}


def normalize_language(lang: str | None) -> str:
    """Normalize a language string to ISO 639-2/B (3-letter) code."""
    if not lang:
        return "und"
    return _LANG_MAP.get(lang.lower().strip(), lang.lower().strip())


def scan_external_subtitles(media_info: MediaInfo) -> MediaInfo:
    """Scan for external subtitle files matching the video filename."""
    video_path = media_info.path
    video_stem = video_path.stem
    parent = video_path.parent

    external_subs: list[ExternalSubtitle] = []

    for sub_path in sorted(parent.iterdir()):
        if sub_path.suffix.lower() not in SUB_EXTENSIONS:
            continue
        if not sub_path.is_file():
            continue

        sub_name = sub_path.stem
        if not sub_name.startswith(video_stem):
            continue

        remainder = sub_name[len(video_stem):]
        lang = "und"
        if remainder:
            parts = [p for p in remainder.split(".") if p and p.lower() != "forced"]
            for part in parts:
                normalized = normalize_language(part)
                if normalized != part.lower().strip() or len(part) == 3:
                    lang = normalized
                    break

        external_subs.append(ExternalSubtitle(
            path=sub_path,
            language=lang,
            format=sub_path.suffix.lstrip(".").lower(),
        ))

    media_info.external_subtitles = external_subs
    return media_info


def is_bitmap_subtitle(codec_name: str) -> bool:
    """Check if a subtitle codec is bitmap-based (PGS, VobSub, DVB)."""
    from mediaporter.compat import BITMAP_SUBTITLE_CODECS
    return codec_name.lower() in BITMAP_SUBTITLE_CODECS


def is_text_subtitle(codec_name: str) -> bool:
    """Check if a subtitle codec is text-based (SRT, ASS, SSA)."""
    from mediaporter.compat import TEXT_SUBTITLE_CODECS
    return codec_name.lower() in TEXT_SUBTITLE_CODECS
