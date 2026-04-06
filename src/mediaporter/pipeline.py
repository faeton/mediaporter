"""Pipeline orchestration: probe -> transcode -> tag -> sync."""

from __future__ import annotations

import os
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

from mediaporter.compat import evaluate_compatibility, get_hd_flag
from mediaporter.exceptions import MediaPorterError
from mediaporter.metadata import EpisodeMetadata, MovieMetadata
from mediaporter.probe import MediaInfo, probe_file
from mediaporter.progress import (
    console,
    create_sync_progress,
    create_transcode_progress,
    print_analysis,
    print_dry_run,
    print_error,
    print_success,
    print_warning,
)
from mediaporter.subtitles import scan_external_subtitles

VIDEO_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".flv",
    ".webm", ".ts", ".mts", ".m2ts", ".mpg", ".mpeg", ".vob",
}


@dataclass
class FileJob:
    """A single file moving through the pipeline."""
    input_path: Path
    media_info: MediaInfo | None = None
    decision: "TranscodeDecision | None" = None  # type: ignore[name-defined]
    metadata: MovieMetadata | EpisodeMetadata | None = None
    output_path: Path | None = None
    selected_audio: list[int] | None = None  # indices into media_info.audio_streams
    selected_subtitles: list[int] | None = None  # indices into subtitle_streams
    selected_external_subs: list[int] | None = None  # indices into external_subtitles
    status: str = "pending"
    error: str | None = None


@dataclass
class PipelineOptions:
    """Options for the processing pipeline."""
    quality: str = "balanced"
    hw_accel: bool = True
    subtitle_mode: str = "embed"
    burn_bitmap_subs: bool = False
    fetch_metadata: bool = True
    tmdb_key: str | None = None
    show_override: str | None = None
    season_override: int | None = None
    episode_override: int | None = None
    keep_files: bool = False
    dry_run: bool = False
    output_path: str | None = None
    non_interactive: bool = False
    verbose: bool = False
    jobs: int | None = None


def collect_video_files(paths: list[str]) -> list[Path]:
    """Expand paths (files and directories) to video file list."""
    result: list[Path] = []
    for path_str in paths:
        p = Path(path_str)
        if p.is_file():
            if p.suffix.lower() in VIDEO_EXTENSIONS:
                result.append(p)
            else:
                result.append(p)  # let ffprobe decide
        elif p.is_dir():
            for f in sorted(p.iterdir()):
                if f.is_file() and f.suffix.lower() in VIDEO_EXTENSIONS:
                    result.append(f)
    return result


def analyze(files: list[Path], options: PipelineOptions) -> list[FileJob]:
    """Probe all files, check compat, lookup metadata."""
    jobs: list[FileJob] = []

    for path in files:
        job = FileJob(input_path=path)
        try:
            job.media_info = probe_file(path)
            job.media_info = scan_external_subtitles(job.media_info)
            job.decision = evaluate_compatibility(job.media_info)

            if options.fetch_metadata:
                from mediaporter.metadata import lookup_metadata
                try:
                    job.metadata = lookup_metadata(
                        path=path,
                        show_override=options.show_override,
                        season_override=options.season_override,
                        episode_override=options.episode_override,
                        api_key=options.tmdb_key,
                        non_interactive=options.non_interactive,
                    )
                except MediaPorterError as e:
                    print_warning(f"Metadata lookup failed for {path.name}: {e}")

            job.status = "analyzed"
        except MediaPorterError as e:
            job.status = "failed"
            job.error = str(e)

        jobs.append(job)

    return jobs


def _format_track(s) -> str:
    """Format a single audio track for display."""
    codec = s.codec_name.upper()
    ch = f"{s.channels}.0" if s.channels and s.channels <= 2 else f"{s.channels - 1}.1" if s.channels else ""
    title = s.title or ""
    lang = s.language or "und"
    lang_names = {
        "eng": "English", "rus": "Russian", "fra": "French", "deu": "German",
        "spa": "Spanish", "ita": "Italian", "por": "Portuguese", "jpn": "Japanese",
        "kor": "Korean", "zho": "Chinese", "chi": "Chinese", "ara": "Arabic",
        "hin": "Hindi", "tur": "Turkish", "ukr": "Ukrainian", "pol": "Polish",
        "und": "Unknown",
    }
    lang_display = lang_names.get(lang, lang.upper())
    parts = [lang_display, codec, ch]
    if title:
        parts.append(f'"{title}"')
    return " ".join(p for p in parts if p)


