"""Pipeline orchestration: probe -> transcode -> tag -> sync."""

from __future__ import annotations

import os
import shutil
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from queue import Queue

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
    temp_dir: Path | None = None  # mkdtemp dir to remove on cleanup (None if output_path is user-specified)
    selected_audio: list[int] | None = None  # indices into media_info.audio_streams
    selected_subtitles: list[int] | None = None  # indices into subtitle_streams
    selected_external_subs: list[int] | None = None  # indices into external_subtitles
    status: str = "pending"
    error: str | None = None


@dataclass
class PipelineStats:
    """Wall-clock metrics and byte counters for a sync run.

    Populated incrementally by transcode_and_sync — the uploader thread
    records timings under sync_infos_lock and the summary is printed after
    everything is registered.
    """
    pipeline_start: float
    pipeline_end: float | None = None
    transcode_timings: dict[str, tuple[float, float]] = field(default_factory=dict)
    upload_timings: dict[str, tuple[float, float]] = field(default_factory=dict)
    upload_bytes: dict[str, int] = field(default_factory=dict)
    mac_free_before: int | None = None
    mac_free_after: int | None = None
    device_free_before: int | None = None
    device_free_after: int | None = None
    device_total: int | None = None
    device_name: str | None = None


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


def _transcode_one(
    job: FileJob,
    options: PipelineOptions,
    task_id,
    progress,
    stats: PipelineStats | None = None,
) -> None:
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
        tmpdir = Path(tempfile.mkdtemp(prefix="mediaporter-"))
        job.temp_dir = tmpdir
        output = tmpdir / f"{job.input_path.stem}.m4v"

    job.status = "transcoding"

    t_start = time.monotonic()

    def on_progress(pct: float) -> None:
        progress.update(task_id, completed=pct * 100)

    try:
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
            verbose=options.verbose,
        )
    finally:
        if stats is not None:
            stats.transcode_timings[job.input_path.name] = (t_start, time.monotonic())

    job.output_path = output
    job.status = "transcoded"

    # Tag
    if job.metadata:
        from mediaporter.tagger import tag_file
        tag_file(output, job.metadata, job.media_info)

    job.status = "ready"


def _partition_jobs(jobs: list[FileJob]) -> tuple[list[FileJob], list[FileJob]]:
    """Split analyzed jobs into (needs_work, already_ok).

    Several conditions force a remux even when every stream individually
    copies cleanly:
      - Track selection: the user picked a subset of audio/subtitles.
      - Mixed-codec audio: the selected set has multiple audio codecs, which
        breaks the iPad TV app's language switcher. build_ffmpeg_command
        normalizes to the best codec present (EAC3 > AC3 > AAC).
    """
    from mediaporter.audio import pick_normalization_codec

    for j in jobs:
        if not j.decision or not j.media_info:
            continue

        has_selection = (
            j.selected_audio is not None
            or j.selected_subtitles is not None
            or j.selected_external_subs is not None
        )
        if has_selection and not j.decision.needs_transcode and not j.decision.needs_remux:
            j.decision.needs_remux = True

        audio_idx = (
            j.selected_audio
            if j.selected_audio is not None
            else list(range(len(j.media_info.audio_streams)))
        )
        selected_streams = [j.media_info.audio_streams[i] for i in audio_idx]
        if pick_normalization_codec(selected_streams):
            if not j.decision.needs_transcode and not j.decision.needs_remux:
                j.decision.needs_remux = True

    needs_work = [
        j for j in jobs
        if j.status == "analyzed" and j.decision
        and (j.decision.needs_transcode or j.decision.needs_remux)
    ]
    already_ok = [
        j for j in jobs
        if j.status == "analyzed" and j.decision
        and not j.decision.needs_transcode and not j.decision.needs_remux
    ]
    return needs_work, already_ok


def _fmt_bytes(n: int | None) -> str:
    """Human-readable byte count, e.g. 1.41 GB / 2.53 TB."""
    if n is None:
        return "?"
    tb = 1024 ** 4
    gb = 1024 ** 3
    mb = 1024 ** 2
    kb = 1024
    if n >= tb:
        return f"{n / tb:.2f} TB"
    if n >= gb:
        return f"{n / gb:.1f} GB"
    if n >= mb:
        return f"{n / mb:.1f} MB"
    if n >= kb:
        return f"{n / kb:.1f} KB"
    return f"{n} B"


