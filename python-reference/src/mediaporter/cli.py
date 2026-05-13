"""CLI interface for mediaporter."""

from __future__ import annotations

import sys

import click

from mediaporter import __version__
from mediaporter.progress import console


class DefaultSyncGroup(click.Group):
    """Routes unknown args to 'sync' command automatically.

    mediaporter movie.mkv        → mediaporter sync movie.mkv
    mediaporter probe movie.mkv  → probe subcommand
    mediaporter devices          → devices subcommand
    mediaporter                  → mediaporter sync (interactive)
    """

    def parse_args(self, ctx, args):
        # Let --help and --version through to the group
        if "--help" in args or "--version" in args:
            return super().parse_args(ctx, args)

        # No args at all — launch interactive drag-and-drop sync mode
        if not args:
            return super().parse_args(ctx, ["sync"])

        # If first non-option arg is a known subcommand, let Click handle it
        for arg in args:
            if arg.startswith("-"):
                continue
            if arg in self.commands:
                return super().parse_args(ctx, args)
            # First positional is not a subcommand — prepend "sync"
            args = ["sync"] + list(args)
            return super().parse_args(ctx, args)

        # Only options, no positional — default to "sync" (interactive mode)
        args = ["sync"] + list(args)
        return super().parse_args(ctx, args)


@click.group(cls=DefaultSyncGroup)
@click.version_option(version=__version__, prog_name="mediaporter")
def main():
    """Transfer videos to iPad/iPhone TV app.

    \b
    Examples:
      mediaporter movie.mkv                Transcode and sync to device
      mediaporter *.mkv -j4 -y             Parallel transcode, skip confirm
      mediaporter                           Interactive drag-and-drop mode
      mediaporter probe movie.mkv           Analyze file compatibility
      mediaporter devices                   List connected iOS devices
    """


@main.command()
@click.argument("files", nargs=-1, type=click.Path())
@click.option("-y", "--yes", is_flag=True, help="Skip confirmation.")
@click.option("-q", "--quality", type=click.Choice(["fast", "balanced", "quality"]),
              default="balanced", help="Encoding quality preset.")
@click.option("-j", "--jobs", type=int, default=None, help="Parallel transcode workers.")
@click.option("--hw/--no-hw", default=True, help="VideoToolbox hardware encoding.")
@click.option("--no-metadata", is_flag=True, help="Skip TMDb metadata lookup.")
@click.option("--tmdb-key", envvar="TMDB_API_KEY", help="TMDb API key.")
@click.option("--dry-run", is_flag=True, help="Show plan without executing.")
@click.option("-o", "--output", type=click.Path(), help="Save M4V locally instead of syncing.")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output.")
@click.option("--device", "device_udid", default=None,
              help="Target a specific device UDID (use `mediaporter devices` to list). "
                   "Default: auto-pick iPad over iPhone when multiple are attached.")
def sync(files, yes, quality, jobs, hw, no_metadata, tmdb_key, dry_run, output, verbose, device_udid):
    """Transcode and transfer video files to device."""
    from mediaporter.config import load_config
    from mediaporter.pipeline import PipelineOptions, run_pipeline
    from mediaporter.progress import prompt_for_files

    config = load_config()

    file_list = list(files) if files else []
    if not file_list:
        file_list = prompt_for_files()
        if not file_list:
            raise click.Abort()

    options = PipelineOptions(
        quality=quality,
        hw_accel=hw,
        fetch_metadata=not no_metadata,
        tmdb_key=tmdb_key or config.tmdb_api_key,
        dry_run=dry_run,
        output_path=output,
        non_interactive=yes,
        verbose=verbose,
        jobs=jobs,
        subtitle_mode=config.subtitle_mode,
        burn_bitmap_subs=config.burn_bitmap_subs,
        keep_files=config.keep_files,
        device_udid=device_udid,
    )

    run_pipeline(file_list, options)