def _prompt_audio_selection(job: FileJob) -> None:
    """Per-language audio track selection.

    iPad groups tracks by language — only one per language is shown.
    So we let the user pick ONE track per language when there are duplicates.
    """
    if not job.media_info:
        return

    streams = job.media_info.audio_streams
    if len(streams) <= 1:
        return

    # Group by language, preserving order
    by_lang: dict[str, list[tuple[int, object]]] = {}
    for i, s in enumerate(streams):
        lang = s.language or "und"
        by_lang.setdefault(lang, []).append((i, s))

    has_duplicates = any(len(tracks) > 1 for tracks in by_lang.values())
    if not has_duplicates:
        return

    from mediaporter.selector import radio_select

    selected: list[int] = []

    for lang, tracks in by_lang.items():
        if len(tracks) == 1:
            idx, s = tracks[0]
            selected.append(idx)
            console.print(f"  [green]{_lang_name(lang)}[/green]: {_format_track_short(s)}")
        else:
            # Multiple tracks for this language — user picks one
            items = [_format_track_short(s) for _, s in tracks]
            choice = radio_select(
                title=f"\033[1m{_lang_name(lang)}\033[0m — pick one dub:",
                items=items,
                default=0,
            )
            if choice is None:
                # Cancelled — pick first
                choice = 0
            idx, s = tracks[choice]
            selected.append(idx)
            console.print(f"  [green]{_lang_name(lang)}[/green]: {_format_track_short(s)}")

    if len(selected) < len(streams):
        job.selected_audio = selected


def _lang_name(code: str) -> str:
    names = {
        "eng": "English", "rus": "Russian", "fra": "French", "deu": "German",
        "spa": "Spanish", "ita": "Italian", "por": "Portuguese", "jpn": "Japanese",
        "kor": "Korean", "zho": "Chinese", "chi": "Chinese", "ara": "Arabic",
        "hin": "Hindi", "tur": "Turkish", "ukr": "Ukrainian", "pol": "Polish",
        "nld": "Dutch", "swe": "Swedish", "nor": "Norwegian", "dan": "Danish",
        "fin": "Finnish", "ces": "Czech", "ron": "Romanian", "rum": "Romanian",
        "und": "Unknown",
    }
    return names.get(code, code.upper())


def _format_track_short(s) -> str:
    codec = s.codec_name.upper()
    ch = f"{s.channels}.0" if s.channels and s.channels <= 2 else f"{s.channels - 1}.1" if s.channels else ""
    title = s.title or ""
    parts = [codec, ch]
    if title:
        parts.append(f'"{title}"')
    return " ".join(p for p in parts if p)


def _format_sub_track(stream) -> str:
    """Format a subtitle track for display."""
    lang = _lang_name(stream.language or "und")
    codec = stream.codec_name.upper()
    title = stream.title or ""
    parts = [lang, codec]
    if title:
        parts.append(f'"{title}"')
    return " ".join(p for p in parts if p)


def _prompt_subtitle_selection(job: FileJob) -> None:
    """Let user choose which subtitle tracks to embed."""
    if not job.media_info or not job.decision:
        return

    # Collect embeddable subtitles
    entries: list[tuple[str, int, str]] = []  # (type, orig_index, display)

    for i, stream in enumerate(job.media_info.subtitle_streams):
        action = job.decision.stream_actions.get(stream.index, "skip")
        if action in ("copy", "convert_to_mov_text"):
            entries.append(("internal", i, _format_sub_track(stream)))

    for i, ext_sub in enumerate(job.media_info.external_subtitles):
        lang = _lang_name(ext_sub.language or "und")
        fmt = ext_sub.format.upper() if ext_sub.format else "SRT"
        entries.append(("external", i, f"{lang} {fmt} (external)"))

    if len(entries) <= 1:
        return

    from mediaporter.selector import checkbox_select

    items = [e[2] for e in entries]
    result = checkbox_select(
        title="Subtitle tracks (space=toggle, enter=confirm):",
        items=items,
    )

    if result is None:
        return  # Cancelled, keep all

    internal_selected = []
    external_selected = []
    for idx in result:
        kind, orig_idx, _ = entries[idx]
        if kind == "internal":
            internal_selected.append(orig_idx)
        else:
            external_selected.append(orig_idx)

    total_internal = sum(1 for e in entries if e[0] == "internal")
    total_external = sum(1 for e in entries if e[0] == "external")

    if len(internal_selected) < total_internal or len(external_selected) < total_external:
        job.selected_subtitles = internal_selected
        job.selected_external_subs = external_selected