def _fmt_duration(seconds: float) -> str:
    """Human-readable wall clock duration, e.g. '14m 32s'."""
    seconds = max(0.0, seconds)
    if seconds < 60:
        return f"{seconds:.1f}s"
    mins, secs = divmod(int(seconds), 60)
    hours, mins = divmod(mins, 60)
    if hours:
        return f"{hours}h {mins}m {secs}s"
    return f"{mins}m {secs}s"


def _fmt_speed_bps(bps: float) -> str:
    """Human-readable bytes/sec + gigabit equivalent."""
    mb = bps / (1024 ** 2)
    gbit = bps * 8 / 1e9
    return f"{mb:.1f} MB/s ({gbit:.2f} Gbps)"


def _check_disk_space(
    sources: list[Path],
    device_free: int | None,
    mac_free: int | None,
) -> str | None:
    """Return a human-readable error string if either side is too small.

    Uses sum of source file sizes * 1.1 as an upper bound for the transcoded
    M4V outputs. That's pessimistic for most files (M4V with AAC is typically
    smaller than MKV with DTS/EAC3), so false negatives are more likely than
    silent overflows.
    """
    total = sum(p.stat().st_size for p in sources if p.exists())
    needed = int(total * 1.1)

    problems = []
    if mac_free is not None and mac_free < needed:
        problems.append(
            f"Mac temp space: need ~{_fmt_bytes(needed)}, have {_fmt_bytes(mac_free)} free"
        )
    if device_free is not None and device_free < needed:
        problems.append(
            f"Device free space: need ~{_fmt_bytes(needed)}, have {_fmt_bytes(device_free)} free"
        )
    if problems:
        return "\n  ".join(problems)
    return None


def _print_summary(stats: PipelineStats, sync_infos_count: int) -> None:
    """Print a wall-clock + throughput summary for a completed run."""
    if not stats.pipeline_end:
        stats.pipeline_end = time.monotonic()

    total_wall = stats.pipeline_end - stats.pipeline_start

    transcode_wall = 0.0
    if stats.transcode_timings:
        starts = [s for s, _ in stats.transcode_timings.values()]
        ends = [e for _, e in stats.transcode_timings.values()]
        transcode_wall = max(ends) - min(starts)

    upload_wall = 0.0
    upload_total_bytes = 0
    peak_file_speed = 0.0
    avg_file_speed = 0.0
    if stats.upload_timings:
        starts = [s for s, _ in stats.upload_timings.values()]
        ends = [e for _, e in stats.upload_timings.values()]
        upload_wall = max(ends) - min(starts)
        upload_total_bytes = sum(stats.upload_bytes.values())
        per_file_speeds = []
        for title, (s, e) in stats.upload_timings.items():
            dur = max(e - s, 1e-6)
            b = stats.upload_bytes.get(title, 0)
            per_file_speeds.append(b / dur)
        if per_file_speeds:
            peak_file_speed = max(per_file_speeds)
        if upload_wall > 0:
            avg_file_speed = upload_total_bytes / upload_wall

    console.print("\n[bold]Summary[/bold]")
    console.print(f"  Total time:      {_fmt_duration(total_wall)}")
    if transcode_wall > 0:
        console.print(
            f"  Transcoding:     {_fmt_duration(transcode_wall)}"
            f"  [dim]({len(stats.transcode_timings)} file(s) in parallel)[/dim]"
        )
    if upload_wall > 0:
        console.print(
            f"  Upload:          {_fmt_duration(upload_wall)}"
            f"  [dim]({sync_infos_count} file(s))[/dim]"
        )
    if upload_total_bytes > 0:
        console.print(f"  Transferred:     {_fmt_bytes(upload_total_bytes)}")
    if peak_file_speed > 0:
        console.print(f"  Peak file speed: [cyan]{_fmt_speed_bps(peak_file_speed)}[/cyan]")
    if avg_file_speed > 0 and abs(avg_file_speed - peak_file_speed) > 1:
        console.print(f"  Avg sustained:   {_fmt_speed_bps(avg_file_speed)}")

    if stats.mac_free_before is not None or stats.device_free_before is not None:
        console.print("\n  [bold]Disk space[/bold]")
        mac_label = "Mac temp"
        dev_label = stats.device_name or "iPad/iPhone"
        width = max(len(mac_label), len(dev_label))

    if stats.mac_free_before is not None:
        after = stats.mac_free_after if stats.mac_free_after is not None else stats.mac_free_before
        delta = after - stats.mac_free_before
        sign = "+" if delta >= 0 else "-"
        console.print(
            f"    {mac_label:<{width}}  {_fmt_bytes(after)} free"
            f"  [dim]({sign}{_fmt_bytes(abs(delta))})[/dim]"
        )
    if stats.device_free_before is not None:
        after = stats.device_free_after if stats.device_free_after is not None else stats.device_free_before
        used_delta = stats.device_free_before - after
        of_total = (
            f" / {_fmt_bytes(stats.device_total)}" if stats.device_total else ""
        )
        console.print(
            f"    {dev_label:<{width}}  {_fmt_bytes(after)} free{of_total}"
            f"  [dim](-{_fmt_bytes(max(0, used_delta))})[/dim]"
        )


