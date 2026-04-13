#!/usr/bin/env python3
"""Audio-language-switcher hypothesis test.

Builds 5 short MP4 variants from a single MKV source to isolate which
variable actually controls whether the iPad TV app's audio-language
selector appears. Each variant gets a distinctively labeled cover so the
test can be identified visually in the TV app, then all five are synced
to the connected device (one ATC session per variant).

Variants:
  A. Baseline           — 4 audio tracks copied, no disposition fix
  B. One Default        — as A, but only track 0 marked default
  C. Distinct Titles    — B + rewrite same-language titles to be unique
  D. AAC Normalized     — transcode everything to AAC stereo (control)
  E. Two Tracks         — only RU AC3 + EN EAC3 (two codecs, one default)

Usage:
    scripts/test_audio_switcher.py                 # build all + sync all
    scripts/test_audio_switcher.py --only A,B      # only A and B
    scripts/test_audio_switcher.py --no-sync       # build only
    scripts/test_audio_switcher.py --no-build      # sync existing files
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Make src/ importable when run as a script
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from mediaporter.sync import sync_files  # noqa: E402
from mediaporter.sync.atc import SyncItem  # noqa: E402


DEFAULT_SOURCE = Path(
    "/Users/faeton/Downloads/The.Luckiest.Man.in.America.2024.AMZN.WEB-DL.1080p.mkv"
)
OUT_DIR = ROOT / "test_fixtures" / "audio_switcher"
CLIP_START = "00:15:00"
CLIP_DURATION = "90"

COMMON_MAP = [
    "-map", "0:v:0",
    "-map", "0:a:0",
    "-map", "0:a:1",
    "-map", "0:a:2",
    "-map", "0:a:3",
]

DISPOSITION_ONE_DEFAULT = [
    "-disposition:a:0", "default",
    "-disposition:a:1", "0",
    "-disposition:a:2", "0",
    "-disposition:a:3", "0",
]

DISTINCT_META = [
    "-metadata:s:a:0", "language=rus",
    "-metadata:s:a:0", "title=RU HDRezka",
    "-metadata:s:a:1", "language=rus",
    "-metadata:s:a:1", "title=RU zaKADRY",
    "-metadata:s:a:2", "language=ukr",
    "-metadata:s:a:2", "title=UK HDRezka",
    "-metadata:s:a:3", "language=eng",
    "-metadata:s:a:3", "title=EN Original 5.1",
]


@dataclass
class Variant:
    code: str
    title: str                        # TV-app title
    cover_heading: str                # big line on cover
    cover_detail: list[str]           # smaller lines under heading
    ffmpeg_args: list[str]            # args between -i and output
    color: tuple[int, int, int] = field(default=(60, 60, 60))


VARIANTS: list[Variant] = [
    Variant(
        code="A",
        title="AudioSwitch A All Default",
        cover_heading="ALL DEFAULT",
        cover_detail=[
            "4 audio tracks",
            "every track is default",
            "ac3 / ac3 / aac / eac3",
            "(provokes bug)",
        ],
        ffmpeg_args=[
            *COMMON_MAP,
            "-c", "copy",
            "-disposition:a:0", "default",
            "-disposition:a:1", "default",
            "-disposition:a:2", "default",
            "-disposition:a:3", "default",
        ],
        color=(180, 40, 40),
    ),
    Variant(
        code="B",
        title="AudioSwitch B One Default",
        cover_heading="ONE DEFAULT",
        cover_detail=[
            "4 audio tracks",
            "only a:0 is default",
            "others disabled",
            "same mixed codecs",
        ],
        ffmpeg_args=[*COMMON_MAP, "-c", "copy", *DISPOSITION_ONE_DEFAULT],
        color=(200, 140, 20),
    ),
    Variant(
        code="C",
        title="AudioSwitch C Distinct",
        cover_heading="DISTINCT LABELS",
        cover_detail=[
            "B + unique titles",
            "RU HDRezka / RU zaKADRY",
            "UK HDRezka / EN 5.1",
            "lang tags set",
        ],
        ffmpeg_args=[
            *COMMON_MAP,
            "-c", "copy",
            *DISPOSITION_ONE_DEFAULT,
            *DISTINCT_META,
        ],
        color=(30, 120, 60),
    ),
    Variant(
        code="D",
        title="AudioSwitch D AAC norm",
        cover_heading="AAC NORMALIZED",
        cover_detail=[
            "4 tracks -> AAC 2ch",
            "uniform codec control",
            "(matches old pipeline)",
            "lang + titles set",
        ],
        ffmpeg_args=[
            *COMMON_MAP,
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ac", "2",
            *DISPOSITION_ONE_DEFAULT,
            *DISTINCT_META,
        ],
        color=(40, 80, 180),
    ),
    Variant(
        code="E",
        title="AudioSwitch E Two Tracks",
        cover_heading="TWO TRACKS",
        cover_detail=[
            "RU AC3 + EN EAC3",
            "only 2 streams",
            "one default",
            "isolates codec mix",
        ],
        ffmpeg_args=[
            "-map", "0:v:0",
            "-map", "0:a:0",   # rus ac3
            "-map", "0:a:3",   # eng eac3
            "-c", "copy",
            "-disposition:a:0", "default",
            "-disposition:a:1", "0",
            "-metadata:s:a:0", "language=rus",
            "-metadata:s:a:0", "title=RU HDRezka",
            "-metadata:s:a:1", "language=eng",
            "-metadata:s:a:1", "title=EN Original 5.1",
        ],
        color=(120, 40, 160),
    ),
    # ------------------------------------------------------------------
    # Second wave — pin down the codec-specific rule
    # ------------------------------------------------------------------
    Variant(
        code="F",
        title="AudioSwitch F AC3->AAC",
        cover_heading="AC3 -> AAC",
        cover_detail=[
            "transcode ac3 tracks",
            "to aac (cheap fix)",
            "aac + eac3 copy",
            "HYPOTHESIS FIX",
        ],
        ffmpeg_args=[
            *COMMON_MAP,
            "-c:v", "copy",
            "-c:a:0", "aac", "-b:a:0", "192k", "-ac:a:0", "2",
            "-c:a:1", "aac", "-b:a:1", "192k", "-ac:a:1", "2",
            "-c:a:2", "copy",
            "-c:a:3", "copy",
            *DISPOSITION_ONE_DEFAULT,
            *DISTINCT_META,
        ],
        color=(0, 140, 140),
    ),
    Variant(
        code="G",
        title="AudioSwitch G AC3->EAC3",
        cover_heading="AC3 -> EAC3",
        cover_detail=[
            "transcode ac3 tracks",
            "to eac3 (keep quality)",
            "aac + eac3 copy",
            "tests eac3 as target",
        ],
        ffmpeg_args=[
            *COMMON_MAP,
            "-c:v", "copy",
            "-c:a:0", "eac3", "-b:a:0", "192k", "-ac:a:0", "2",
            "-c:a:1", "eac3", "-b:a:1", "192k", "-ac:a:1", "2",
            "-c:a:2", "copy",
            "-c:a:3", "copy",
            *DISPOSITION_ONE_DEFAULT,
            *DISTINCT_META,
        ],
        color=(140, 60, 0),
    ),
    Variant(
        code="H",
        title="AudioSwitch H AAC+EAC3",
        cover_heading="AAC + EAC3",
        cover_detail=[
            "drop both ac3",
            "UK AAC + EN EAC3",
            "2 tracks, mixed codecs",
            "proves non-ac3 mix OK",
        ],
        ffmpeg_args=[
            "-map", "0:v:0",
            "-map", "0:a:2",   # ukr aac
            "-map", "0:a:3",   # eng eac3
            "-c", "copy",
            "-disposition:a:0", "default",
            "-disposition:a:1", "0",
            "-metadata:s:a:0", "language=ukr",
            "-metadata:s:a:0", "title=UK HDRezka",
            "-metadata:s:a:1", "language=eng",
            "-metadata:s:a:1", "title=EN Original 5.1",
        ],
        color=(0, 90, 120),
    ),
    Variant(
        code="I",
        title="AudioSwitch I No Default",
        cover_heading="NO DEFAULT (tried)",
        cover_detail=[
            "4 tracks copy",
            "distinct titles",
            "mp4 muxer forces a:0",
            "effectively same as C",
        ],
        ffmpeg_args=[
            *COMMON_MAP,
            "-c", "copy",
            "-disposition:a:0", "0",
            "-disposition:a:1", "0",
            "-disposition:a:2", "0",
            "-disposition:a:3", "0",
            *DISTINCT_META,
        ],
        color=(80, 80, 80),
    ),
    Variant(
        code="J",
        title="AudioSwitch J Two AC3",
        cover_heading="TWO AC3",
        cover_detail=[
            "only the 2 RU AC3",
            "nothing else",
            "expected: no switcher",
            "(both dropped)",
        ],
        ffmpeg_args=[
            "-map", "0:v:0",
            "-map", "0:a:0",   # rus ac3
            "-map", "0:a:1",   # rus ac3
            "-c", "copy",
            "-disposition:a:0", "default",
            "-disposition:a:1", "0",
            "-metadata:s:a:0", "language=rus",
            "-metadata:s:a:0", "title=RU HDRezka",
            "-metadata:s:a:1", "language=rus",
            "-metadata:s:a:1", "title=RU zaKADRY",
        ],
        color=(120, 20, 20),
    ),
    Variant(
        code="K",
        title="AudioSwitch K 3 Codecs",
        cover_heading="3 CODECS",
        cover_detail=[
            "one ac3 + aac + eac3",
            "distinct languages",
            "expected: aac+eac3 shown",
            "ac3 silently dropped",
        ],
        ffmpeg_args=[
            "-map", "0:v:0",
            "-map", "0:a:0",   # rus ac3
            "-map", "0:a:2",   # ukr aac
            "-map", "0:a:3",   # eng eac3
            "-c", "copy",
            "-disposition:a:0", "default",
            "-disposition:a:1", "0",
            "-disposition:a:2", "0",
            "-metadata:s:a:0", "language=rus",
            "-metadata:s:a:0", "title=RU HDRezka",
            "-metadata:s:a:1", "language=ukr",
            "-metadata:s:a:1", "title=UK HDRezka",
            "-metadata:s:a:2", "language=eng",
            "-metadata:s:a:2", "title=EN Original 5.1",
        ],
        color=(160, 120, 0),
    ),
]


def _font(size: int) -> ImageFont.FreeTypeFont:
    for path in (
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def _centered(draw, text, font, y, width, fill=(255, 255, 255)):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    x_offset = bbox[0]
    draw.text(((width - tw) / 2 - x_offset, y), text, fill=fill, font=font)
    return bbox[3] - bbox[1]


def make_poster(path: Path, variant: Variant) -> None:
    W, H = 600, 900
    img = Image.new("RGB", (W, H), variant.color)
    draw = ImageDraw.Draw(img)

    # Dark band at top
    draw.rectangle([(0, 0), (W, 160)], fill=(0, 0, 0))
    _centered(draw, "AUDIO SWITCHER TEST", _font(36), 40, W, fill=(230, 230, 230))
    _centered(draw, f"#{variant.code}", _font(70), 80, W, fill=(255, 255, 255))

    # Giant code letter as watermark
    letter_font = _font(340)
    bbox = draw.textbbox((0, 0), variant.code, font=letter_font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    draw.text(
        ((W - tw) / 2 - bbox[0], 200 - bbox[1]),
        variant.code,
        fill=(255, 255, 255, 255),
        font=letter_font,
    )

    # Heading under the letter
    _centered(draw, variant.cover_heading, _font(44), 570, W)

    # Detail lines
    y = 650
    detail_font = _font(32)
    for line in variant.cover_detail:
        h = _centered(draw, line, detail_font, y, W, fill=(240, 240, 240))
        y += h + 14

    # Footer band
    draw.rectangle([(0, H - 60), (W, H)], fill=(0, 0, 0))
    _centered(draw, "mediaporter audio-switcher test", _font(24), H - 45, W,
              fill=(200, 200, 200))

    img.save(path, "JPEG", quality=92)


def build_variant(variant: Variant, source: Path, out_dir: Path) -> Path:
    out = out_dir / f"audio_switcher_{variant.code}.mp4"
    if out.exists():
        out.unlink()

    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-ss", CLIP_START,
        "-i", str(source),
        "-t", CLIP_DURATION,
        *variant.ffmpeg_args,
        "-avoid_negative_ts", "make_zero",
        "-reset_timestamps", "1",
        "-movflags", "+faststart",
        "-f", "mp4",
        str(out),
    ]
    print(f"[{variant.code}] ffmpeg -> {out.name}", flush=True)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr[-2000:], file=sys.stderr)
        raise RuntimeError(f"ffmpeg failed for variant {variant.code}")

    size_mb = out.stat().st_size // 1024 // 1024
    print(f"[{variant.code}] built {out.name} ({size_mb} MB)")
    return out


def sync_variant(variant: Variant, out_dir: Path) -> None:
    mp4 = out_dir / f"audio_switcher_{variant.code}.mp4"
    poster = out_dir / f"audio_switcher_{variant.code}.jpg"

    if not mp4.exists():
        raise FileNotFoundError(f"missing {mp4} — run without --no-build first")
    if not poster.exists():
        raise FileNotFoundError(f"missing {poster}")

    poster_data = poster.read_bytes()

    item = SyncItem(
        file_path=mp4,
        title=variant.title,
        sort_name=variant.title.lower(),
        duration_ms=int(CLIP_DURATION) * 1000,
        file_size=mp4.stat().st_size,
        is_movie=True,
        is_hd=True,
        bit_rate=9200,
        audio_format=502,  # AAC LC marker
        channels=2,
        poster_data=poster_data,
    )

    print(f"[{variant.code}] syncing '{item.title}' ({item.file_size // 1024 // 1024} MB)")
    results = sync_files([item], verbose=True)
    for r in results:
        status = "OK" if r.success else f"FAIL: {r.error}"
        print(f"[{variant.code}] {status} -> {r.device_path or '-'}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                    help=f"MKV source (default: {DEFAULT_SOURCE})")
    ap.add_argument("--only", help="Comma-separated codes to process (e.g. A,C,E)")
    ap.add_argument("--no-build", action="store_true",
                    help="Skip ffmpeg; reuse existing mp4/jpg files")
    ap.add_argument("--no-sync", action="store_true",
                    help="Only build files + covers; don't touch the device")
    args = ap.parse_args()

    if not args.no_build and not args.source.exists():
        sys.exit(f"source not found: {args.source}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    only: set[str] | None = None
    if args.only:
        only = {c.strip().upper() for c in args.only.split(",") if c.strip()}
    variants = [v for v in VARIANTS if not only or v.code in only]
    if not variants:
        sys.exit("no variants selected")

    if not args.no_build:
        for v in variants:
            make_poster(OUT_DIR / f"audio_switcher_{v.code}.jpg", v)
            build_variant(v, args.source, OUT_DIR)

    if args.no_sync:
        print(f"built {len(variants)} variant(s) in {OUT_DIR} (--no-sync)")
        return 0

    for v in variants:
        try:
            sync_variant(v, OUT_DIR)
        except Exception as e:
            print(f"[{v.code}] sync error: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
