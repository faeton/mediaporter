"""Rich terminal UI for progress reporting."""

from __future__ import annotations

import shlex

from rich.console import Console
from rich.progress import (
    BarColumn,
    DownloadColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeRemainingColumn,
    TransferSpeedColumn,
)
from rich.table import Table

console = Console()


def create_transcode_progress() -> Progress:
    """Create a multi-file progress display for transcoding."""
    return Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TimeRemainingColumn(),
        console=console,
    )


def create_sync_progress() -> Progress:
    """Create a progress display for file sync/upload."""
    return Progress(
        SpinnerColumn(),
        TextColumn("[bold green]{task.description}"),
        BarColumn(),
        DownloadColumn(),
        TransferSpeedColumn(),
        TimeRemainingColumn(),
        console=console,
    )


def print_analysis(jobs) -> None:
    """Pretty-print analysis results for all files (after selection)."""
    from mediaporter.compat import COMPATIBLE_AUDIO_CODECS
    from mediaporter.metadata import EpisodeMetadata, MovieMetadata

    for job in jobs:
        console.print(f"\n[bold]{job.input_path.name}[/bold]")

        if job.media_info:
            mi = job.media_info
            decision = job.decision

            # Video
            for s in mi.video_streams:
                act = decision.stream_actions.get(s.index, "?") if decision else "?"
                res = f"{s.width}x{s.height}" if s.width and s.height else ""
                color = "green" if act == "copy" else "yellow"
                console.print(f"  [{color}]{s.codec_name} {res} -> {act}[/{color}]")

            # Audio — only selected tracks, with real action
            audio_indices = job.selected_audio if job.selected_audio is not None else list(range(len(mi.audio_streams)))
            selected_streams = [mi.audio_streams[i] for i in audio_indices]
            codecs_used = {s.codec_name.lower() for s in selected_streams}
            force_aac = len(audio_indices) > 1 and len(codecs_used) > 1

            for i in audio_indices:
                s = mi.audio_streams[i]
                ch = f"{s.channels}ch" if s.channels else ""
                lang = s.language or "und"
                title = f' "{s.title}"' if s.title else ""
                if force_aac:
                    act = "AAC" if s.codec_name.lower() != "aac" else "copy"
                    color = "yellow" if act == "AAC" else "green"
                    console.print(f"  [{color}]{s.codec_name} {ch} [{lang}]{title} -> {act}[/{color}]")
                else:
                    orig_act = decision.stream_actions.get(s.index, "?") if decision else "?"
                    color = "green" if orig_act == "copy" else "yellow"
                    console.print(f"  [{color}]{s.codec_name} {ch} [{lang}]{title} -> {orig_act}[/{color}]")

            # Subtitles — only selected tracks
            sub_indices = job.selected_subtitles if job.selected_subtitles is not None else list(range(len(mi.subtitle_streams)))
            shown_subs = 0
            for i in sub_indices:
                s = mi.subtitle_streams[i]
                act = decision.stream_actions.get(s.index, "skip") if decision else "skip"
                if act in ("copy", "convert_to_mov_text"):
                    lang = s.language or "und"
                    title = f' "{s.title}"' if s.title else ""
                    console.print(f"  [cyan]{s.codec_name} [{lang}]{title} -> mov_text[/cyan]")
                    shown_subs += 1

            ext_indices = job.selected_external_subs if job.selected_external_subs is not None else list(range(len(mi.external_subtitles)))
            for i in ext_indices:
                ext = mi.external_subtitles[i]
                console.print(f"  [cyan]{ext.format} [{ext.language}] (external) -> mov_text[/cyan]")
                shown_subs += 1

        if job.metadata:
            meta = job.metadata
            if isinstance(meta, EpisodeMetadata):
                ep_title = meta.episode_title or "untitled"
                poster = "Poster OK" if meta.poster_data or meta.show_poster_data else "No poster"
                console.print(
                    f"  TV: \"{meta.show_name}\" S{meta.season:02d}E{meta.episode:02d}"
                    f" \"{ep_title}\" -- {poster}"
                )
            elif isinstance(meta, MovieMetadata):
                year = meta.year or "?"
                poster = "Poster OK" if meta.poster_data else "No poster"
                console.print(f"  Movie: \"{meta.title}\" ({year}) -- {poster}")
        else:
            console.print("  [dim]No metadata[/dim]")


def prompt_for_files() -> list[str]:
    """Interactive prompt: drag files here, press Enter."""
    console.print("\n[bold]Drag video files here, then press Enter:[/bold]")
    try:
        raw = console.input("  ").strip()
    except (EOFError, KeyboardInterrupt):
        return []

    if not raw:
        return []

    try:
        return shlex.split(raw)
    except ValueError:
        return [raw]


def print_device_info(udid: str) -> None:
    """Print device connection info."""
    short = udid[:16] + "..." if len(udid) > 16 else udid
    console.print(f"  Device: {short}")


def print_file_info(filename: str, action: str) -> None:
    console.print(f"\n[bold]{'─' * 60}[/bold]")
    console.print(f"  [bold]{filename}[/bold] -> {action}")
    console.print(f"[bold]{'─' * 60}[/bold]")


def print_success(message: str) -> None:
    console.print(f"  [green]OK[/green] {message}")


def print_warning(message: str) -> None:
    console.print(f"  [yellow]!![/yellow] {message}")


def print_error(message: str) -> None:
    console.print(f"  [red]FAIL[/red] {message}")


def print_dry_run(lines: list[str]) -> None:
    console.print("\n[bold yellow]DRY RUN — no changes will be made[/bold yellow]\n")
    for line in lines:
        console.print(f"  {line}")
    console.print()