def _prepare_already_ok(jobs: list[FileJob]) -> None:
    """Tag already-compatible files (copy to temp first) and mark them ready."""
    for job in jobs:
        if job.metadata:
            tmpdir = Path(tempfile.mkdtemp(prefix="mediaporter-"))
            job.temp_dir = tmpdir
            tmp = tmpdir / f"{job.input_path.stem}.m4v"
            shutil.copy2(job.input_path, tmp)
            job.output_path = tmp
            from mediaporter.tagger import tag_file
            tag_file(tmp, job.metadata, job.media_info)
        else:
            job.output_path = job.input_path
        job.status = "ready"


def transcode_all(jobs: list[FileJob], options: PipelineOptions) -> None:
    """Transcode + tag files in parallel. Used for --output mode (no sync)."""
    needs_work, already_ok = _partition_jobs(jobs)
    _prepare_already_ok(already_ok)

    if not needs_work:
        return

    workers = options.jobs or min(os.cpu_count() or 2, len(needs_work))

    with create_transcode_progress() as progress:
        task_ids = {}
        for job in needs_work:
            task_ids[job.input_path] = progress.add_task(job.input_path.name, total=100)

        executor = ThreadPoolExecutor(max_workers=workers)
        futs = {}
        try:
            for job in needs_work:
                fut = executor.submit(
                    _transcode_one, job, options, task_ids[job.input_path], progress
                )
                futs[fut] = job

            for fut in as_completed(futs):
                job = futs[fut]
                try:
                    fut.result()
                    progress.update(task_ids[job.input_path], completed=100)
                except Exception as e:
                    job.status = "failed"
                    job.error = str(e)
        except KeyboardInterrupt:
            from mediaporter.transcode import cancel_all
            for f in futs:
                f.cancel()
            cancel_all()  # terminate ffmpeg so workers unblock
            raise
        finally:
            executor.shutdown(wait=True)