@main.command()
@click.argument("file", type=click.Path(exists=True))
@click.option("--tmdb-key", envvar="TMDB_API_KEY", help="TMDb API key for metadata lookup.")
def probe(file, tmdb_key):
    """Analyze video file: streams, compatibility, metadata, cover art."""
    from pathlib import Path

    from mediaporter.audio import classify_all_audio
    from mediaporter.compat import evaluate_compatibility, get_hd_flag
    from mediaporter.metadata import lookup_metadata, parse_filename
    from mediaporter.probe import probe_file
    from mediaporter.subtitles import scan_external_subtitles

    media_info = probe_file(file)
    media_info = scan_external_subtitles(media_info)
    decision = evaluate_compatibility(media_info)
    audio_actions = classify_all_audio(media_info.audio_streams)

    file_size_mb = Path(file).stat().st_size / 1048576
    mins, secs = divmod(int(media_info.duration), 60)
    hours, mins = divmod(mins, 60)
    dur_str = f"{hours}:{mins:02d}:{secs:02d}" if hours else f"{mins}:{secs:02d}"
    console.print(f"\n[bold]{media_info.path.name}[/bold]  ({file_size_mb:.1f} MB, {dur_str})")
    console.print(f"  Container: {media_info.format_name}")
    if media_info.bit_rate:
        console.print(f"  Bitrate: {media_info.bit_rate // 1000} kbps")

    console.print()
    for s in media_info.video_streams:
        action = decision.stream_actions.get(s.index, "?")
        color = "green" if action == "copy" else "red"
        hd = get_hd_flag(s.width, s.height)
        hd_label = {0: "SD", 1: "720p HD", 2: "1080p+ HD"}.get(hd, "")
        profile_str = f" ({s.profile})" if s.profile else ""
        console.print(
            f"  [bold]Video[/bold] #{s.index}: {s.codec_name}{profile_str} "
            f"{s.width}x{s.height} {hd_label} [{color}]{action}[/{color}]"
        )

    for i, (s, aa) in enumerate(zip(media_info.audio_streams, audio_actions)):
        action = aa.action
        color = "green" if action == "copy" else "yellow"
        lang = s.language or "und"
        ch_label = f"{s.channels}ch" if s.channels else ""
        title = f' "{s.title}"' if s.title else ""
        detail = ""
        if action == "transcode":
            detail = f" -> AAC {aa.target_channels}ch {aa.target_bitrate}"
        console.print(
            f"  [bold]Audio[/bold] #{s.index}: {s.codec_name} {ch_label} [{lang}]{title} "
            f"[{color}]{action}{detail}[/{color}]"
        )

    if media_info.subtitle_streams:
        for s in media_info.subtitle_streams:
            action = decision.stream_actions.get(s.index, "skip")
            lang = s.language or "und"
            title = f' "{s.title}"' if s.title else ""
            color = "green" if action in ("copy", "convert_to_mov_text") else "dim"
            console.print(
                f"  [bold]Sub[/bold]   #{s.index}: {s.codec_name} [{lang}]{title} [{color}]{action}[/{color}]"
            )

    if media_info.external_subtitles:
        for ext_sub in media_info.external_subtitles:
            console.print(
                f"  [bold]Sub[/bold]   [ext]: {ext_sub.path.name} [{ext_sub.language}] [green]embed[/green]"
            )

    if decision.needs_transcode:
        console.print(f"\n  Transcode: [red]yes (video or audio needs re-encoding)[/red]")
    elif decision.needs_remux:
        console.print(f"\n  Transcode: [yellow]remux only (container change)[/yellow]")
    else:
        console.print(f"\n  Transcode: [green]not needed (already compatible)[/green]")

    console.print()
    try:
        guess = parse_filename(Path(file))
        guessed_type = guess.get("type", "movie")

        if guessed_type == "episode":
            show = guess.get("title", "?")
            season = guess.get("season", "?")
            episode = guess.get("episode", "?")
            console.print(f"  [bold]Detected[/bold]: TV Series")
            console.print(f"    Show: {show}")
            console.print(f"    Season {season}, Episode {episode}")
        else:
            title = guess.get("title", Path(file).stem)
            year = guess.get("year", "")
            year_str = f" ({year})" if year else ""
            console.print(f"  [bold]Detected[/bold]: Movie")
            console.print(f"    Title: {title}{year_str}")

        config = None
        api_key = tmdb_key
        if not api_key:
            from mediaporter.config import load_config
            config = load_config()
            api_key = config.tmdb_api_key

        if api_key:
            meta = lookup_metadata(Path(file), api_key=api_key)
            if meta:
                from mediaporter.metadata import EpisodeMetadata, MovieMetadata
                if isinstance(meta, EpisodeMetadata):
                    console.print(f"    TMDb: [green]{meta.show_name}[/green] "
                                  f"S{meta.season:02d}E{meta.episode:02d} "
                                  f'"{meta.episode_title or "?"}"')
                    if meta.genre:
                        console.print(f"    Genre: {meta.genre}")
                    if meta.network:
                        console.print(f"    Network: {meta.network}")
                    poster = meta.poster_data or meta.show_poster_data
                    if poster:
                        console.print(f"    Cover: [green]{len(poster) // 1024} KB poster downloaded[/green]")
                    else:
                        console.print(f"    Cover: [yellow]no poster found[/yellow]")
                elif isinstance(meta, MovieMetadata):
                    year_s = f" ({meta.year})" if meta.year else ""
                    console.print(f"    TMDb: [green]{meta.title}{year_s}[/green]")
                    if meta.genre:
                        console.print(f"    Genre: {meta.genre}")
                    if meta.director:
                        console.print(f"    Director: {meta.director}")
                    if meta.overview:
                        console.print(f"    Overview: {meta.overview[:80]}...")
                    if meta.poster_data:
                        console.print(f"    Cover: [green]{len(meta.poster_data) // 1024} KB poster downloaded[/green]")
                    else:
                        console.print(f"    Cover: [yellow]no poster found[/yellow]")
        else:
            console.print(f"    TMDb: [dim]no API key (set TMDB_API_KEY or --tmdb-key)[/dim]")
            console.print(f"    Cover: [dim]skipped (needs TMDb)[/dim]")

    except Exception as e:
        console.print(f"  [dim]Metadata detection failed: {e}[/dim]")


