"""Generate synthetic test video files using ffmpeg for development and testing."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def _run_ffmpeg(args: list[str], description: str) -> None:
    """Run an ffmpeg command, raising on failure."""
    cmd = ["ffmpeg", "-hide_banner", "-y"] + args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Failed to generate {description}: {result.stderr[:500]}")


def _write_srt(path: Path, language: str = "English") -> None:
    """Write a simple SRT subtitle file."""
    path.write_text(
        f"1\n00:00:00,000 --> 00:00:02,000\n[{language}] Hello, this is a test subtitle.\n\n"
        f"2\n00:00:02,500 --> 00:00:04,500\n[{language}] mediaporter test content.\n\n"
    )


def _write_ass(path: Path, language: str = "French") -> None:
    """Write a simple ASS subtitle file."""
    path.write_text(
        "[Script Info]\n"
        "Title: Test\n"
        "ScriptType: v4.00+\n"
        "PlayResX: 1920\n"
        "PlayResY: 1080\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, "
        "BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, "
        "BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"
        "0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        f"Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{language} subtitle test\n"
        f"Dialogue: 0,0:00:02.50,0:00:04.50,Default,,0,0,0,,{language} mediaporter\n"
    )


# Video source filters
_VIDEO_5S_720P = '-f lavfi -i "testsrc2=size=1280x720:rate=24:duration=5"'
_VIDEO_5S_1080P = '-f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=5"'
_VIDEO_5S_4K = '-f lavfi -i "testsrc2=size=3840x2160:rate=24:duration=5"'
_VIDEO_5S_480P = '-f lavfi -i "testsrc2=size=720x480:rate=24:duration=5"'

# Audio source filters
_AUDIO_440HZ = '-f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000"'
_AUDIO_880HZ = '-f lavfi -i "sine=frequency=880:duration=5:sample_rate=48000"'
_AUDIO_220HZ = '-f lavfi -i "sine=frequency=220:duration=5:sample_rate=48000"'


def gen_h264_aac_mp4(outdir: Path) -> None:
    """Already iPad-compatible: H.264 + AAC in MP4 container."""
    out = outdir / "test_h264_aac.mp4"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
        "-c:a", "aac", "-b:a", "128k",
        "-metadata:s:a:0", "language=eng",
        str(out),
    ], "test_h264_aac.mp4")
    print(f"  Created: {out.name}")


def gen_h265_aac_mkv(outdir: Path) -> None:
    """H.265 + AAC in MKV — needs container change only."""
    out = outdir / "test_h265_aac.mkv"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx265", "-preset", "ultrafast", "-crf", "28",
        "-tag:v", "hvc1",
        "-c:a", "aac", "-b:a", "128k",
        "-metadata:s:a:0", "language=eng",
        str(out),
    ], "test_h265_aac.mkv")
    print(f"  Created: {out.name}")


def gen_h264_dts_mkv(outdir: Path) -> None:
    """H.264 + 6-channel audio (simulating DTS) — needs audio transcode."""
    out = outdir / "test_h264_multichannel.mkv"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
        "-c:a", "flac", "-ac", "6",
        "-metadata:s:a:0", "language=eng",
        "-metadata:s:a:0", "title=English 5.1",
        str(out),
    ], "test_h264_multichannel.mkv")
    print(f"  Created: {out.name}")


def gen_vp9_mkv(outdir: Path) -> None:
    """VP9 + Vorbis — needs full video + audio transcode."""
    out = outdir / "test_vp9.mkv"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libvpx-vp9", "-b:v", "1M", "-cpu-used", "8",
        "-c:a", "libopus", "-b:a", "128k",
        "-metadata:s:a:0", "language=eng",
        str(out),
    ], "test_vp9.mkv")
    print(f"  Created: {out.name}")


def gen_multi_audio_mkv(outdir: Path) -> None:
    """H.264 + 3 audio tracks (AAC eng, AC3 fra, 6ch deu)."""
    out = outdir / "test_multi_audio.mkv"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-f", "lavfi", "-i", "sine=frequency=880:duration=5:sample_rate=48000",
        "-f", "lavfi", "-i", "sine=frequency=220:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
        "-c:a:0", "aac", "-b:a:0", "128k",
        "-c:a:1", "ac3", "-b:a:1", "384k",
        "-c:a:2", "aac", "-ac:a:2", "6", "-b:a:2", "384k",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English Stereo",
        "-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "title=French 5.1",
        "-metadata:s:a:2", "language=deu", "-metadata:s:a:2", "title=German 5.1",
        str(out),
    ], "test_multi_audio.mkv")
    print(f"  Created: {out.name}")


def gen_embedded_subs_mkv(outdir: Path) -> None:
    """H.264 + AAC + embedded SRT (eng) and ASS (fra) subtitles."""
    out = outdir / "test_embedded_subs.mkv"

    # Create temp subtitle files
    srt_file = outdir / "_tmp_eng.srt"
    ass_file = outdir / "_tmp_fra.ass"
    _write_srt(srt_file, "English")
    _write_ass(ass_file, "French")

    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-i", str(srt_file),
        "-i", str(ass_file),
        "-map", "0:v", "-map", "1:a", "-map", "2:0", "-map", "3:0",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
        "-c:a", "aac", "-b:a", "128k",
        "-c:s:0", "srt",
        "-c:s:1", "ass",
        "-metadata:s:a:0", "language=eng",
        "-metadata:s:s:0", "language=eng",
        "-metadata:s:s:1", "language=fra",
        str(out),
    ], "test_embedded_subs.mkv")

    # Cleanup temp files
    srt_file.unlink(missing_ok=True)
    ass_file.unlink(missing_ok=True)
    print(f"  Created: {out.name}")


def gen_external_subs(outdir: Path) -> None:
    """H.264 + AAC MKV with external subtitle sidecar files."""
    out = outdir / "test_external_subs.mkv"

    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
        "-c:a", "aac", "-b:a", "128k",
        "-metadata:s:a:0", "language=eng",
        str(out),
    ], "test_external_subs.mkv")

    # Generate external subtitle files in various naming patterns
    _write_srt(outdir / "test_external_subs.srt", "Default")
    _write_srt(outdir / "test_external_subs.en.srt", "English")
    _write_srt(outdir / "test_external_subs.eng.srt", "English-3")
    _write_srt(outdir / "test_external_subs.english.srt", "English-full")
    _write_ass(outdir / "test_external_subs.fr.ass", "French")
    _write_ass(outdir / "test_external_subs.fra.ass", "French-3")

    print(f"  Created: {out.name} + 6 sidecar subtitle files")


def gen_4k_hevc_mkv(outdir: Path) -> None:
    """4K H.265 10-bit + AAC — passthrough test."""
    out = outdir / "test_4k_hevc.mkv"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx265", "-preset", "ultrafast", "-crf", "28",
        "-pix_fmt", "yuv420p10le",
        "-tag:v", "hvc1",
        "-c:a", "aac", "-b:a", "128k",
        "-metadata:s:a:0", "language=eng",
        str(out),
    ], "test_4k_hevc.mkv")
    print(f"  Created: {out.name}")


def gen_avi_mpeg4(outdir: Path) -> None:
    """MPEG-4 Part 2 + MP3 in AVI — legacy format, full transcode."""
    out = outdir / "test_avi_mpeg4.avi"
    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "mpeg4", "-b:v", "1M",
        "-c:a", "libmp3lame", "-b:a", "128k",
        str(out),
    ], "test_avi_mpeg4.avi")
    print(f"  Created: {out.name}")


def gen_everything_mkv(outdir: Path) -> None:
    """Kitchen-sink test: H.265 + multiple audio + multiple subtitle types."""
    out = outdir / "test_everything.mkv"

    srt_file = outdir / "_tmp_eng2.srt"
    ass_file = outdir / "_tmp_fra2.ass"
    _write_srt(srt_file, "English")
    _write_ass(ass_file, "French")

    _run_ffmpeg([
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
        "-f", "lavfi", "-i", "sine=frequency=880:duration=5:sample_rate=48000",
        "-f", "lavfi", "-i", "sine=frequency=220:duration=5:sample_rate=48000",
        "-i", str(srt_file),
        "-i", str(ass_file),
        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a",
        "-map", "4:0", "-map", "5:0",
        "-c:v", "libx265", "-preset", "ultrafast", "-crf", "28",
        "-tag:v", "hvc1",
        "-c:a:0", "aac", "-b:a:0", "128k",
        "-c:a:1", "ac3", "-b:a:1", "384k",
        "-c:a:2", "flac", "-ac:a:2", "6",
        "-c:s:0", "srt",
        "-c:s:1", "ass",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English Stereo",
        "-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "title=French 5.1",
        "-metadata:s:a:2", "language=deu", "-metadata:s:a:2", "title=German 5.1 Lossless",
        "-metadata:s:s:0", "language=eng",
        "-metadata:s:s:1", "language=fra",
        str(out),
    ], "test_everything.mkv")

    srt_file.unlink(missing_ok=True)
    ass_file.unlink(missing_ok=True)
    print(f"  Created: {out.name}")


def gen_tv_series(outdir: Path) -> None:
    """Generate fake TV series episodes for series grouping tests."""
    episodes = [
        ("Breaking.Bad.S01E01.Pilot.1080p.mkv", "S01E01"),
        ("Breaking.Bad.S01E02.Cats.in.the.Bag.1080p.mkv", "S01E02"),
        ("Breaking.Bad.S02E01.Seven.Thirty.Seven.1080p.mkv", "S02E01"),
    ]
    for filename, ep_id in episodes:
        out = outdir / filename
        _run_ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=5:sample_rate=48000",
            "-map", "0:v", "-map", "1:a",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
            "-c:a", "aac", "-b:a", "128k",
            "-metadata:s:a:0", "language=eng",
            "-metadata", f"title={ep_id}",
            str(out),
        ], filename)
        print(f"  Created: {out.name}")


# Quick test set (3 files) vs full set (all files)
QUICK_GENERATORS = [gen_h264_aac_mp4, gen_vp9_mkv, gen_embedded_subs_mkv]

ALL_GENERATORS = [
    gen_h264_aac_mp4,
    gen_h265_aac_mkv,
    gen_h264_dts_mkv,
    gen_vp9_mkv,
    gen_multi_audio_mkv,
    gen_embedded_subs_mkv,
    gen_external_subs,
    gen_4k_hevc_mkv,
    gen_avi_mpeg4,
    gen_everything_mkv,
    gen_tv_series,
]


def generate_all(outdir: str, quick: bool = False) -> None:
    """Generate all (or quick subset of) test videos."""
    out_path = Path(outdir)
    out_path.mkdir(parents=True, exist_ok=True)

    generators = QUICK_GENERATORS if quick else ALL_GENERATORS
    print(f"Generating {'quick' if quick else 'full'} test set ({len(generators)} generators)...")

    for gen in generators:
        try:
            gen(out_path)
        except RuntimeError as e:
            print(f"  ERROR: {e}")


if __name__ == "__main__":
    import sys
    outdir = sys.argv[1] if len(sys.argv) > 1 else "./test_fixtures"
    quick = "--quick" in sys.argv
    generate_all(outdir, quick=quick)