def transcode_and_sync(jobs: list[FileJob], options: PipelineOptions) -> None:
    """Pipelined transcode + sync.

    Transcoding runs in a thread pool while a dedicated uploader thread drains
    a queue of completed transcodes and streams each file to the device as
    soon as it's ready. Registration happens in a short ATC session at the
    end, after every file is on the device.

    Before any ffmpeg is launched we verify both the Mac's temp filesystem
    and the device have enough free space for the worst-case output size,
    and we record wall-clock metrics for a summary at the very end.
    """
    from mediaporter.exceptions import SyncError
    from mediaporter.sync import (
        afc_upload_one,
        discover_device,
        make_sync_file_info,
        NativeAFC,
        register_uploaded_files,
    )
    from mediaporter.sync.device import query_device_details, query_device_disk_space
    from mediaporter.transcode import cancel_all
    from rich.console import Group
    from rich.live import Live

    needs_work, already_ok = _partition_jobs(jobs)
    _prepare_already_ok(already_ok)

    to_process = already_ok + needs_work  # everything that should reach the device
    if not to_process:
        print_warning("Nothing to sync")
        return

    stats = PipelineStats(pipeline_start=time.monotonic())

    # Discover device up front so we fail fast before running any ffmpeg.
    try:
        device = discover_device()
    except SyncError as e:
        print_error(f"Device not found: {e}")
        return

    # Populate device name for the summary (best-effort).
    try:
        query_device_details(device)
    except Exception:
        pass
    stats.device_name = device.name or "iPad/iPhone"

    # Preflight disk space check — Mac temp + device.
    sources = [j.input_path for j in to_process]
    try:
        mac_free = shutil.disk_usage(tempfile.gettempdir()).free
        stats.mac_free_before = mac_free
    except Exception:
        mac_free = None

    device_disk = None
    try:
        device_disk = query_device_disk_space(device)
    except Exception:
        device_disk = None

    if device_disk:
        stats.device_free_before, stats.device_total = device_disk

    problem = _check_disk_space(sources, stats.device_free_before, mac_free)
    if problem:
        print_error(f"Insufficient free space:\n  {problem}")
        return

    # Show the preflight status so the user knows what we saw.
    if stats.mac_free_before is not None or stats.device_free_before is not None:
        console.print("[dim]Free space:[/dim]", end=" ")
        parts = []
        if stats.mac_free_before is not None:
            parts.append(f"Mac temp {_fmt_bytes(stats.mac_free_before)}")
        if stats.device_free_before is not None:
            parts.append(f"{stats.device_name} {_fmt_bytes(stats.device_free_before)}")
        console.print("[dim]" + " · ".join(parts) + "[/dim]")

    upload_queue: Queue = Queue()
    sync_infos: list = []        # _SyncFileInfo for every successfully uploaded job
    sync_infos_lock = threading.Lock()

    transcode_progress = create_transcode_progress()
    upload_progress = create_sync_progress()
    progress_group = Group(transcode_progress, upload_progress)

    transcode_task_ids: dict[Path, int] = {}
    upload_task_ids: dict[str, int] = {}
    upload_tasks_lock = threading.Lock()

    def _upload_progress_cb(title: str, sent: int, total: int) -> None:
        with upload_tasks_lock:
            tid = upload_task_ids.get(title)
            if tid is None:
                tid = upload_progress.add_task(title, total=total)
                upload_task_ids[title] = tid
        upload_progress.update(tid, completed=sent, total=total)

    def _uploader() -> None:
        """Single-threaded AFC uploader — drains the queue until it sees None."""
        try:
            with NativeAFC(device.handle) as afc:
                while True:
                    job = upload_queue.get()
                    try:
                        if job is None:
                            return
                        if job.status != "ready" or not job.output_path:
                            continue
                        item = _build_sync_item(job)
                        if not item:
                            job.status = "failed"
                            job.error = "could not build sync item"
                            continue
                        info = make_sync_file_info(item)
                        u_start = time.monotonic()
                        try:
                            afc_upload_one(afc, info, progress_cb=_upload_progress_cb)
                        except Exception as e:
                            job.status = "failed"
                            job.error = f"upload: {e}"
                            continue
                        u_end = time.monotonic()
                        with sync_infos_lock:
                            sync_infos.append(info)
                            stats.upload_timings[item.title] = (u_start, u_end)
                            stats.upload_bytes[item.title] = item.file_size
                        job.status = "uploaded"
                    finally:
                        upload_queue.task_done()
        except Exception as e:
            # AFC connection itself failed — drain queue and mark remaining failed.
            print_error(f"AFC connection lost: {e}")
            while True:
                try:
                    j = upload_queue.get_nowait()
                except Exception:
                    return
                try:
                    if j is None:
                        return
                    j.status = "failed"
                    j.error = f"afc: {e}"
                finally:
                    upload_queue.task_done()

    workers = options.jobs or min(os.cpu_count() or 2, max(1, len(needs_work)))

    uploader_thread = threading.Thread(target=_uploader, name="mediaporter-uploader", daemon=True)
    interrupted = False

    with Live(progress_group, console=console, refresh_per_second=10):
        for job in needs_work:
            transcode_task_ids[job.input_path] = transcode_progress.add_task(
                job.input_path.name, total=100
            )

        uploader_thread.start()

        # Already-compatible files: enqueue for upload immediately so they
        # start transferring while ffmpeg works on the rest.
        for job in already_ok:
            upload_queue.put(job)

        executor = ThreadPoolExecutor(max_workers=workers) if needs_work else None
        futs: dict = {}
        try:
            if executor:
                for job in needs_work:
                    fut = executor.submit(
                        _transcode_one, job, options,
                        transcode_task_ids[job.input_path], transcode_progress, stats,
                    )
                    futs[fut] = job

                for fut in as_completed(futs):
                    job = futs[fut]
                    try:
                        fut.result()
                        transcode_progress.update(
                            transcode_task_ids[job.input_path], completed=100
                        )
                        upload_queue.put(job)
                    except Exception as e:
                        job.status = "failed"
                        job.error = str(e)
        except KeyboardInterrupt:
            interrupted = True
            for f in futs:
                f.cancel()
            cancel_all()  # terminate in-flight ffmpeg so workers unblock
        finally:
            if executor:
                executor.shutdown(wait=True)
            upload_queue.put(None)  # sentinel — uploader will exit
            uploader_thread.join()

    if interrupted:
        raise KeyboardInterrupt()

    failed_jobs = [j for j in to_process if j.status not in ("ready", "uploaded")]
    for j in failed_jobs:
        print_error(f"{j.input_path.name}: {j.error or 'failed'}")

    if not sync_infos:
        print_warning("No files were successfully uploaded")
        stats.pipeline_end = time.monotonic()
        _print_summary(stats, 0)
        return

    console.print(f"\n[bold]Registering {len(sync_infos)} file(s) on device...[/bold]")
    results = register_uploaded_files(device, sync_infos, verbose=options.verbose)
    for r in results:
        if r.success:
            print_success(f"{r.path.name} -> {r.device_path}")
        else:
            print_error(f"{r.path.name}: {r.error}")

    # Capture post-sync disk space snapshots for the summary.
    try:
        stats.mac_free_after = shutil.disk_usage(tempfile.gettempdir()).free
    except Exception:
        pass
    try:
        after = query_device_disk_space(device)
        if after:
            stats.device_free_after = after[0]
    except Exception:
        pass

    stats.pipeline_end = time.monotonic()
    _print_summary(stats, len(sync_infos))


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
            console.print(f"\n[bold]{job.input_path.name}[/bold]")
            _prompt_audio_selection(job)
            _prompt_subtitle_selection(job)

    # Display analysis AFTER selection so it reflects the actual plan
    print_analysis(analyzable)

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

    # Output mode — transcode then save locally, don't sync
    if options.output_path:
        try:
            transcode_all(analyzable, options)
        except KeyboardInterrupt:
            console.print("\n  Interrupted.")
            return

        ready = [j for j in analyzable if j.status == "ready"]
        if not ready:
            print_error("No files were successfully transcoded")
            return
        for job in ready:
            size_mb = job.output_path.stat().st_size / 1048576 if job.output_path else 0
            print_success(f"Transcoded: {job.input_path.name} ({size_mb:.1f} MB)")
            print_success(f"Saved: {job.output_path}")
        return

    # Sync mode — transcode and upload in parallel, register at the end
    try:
        transcode_and_sync(analyzable, options)
    except KeyboardInterrupt:
        console.print("\n  Interrupted.")
        return
    except MediaPorterError as e:
        print_error(f"Sync failed: {e}")
        for job in analyzable:
            if job.output_path:
                print_warning(f"File saved at: {job.output_path}")
        return

    # Cleanup temp files
    if not options.keep_files:
        for job in analyzable:
            if job.temp_dir:
                shutil.rmtree(job.temp_dir, ignore_errors=True)
            elif job.output_path and job.output_path != job.input_path:
                job.output_path.unlink(missing_ok=True)

    console.print("\n[bold]Done.[/bold]")