@main.command()
def devices():
    """List connected iOS devices with model info and transcode guidance."""
    try:
        from mediaporter.sync.device import (
            describe_model,
            list_devices,
            optimal_transcode_resolution,
        )

        devs = list_devices(with_details=True)
        if not devs:
            console.print("[yellow]No iOS devices found. Is your device connected and trusted?[/yellow]")
            return

        def _row(label: str, value: str) -> str:
            return f"  {label:<10}{value}"

        for i, d in enumerate(devs):
            if i > 0:
                console.print()

            model_name, native_res = describe_model(d.product_type)
            header = d.name or model_name or "iOS device"
            console.print(f"[bold green]{header}[/bold green]")

            if d.product_type:
                if model_name != d.product_type:
                    console.print(_row("Model:", f"{model_name} [dim]({d.product_type})[/dim]"))
                else:
                    console.print(_row("Model:", d.product_type))
            if d.product_version:
                dc = (d.device_class or "").lower()
                version_label = "iPadOS:" if dc == "ipad" else "iOS:"
                console.print(_row(version_label, d.product_version))
            if d.model_number:
                console.print(_row("Model #:", d.model_number))
            console.print(_row("UDID:", f"[dim]{d.udid}[/dim]"))

            if native_res:
                console.print(_row("Display:", native_res))
            console.print(_row(
                "Optimal:",
                f"[cyan]{optimal_transcode_resolution(d.product_type)}[/cyan]"
                " [dim](target for transcoding)[/dim]",
            ))
    except Exception as e:
        console.print(f"[red]Device discovery failed: {e}[/red]")