def _transcode_one(job: FileJob, options: PipelineOptions, task_id, progress) -> None:
    """Transcode and tag a single file. Called from worker thread."""
    from mediaporter.transcode import transcode

    if not job.media_info or not job.decision:
        return

    if options.output_path:
        out_dir = Path(options.output_path)
        if out_dir.is_dir():
            output = out_dir / f"{job.input_path.stem}.m4v"
        else:
            output = out_dir
    else:
        output = Path(tempfile.mkdtemp()) / f"{job.input_path.stem}.m4v"

    job.status = "transcoding"

    def on_progress(pct: float) -> None:
        progress.update(task_id, completed=pct * 100)

    transcode(
        media_info=job.media_info,
        decision=job.decision,
        output_path=output,
        quality=options.quality,
        hw_accel=options.hw_accel,
        subtitle_mode=options.subtitle_mode,
        burn_bitmap_subs=options.burn_bitmap_subs,
        progress_callback=on_progress,
        selected_audio=job.selected_audio,
        selected_subtitles=job.selected_subtitles,
        selected_external_subs=job.selected_external_subs,
    )

    job.output_path = output
    job.status = "transcoded"

    # Tag
    if job.metadata:
        from mediaporter.tagger import tag_file
        tag_file(output, job.metadata, job.media_info)

    job.status = "ready"


def transcode_all(jobs: list[FileJob], options: PipelineOptions) -> None:
    """Transcode + tag files in parallel using ThreadPoolExecutor."""
    # If audio/subtitle selection was made, the file needs remuxing even if codecs are compatible
    for j in jobs:
        has_selection = j.selected_audio is not None or j.selected_subtitles is not None or j.selected_external_subs is not None
        if has_selection and j.decision and not j.decision.needs_transcode and not j.decision.needs_remux:
            j.decision.needs_remux = True  # force remux to apply track selection

    needs_work = [j for j in jobs if j.status == "analyzed" and j.decision
                  and (j.decision.needs_transcode or j.decision.needs_remux)]
    already_ok = [j for j in jobs if j.status == "analyzed" and j.decision
                  and not j.decision.needs_transcode and not j.decision.needs_remux]

    # Files that are already compatible — use directly
    for job in already_ok:
        job.output_path = job.input_path
        job.status = "ready"
        if job.metadata:
            import shutil
            tmp = Path(tempfile.mkdtemp()) / f"{job.input_path.stem}.m4v"
            shutil.copy2(job.input_path, tmp)
            job.output_path = tmp
            from mediaporter.tagger import tag_file
            tag_file(tmp, job.metadata, job.media_info)

    if not needs_work:
        return

    workers = options.jobs or min(os.cpu_count() or 2, len(needs_work))

    with create_transcode_progress() as progress:
        task_ids = {}
        for job in needs_work:
            task_ids[job.input_path] = progress.add_task(job.input_path.name, total=100)

        with ThreadPoolExecutor(max_workers=workers) as executor:
            future_to_job = {}
            for job in needs_work:
                future = executor.submit(
                    _transcode_one, job, options, task_ids[job.input_path], progress
                )
                future_to_job[future] = job

            for future in as_completed(future_to_job):
                job = future_to_job[future]
                try:
                    future.result()
                    progress.update(task_ids[job.input_path], completed=100)
                except Exception as e:
                    job.status = "failed"
                    job.error = str(e)


def _build_sync_item(job: FileJob):
    """Map a completed FileJob to a SyncItem for the sync engine."""
    from mediaporter.sync.atc import SyncItem

    if not job.output_path or not job.media_info:
        return None

    is_hd = False
    if job.media_info.video_streams:
        vs = job.media_info.video_streams[0]
        is_hd = get_hd_flag(vs.width, vs.height) > 0

    duration_ms = int(job.media_info.duration * 1000) if job.media_info.duration else 125
    file_size = job.output_path.stat().st_size

    # Determine audio info from probe
    channels = 2
    if job.media_info.audio_streams:
        channels = job.media_info.audio_streams[0].channels or 2

    # Get poster data
    poster_data = None
    if isinstance(job.metadata, EpisodeMetadata):
        poster_data = job.metadata.poster_data or job.metadata.show_poster_data
    elif isinstance(job.metadata, MovieMetadata):
        poster_data = job.metadata.poster_data

    if isinstance(job.metadata, EpisodeMetadata):
        meta = job.metadata
        return SyncItem(
            file_path=job.output_path,
            title=meta.episode_title or f"Episode {meta.episode}",
            sort_name=(meta.episode_title or f"Episode {meta.episode}").lower(),
            duration_ms=duration_ms,
            file_size=file_size,
            is_movie=False,
            is_tv_show=True,
            tv_show_name=meta.show_name,
            sort_tv_show_name=meta.show_name.lower(),
            season_number=meta.season,
            episode_number=meta.episode,
            episode_sort_id=meta.episode,
            artist=meta.show_name,
            sort_artist=meta.show_name.lower(),
            album=f"{meta.show_name}, Season {meta.season}",
            sort_album=f"{meta.show_name.lower()}, season {meta.season}",
            album_artist=meta.show_name,
            sort_album_artist=meta.show_name.lower(),
            is_hd=is_hd,
            channels=min(channels, 6),
            poster_data=poster_data,
        )
    else:
        meta = job.metadata
        title = meta.title if meta else job.input_path.stem
        return SyncItem(
            file_path=job.output_path,
            title=title,
            sort_name=title.lower(),
            duration_ms=duration_ms,
            file_size=file_size,
            is_movie=True,
            is_tv_show=False,
            is_hd=is_hd,
            channels=min(channels, 6),
            poster_data=poster_data,
        )


