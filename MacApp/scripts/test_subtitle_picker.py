#!/usr/bin/env python3
"""Subtitle-picker hypothesis test.

iPad TV-app de-duplicates two subtitle tracks that share an ISO 639-2/T
language code. Two Russian SRTs (CafeSubs + Crunchyroll) come out the
other side as a single picker entry. This script builds N MP4 variants
that each set the same two `mov_text` tracks with different metadata
strategies, so we can drop them all on the device and see which strategy
(if any) makes the picker show both tracks.

Each variant has a distinct MP4 title metadata so it lands as its own
row in TV.app. The two subtitle tracks within each file have visibly
different content ("CafeSubs sub track" vs "Crunchyroll sub track") so
on playback the user can tell which physical track is being rendered.

Usage:
    MacApp/scripts/test_subtitle_picker.py [--source PATH] [--only A,B,...] [--no-build]

Drop the resulting `MacApp/scripts/test_fixtures/subtitle_picker/` on
the MacApp window and hit Upload. The files are already mp4 + h264 +
aac so MacApp skips transcode; the Tagger pass only adds movie atom
metadata and leaves the sub track metadata alone.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "test_fixtures" / "Breaking.Bad.S01E01.Pilot.1080p.mkv"
# Outputs go to the gitignored repo-root `test_fixtures/` so multi-GB
# variant builds never accidentally land in git.
OUT_DIR = REPO_ROOT / "test_fixtures" / "subtitle_picker"

# Take a 30 s clip so each variant uploads fast.
CLIP_START = "00:00:30"
CLIP_DURATION = "30"

# Two SRT bodies whose on-screen text identifies the physical track. If
# only one of them is reachable from the TV-app picker, the user can see
# which (CafeSubs vs Crunchyroll) by reading the rendered subtitle.
SRT_A = """\
1
00:00:01,000 --> 00:00:29,000
CafeSubs sub track (rus #1)
"""

SRT_B = """\
1
00:00:01,000 --> 00:00:29,000
Crunchyroll sub track (rus #2)
"""

SRT_UKR = """\
1
00:00:01,000 --> 00:00:29,000
Ukrainian sub track (control)
"""


@dataclass
class Variant:
    code: str
    title: str
    # ffmpeg arg fragments that go after the inputs:
    # - sub_maps:   `-map 1:0 -map 2:0` style
    # - sub_meta:   per-output-sub metadata + dispositions
    # - extra_inputs: extra `-i FILE` pairs beyond the carrier + 2 default SRTs
    sub_maps: list[str] = field(default_factory=list)
    sub_meta: list[str] = field(default_factory=list)
    extra_inputs: list[Path] = field(default_factory=list)
    notes: str = ""


def _v(code, title, **kw):
    return Variant(code=code, title=title, **kw)


# Standard 2-input fixture: carrier + SRT_A (input 1) + SRT_B (input 2).
# Variants override sub_maps/sub_meta and optionally add inputs (G).
VARIANTS: list[Variant] = [
    _v(
        "A", "SubPicker A Baseline",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:1", "language=rus",
        ],
        notes="bare rus, no titles, no handler_name, no dispositions",
    ),
    _v(
        "B", "SubPicker B TitleOnly",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "title=CafeSubs",
            "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:1", "title=Crunchyroll",
        ],
        notes="distinct title only — no handler_name",
    ),
    _v(
        "C", "SubPicker C HandlerOnly",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "handler_name=CafeSubs",
            "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:1", "handler_name=Crunchyroll",
        ],
        notes="distinct handler_name only — no title",
    ),
    _v(
        "D", "SubPicker D TitleAndHandler",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "title=CafeSubs",
            "-metadata:s:s:0", "handler_name=CafeSubs",
            "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:1", "title=Crunchyroll",
            "-metadata:s:s:1", "handler_name=Crunchyroll",
        ],
        notes="current MacApp output: title + handler_name both set",
    ),
    _v(
        "E", "SubPicker E OneForced",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "title=CafeSubs",
            "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:1", "title=Crunchyroll",
            "-disposition:s:1", "forced",
        ],
        notes="second sub gets forced disposition",
    ),
    _v(
        "F", "SubPicker F QaaPrivate",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "title=CafeSubs",
            "-metadata:s:s:1", "language=qaa",     # ISO 639-2 private use
            "-metadata:s:s:1", "title=Crunchyroll",
        ],
        notes="second sub uses qaa (ISO private-use) so iOS can't dedup by lang",
    ),
    _v(
        "G", "SubPicker G LangVariants",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",     # 3-letter
            "-metadata:s:s:0", "title=CafeSubs",
            "-metadata:s:s:1", "language=ru",      # 2-letter
            "-metadata:s:s:1", "title=Crunchyroll",
        ],
        notes="rus (639-2) + ru (639-1) — iOS may treat them as separate",
    ),
    _v(
        "H", "SubPicker H OneDefault",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "title=CafeSubs",
            "-disposition:s:0", "default",
            "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:1", "title=Crunchyroll",
            "-disposition:s:1", "0",
        ],
        notes="first sub marked default, second cleared",
    ),
    _v(
        "I", "SubPicker I Control RUS+UKR",
        sub_maps=["-map", "1:0", "-map", "3:0"],   # SRT_A + SRT_UKR
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "title=CafeSubs",
            "-metadata:s:s:1", "language=ukr",
            "-metadata:s:s:1", "title=Ukrainian",
        ],
        notes="control: different languages — must show both in picker",
    ),
    _v(
        "J", "SubPicker J HearingImpaired",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "handler_name=CafeSubs",
            "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:1", "handler_name=Crunchyroll (CC)",
            "-disposition:s:1", "hearing_impaired",
        ],
        notes="second sub marked CC/SDH — different AVMediaSelectionGroup characteristic",
    ),
    # Round 2: F proved that only distinct language codes split a same-lang
    # pair. F's second entry shows up as "qaa" in the iOS picker because we
    # didn't set handler_name on it. K and L probe whether handler_name is
    # used as the picker label when the lang code is private-use.
    _v(
        "K", "SubPicker K RusPlusQaaNamed",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=rus",
            "-metadata:s:s:0", "handler_name=CafeSubs",
            "-metadata:s:s:1", "language=qaa",
            "-metadata:s:s:1", "handler_name=Crunchyroll",
        ],
        notes="rus(handler=CafeSubs) + qaa(handler=Crunchyroll) — does qaa entry show Crunchyroll or 'qaa'?",
    ),
    _v(
        "L", "SubPicker L QaaQabBothNamed",
        sub_maps=["-map", "1:0", "-map", "2:0"],
        sub_meta=[
            "-metadata:s:s:0", "language=qaa",
            "-metadata:s:s:0", "handler_name=CafeSubs",
            "-metadata:s:s:1", "language=qab",
            "-metadata:s:s:1", "handler_name=Crunchyroll",
        ],
        notes="both private-use codes (qaa + qab) — do both rows show handler names?",
    ),
]

# ffprobe-confirmed findings from a dry-run build (before device sync):
# - B (title only): mp4 muxer strips `title=` on subtitle streams entirely;
#   handler_name falls back to "SubtitleHandler" — Variant B becomes identical
#   to A. The MacApp's current dual-write (title + handler_name) leaves only
#   handler_name in the mp4; the title= line is dead weight.
# - G (2-letter `ru`): mp4 lang atom requires ISO 639-2/T; "ru" gets dropped
#   silently, the second sub ends up with NO language tag at all. Don't ship.
# - H (-disposition:s:0 default): mp4 muxer auto-sets default on the first
#   subtitle stream regardless; -disposition:s:1 0 is the no-op default.
#   Variant H is degenerate vs A.



def write_srt(path: Path, body: str) -> None:
    # SRT must be CRLF for some demuxers, but ffmpeg accepts LF.
    path.write_text(body, encoding="utf-8")


def build_variant(variant: Variant, source: Path, srt_a: Path, srt_b: Path, srt_ukr: Path,
                  out_dir: Path) -> Path:
    out = out_dir / f"subpicker_{variant.code}.mp4"
    if out.exists():
        out.unlink()

    # Inputs: 0 = carrier (clip from source), 1 = SRT_A, 2 = SRT_B, 3 = SRT_UKR (only used by I)
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-ss", CLIP_START,
        "-i", str(source),
        "-i", str(srt_a),
        "-i", str(srt_b),
        "-i", str(srt_ukr),
        "-t", CLIP_DURATION,
        # Keep video + first audio from the carrier, drop everything else
        # so the variant's mp4 is small and reproducible.
        "-map", "0:v:0",
        "-map", "0:a:0?",
        # Sub maps + per-sub metadata come from the variant.
        *variant.sub_maps,
        "-c:v", "copy",
        "-c:a", "aac", "-b:a", "128k",
        "-c:s", "mov_text",
        *variant.sub_meta,
        # MP4 movie-level title — what TV.app shows in the library tile.
        "-metadata", f"title={variant.title}",
        "-metadata", "media_type=9",   # Movie stik
        # Strip chapters + data streams (same hygiene as MacApp transcoder).
        "-map_chapters", "-1", "-dn",
        "-avoid_negative_ts", "make_zero",
        "-reset_timestamps", "1",
        "-movflags", "+faststart",
        "-f", "mp4",
        str(out),
    ]

    print(f"[{variant.code}] ffmpeg -> {out.name}  ({variant.notes})", flush=True)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr[-1500:], file=sys.stderr)
        raise RuntimeError(f"ffmpeg failed for variant {variant.code}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                    help=f"Carrier MKV (default: {DEFAULT_SOURCE})")
    ap.add_argument("--only", help="Comma-separated variant codes (A,B,...)")
    ap.add_argument("--no-build", action="store_true",
                    help="Skip ffmpeg; just print what would be built")
    args = ap.parse_args()

    if not args.source.exists():
        sys.exit(f"source not found: {args.source}")
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found on PATH (brew install ffmpeg)")

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    only: set[str] | None = None
    if args.only:
        only = {c.strip().upper() for c in args.only.split(",") if c.strip()}
    variants = [v for v in VARIANTS if not only or v.code in only]
    if not variants:
        sys.exit("no variants selected")

    if args.no_build:
        for v in variants:
            print(f"[{v.code}] {v.title}  ({v.notes})")
        return 0

    with tempfile.TemporaryDirectory(prefix="subpicker-srt-") as td:
        td_path = Path(td)
        srt_a = td_path / "a.srt"
        srt_b = td_path / "b.srt"
        srt_ukr = td_path / "ukr.srt"
        write_srt(srt_a, SRT_A)
        write_srt(srt_b, SRT_B)
        write_srt(srt_ukr, SRT_UKR)

        for v in variants:
            build_variant(v, args.source, srt_a, srt_b, srt_ukr, OUT_DIR)

    print(f"\nbuilt {len(variants)} variant(s) in {OUT_DIR}")
    print("drag the directory into MacApp, then hit Upload.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
