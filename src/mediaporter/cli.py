"""CLI interface for mediaporter."""

import click
from rich.console import Console

from mediaporter import __version__

console = Console()


@click.group()
@click.version_option(version=__version__, prog_name="mediaporter")
@click.option("-v", "--verbose", is_flag=True, help="Increase verbosity.")
@click.pass_context
def main(ctx: click.Context, verbose: bool) -> None:
    """Transfer video files to iOS devices with smart transcoding."""
    ctx.ensure_object(dict)
    ctx.obj["verbose"] = verbose


@main.command()
@click.argument("input_paths", nargs=-1, required=True, type=click.Path(exists=True))
@click.option("-t", "--type", "media_type", type=click.Choice(["movie", "tv"]), default=None,
              help="Force media type (auto-detected from filename).")
@click.option("-q", "--quality", type=click.Choice(["fast", "balanced", "quality"]),
              default="balanced", help="Encoding quality preset.")
@click.option("--hw/--no-hw", default=True, help="VideoToolbox hardware encoding.")
@click.option("--subtitle-mode", type=click.Choice(["embed", "burn", "skip"]),
              default="embed", help="How to handle subtitles.")
@click.option("--burn-bitmap-subs", is_flag=True, help="Burn bitmap subs (PGS/VobSub) into video.")
@click.option("--no-metadata", is_flag=True, help="Skip TMDb metadata lookup.")
@click.option("--tmdb-key", envvar="TMDB_API_KEY", help="TMDb API key.")
@click.option("--show", "show_name", help="Override TV show name.")
@click.option("--season", type=int, help="Override season number.")
@click.option("--episode", type=int, help="Override episode number.")
@click.option("--keep", is_flag=True, help="Keep transcoded M4V after transfer.")
@click.option("--dry-run", is_flag=True, help="Show plan without executing.")
@click.option("-o", "--output", type=click.Path(), help="Save M4V locally instead of transferring.")
@click.option("--non-interactive", is_flag=True, help="No prompts, auto-select first match.")
@click.pass_context
def push(ctx: click.Context, input_paths: tuple[str, ...], media_type: str | None,
         quality: str, hw: bool, subtitle_mode: str, burn_bitmap_subs: bool,
         no_metadata: bool, tmdb_key: str | None, show_name: str | None,
         season: int | None, episode: int | None, keep: bool, dry_run: bool,
         output: str | None, non_interactive: bool) -> None:
    """Transcode and transfer video files to a connected iOS device."""
    from mediaporter.pipeline import run_pipeline, PipelineOptions

    options = PipelineOptions(
        media_type=media_type,
        quality=quality,
        hw_accel=hw,
        subtitle_mode=subtitle_mode,
        burn_bitmap_subs=burn_bitmap_subs,
        fetch_metadata=not no_metadata,
        tmdb_key=tmdb_key,
        show_override=show_name,
        season_override=season,
        episode_override=episode,
        keep_files=keep,
        dry_run=dry_run,
        output_path=output,
        non_interactive=non_interactive,
        verbose=ctx.obj["verbose"],
    )

    for path in input_paths:
        run_pipeline(path, options)


@main.command()
@click.argument("file", type=click.Path(exists=True))
def probe(file: str) -> None:
    """Analyze video file streams and iPad compatibility."""
    from mediaporter.probe import probe_file
    from mediaporter.compat import evaluate_compatibility
    from mediaporter.subtitles import scan_external_subtitles

    media_info = probe_file(file)
    media_info = scan_external_subtitles(media_info)
    decision = evaluate_compatibility(media_info)

    console.print(f"\n[bold]{media_info.path.name}[/bold]")
    console.print(f"  Container: {media_info.format_name}  Duration: {media_info.duration:.1f}s\n")

    for s in media_info.video_streams:
        action = "copy" if decision.stream_actions.get(s.index) == "copy" else "[red]transcode[/red]"
        console.print(f"  Video #{s.index}: {s.codec_name} {s.width}x{s.height} → {action}")

    for s in media_info.audio_streams:
        action = "copy" if decision.stream_actions.get(s.index) == "copy" else "[yellow]transcode→AAC[/yellow]"
        lang = s.language or "und"
        title = f' "{s.title}"' if s.title else ""
        console.print(f"  Audio #{s.index}: {s.codec_name} {s.channels}ch [{lang}]{title} → {action}")

    for s in media_info.subtitle_streams:
        action = decision.stream_actions.get(s.index, "skip")
        lang = s.language or "und"
        console.print(f"  Sub   #{s.index}: {s.codec_name} [{lang}] → {action}")

    for ext_sub in media_info.external_subtitles:
        console.print(f"  Sub   [ext]: {ext_sub.path.name} [{ext_sub.language}] → embed")

    console.print(f"\n  Needs transcode: {'[red]yes[/red]' if decision.needs_transcode else '[green]no (remux only)[/green]'}")


@main.command()
def devices() -> None:
    """List connected iOS devices."""
    from mediaporter.device import list_devices

    devs = list_devices()
    if not devs:
        console.print("[yellow]No iOS devices found. Is your device connected and trusted?[/yellow]")
        return

    for d in devs:
        console.print(f"  {d.name} ({d.model}) — iOS {d.ios_version} — UDID: {d.udid}")


@main.command("test-videos")
@click.argument("outdir", type=click.Path())
@click.option("--quick", is_flag=True, help="Generate minimal set (3 files).")
def test_videos(outdir: str, quick: bool) -> None:
    """Generate a suite of test video files for development and testing."""
    from tests.fixtures.generate_test_videos import generate_all

    generate_all(outdir, quick=quick)
    console.print(f"[green]Test videos generated in {outdir}[/green]")