def sync_all(jobs: list[FileJob], verbose: bool = False) -> None:
    """Sync all ready files to device in a single ATC session."""
    from mediaporter.sync import sync_files

    ready = [j for j in jobs if j.status == "ready" and j.output_path]
    if not ready:
        print_warning("No files ready for sync")
        return

    items = []
    for job in ready:
        item = _build_sync_item(job)
        if item:
            items.append(item)

    if not items:
        print_warning("No sync items could be built")
        return

    console.print(f"\n[bold]Syncing {len(items)} file(s) to device...[/bold]")

    if verbose:
        # Verbose mode — skip Rich progress to avoid display corruption from stderr logs
        results = sync_files(items, progress_cb=None, verbose=True)
    else:
        with create_sync_progress() as progress:
            tasks: dict[str, int] = {}

            def on_progress(filename: str, sent: int, total: int) -> None:
                if filename not in tasks:
                    tasks[filename] = progress.add_task(filename, total=total)
                progress.update(tasks[filename], completed=sent, total=total)

            results = sync_files(items, progress_cb=on_progress, verbose=False)

    for r in results:
        if r.success:
            print_success(f"{r.path.name} -> {r.device_path}")
        else:
            print_error(f"{r.path.name}: {r.error}")


def run_pipeline(paths: list[str], options: PipelineOptions) -> None:
    """Run the full pipeline: collect -> analyze -> transcode -> sync."""
    # Collect
    files = collect_video_files(paths)
    if not files:
        print_error("No video files found")
        return

    console.print(f"\n[bold]Processing {len(files)} file(s)[/bold]")

    # Analyze
    jobs = analyze(files, options)

    # Display analysis
    print_analysis(jobs)

    failed = [j for j in jobs if j.status == "failed"]
    if failed:
        for j in failed:
            print_error(f"{j.input_path.name}: {j.error}")

    analyzable = [j for j in jobs if j.status == "analyzed"]
    if not analyzable:
        print_error("No files could be analyzed")
        return

    # Interactive audio + subtitle selection (skip in -y mode)
    if not options.non_interactive:
        for job in analyzable:
            _prompt_audio_selection(job)
            _prompt_subtitle_selection(job)

    # Dry run — stop here
    if options.dry_run:
        lines = []
        for job in analyzable:
            action = "transcode" if job.decision and job.decision.needs_transcode else "remux"
            if job.decision and not job.decision.needs_transcode and not job.decision.needs_remux:
                action = "copy"
            lines.append(f"{job.input_path.name}: {action}")
        lines.append(f"Quality: {options.quality}")
        lines.append(f"HW accel: {options.hw_accel}")
        lines.append(f"Metadata: {'TMDb' if options.tmdb_key else 'filename only'}")
        print_dry_run(lines)
        return

    # Confirm
    if not options.non_interactive:
        try:
            answer = console.input("\n  Proceed? [Y/n] ").strip().lower()
            if answer and answer != "y":
                console.print("  Aborted.")
                return
        except (EOFError, KeyboardInterrupt):
            console.print("\n  Aborted.")
            return

    # Transcode
    transcode_all(analyzable, options)

    ready = [j for j in analyzable if j.status == "ready"]
    if not ready:
        print_error("No files were successfully transcoded")
        return

    for job in ready:
        size_mb = job.output_path.stat().st_size / 1048576 if job.output_path else 0
        print_success(f"Transcoded: {job.input_path.name} ({size_mb:.1f} MB)")

    # Output mode — save locally, don't sync
    if options.output_path:
        for job in ready:
            print_success(f"Saved: {job.output_path}")
        return

    # Sync
    try:
        sync_all(ready, verbose=options.verbose)
    except KeyboardInterrupt:
        console.print("\n  Interrupted.")
        return
    except MediaPorterError as e:
        print_error(f"Sync failed: {e}")
        for job in ready:
            if job.output_path:
                print_warning(f"File saved at: {job.output_path}")
        return

    # Cleanup temp files
    if not options.keep_files and not options.output_path:
        for job in ready:
            if job.output_path and job.output_path != job.input_path:
                job.output_path.unlink(missing_ok=True)

    console.print("\n[bold]Done.[/bold]")
