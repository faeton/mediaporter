"""End-to-end pipeline: probe → transcode → tag → transfer → inject."""

from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path

from mediaporter.compat import evaluate_compatibility
from mediaporter.exceptions import MediaPorterError
from mediaporter.metadata import EpisodeMetadata, MovieMetadata
from mediaporter.probe import MediaInfo, probe_file
from mediaporter.progress import (
    console,
    create_transcode_progress,
    create_transfer_progress,
    print_dry_run,
    print_error,
    print_file_info,
    print_success,
    print_warning,
)
from mediaporter.subtitles import scan_external_subtitles


@dataclass
class PipelineOptions:
    """Options for the processing pipeline."""
    media_type: str | None = None
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
    device_udid: str | None = None


def _collect_video_files(path: str) -> list[Path]:
    """Collect video files from a path (file or directory)."""
    video_extensions = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".flv",
                        ".webm", ".ts", ".mts", ".m2ts", ".mpg", ".mpeg", ".vob"}
    p = Path(path)
    if p.is_file():
        return [p]
    elif p.is_dir():
        files = []
        for f in sorted(p.iterdir()):
            if f.suffix.lower() in video_extensions and f.is_file():
                files.append(f)
        return files
    return []


def _process_single_file(input_path: Path, options: PipelineOptions) -> None:
    """Process a single video file through the full pipeline."""
    # Step 1: Probe
    media_info = probe_file(input_path)
    media_info = scan_external_subtitles(media_info)
    decision = evaluate_compatibility(media_info)

    # Determine output path
    if options.output_path:
        output_path = Path(options.output_path)
        if output_path.is_dir():
            output_path = output_path / f"{input_path.stem}.m4v"
    else:
        output_path = Path(tempfile.mkdtemp()) / f"{input_path.stem}.m4v"

    # Build action description
    if decision.needs_transcode:
        action = "transcode → tag → transfer"
    elif decision.needs_remux:
        action = "remux → tag → transfer"
    else:
        action = "tag → transfer"

    print_file_info(input_path.name, action)

    # Log stream info
    for s in media_info.video_streams:
        act = decision.stream_actions.get(s.index, "?")
        console.print(f"  Video: {s.codec_name} {s.width}x{s.height} → {act}")
    for s in media_info.audio_streams:
        act = decision.stream_actions.get(s.index, "?")
        lang = s.language or "und"
        console.print(f"  Audio: {s.codec_name} {s.channels}ch [{lang}] → {act}")
    for s in media_info.subtitle_streams:
        act = decision.stream_actions.get(s.index, "skip")
        lang = s.language or "und"
        console.print(f"  Sub:   {s.codec_name} [{lang}] → {act}")
    for ext in media_info.external_subtitles:
        console.print(f"  Sub:   {ext.path.name} [{ext.language}] → embed")

    # Warn about bitmap subtitles
    from mediaporter.subtitles import is_bitmap_subtitle
    bitmap_subs = [s for s in media_info.subtitle_streams if is_bitmap_subtitle(s.codec_name)]
    if bitmap_subs:
        if options.burn_bitmap_subs:
            print_warning(f"Bitmap subs ({len(bitmap_subs)} tracks) will be burned in")
        else:
            print_warning(f"Bitmap subs ({len(bitmap_subs)} tracks) will be skipped (use --burn-bitmap-subs to burn in)")

    # Dry run — stop here
    if options.dry_run:
        lines = [
            f"Input:  {input_path}",
            f"Output: {output_path}",
            f"Transcode: {'yes' if decision.needs_transcode else 'remux only'}",
            f"Quality: {options.quality}",
            f"HW accel: {options.hw_accel}",
            f"Subtitles: {options.subtitle_mode}",
        ]
        if options.fetch_metadata:
            lines.append(f"Metadata: TMDb lookup {'(key set)' if options.tmdb_key else '(no key!)'}")
        print_dry_run(lines)
        return

    # Step 2: Transcode
    from mediaporter.transcode import transcode

    with create_transcode_progress() as progress:
        task = progress.add_task("Transcoding...", total=100)

        def on_transcode_progress(pct: float) -> None:
            progress.update(task, completed=pct * 100)

        transcode(
            media_info=media_info,
            decision=decision,
            output_path=output_path,
            quality=options.quality,
            hw_accel=options.hw_accel,
            subtitle_mode=options.subtitle_mode,
            burn_bitmap_subs=options.burn_bitmap_subs,
            progress_callback=on_transcode_progress,
        )

    print_success(f"Transcoded → {output_path.name} ({output_path.stat().st_size / 1048576:.1f} MB)")

    # Step 3: Metadata
    metadata = None
    if options.fetch_metadata:
        from mediaporter.metadata import lookup_metadata

        try:
            metadata = lookup_metadata(
                path=input_path,
                media_type=options.media_type,
                show_override=options.show_override,
                season_override=options.season_override,
                episode_override=options.episode_override,
                api_key=options.tmdb_key,
                non_interactive=options.non_interactive,
            )
        except MediaPorterError as e:
            print_warning(f"Metadata lookup failed: {e}")

    if metadata:
        from mediaporter.tagger import tag_file
        tag_file(output_path, metadata, media_info)
        if isinstance(metadata, EpisodeMetadata):
            print_success(f"Tagged: {metadata.show_name} S{metadata.season:02d}E{metadata.episode:02d} — {metadata.episode_title or 'untitled'}")
        else:
            print_success(f"Tagged: {metadata.title} ({metadata.year or '?'})")
    else:
        print_warning("No metadata applied")

    # Step 4: Transfer to device (skip if --output was specified)
    if options.output_path:
        print_success(f"Saved to {output_path}")
        return

    try:
        from mediaporter.device import get_device
        from mediaporter.transfer import push_to_device

        lockdown = get_device(options.device_udid)

        with create_transfer_progress() as progress:
            task = progress.add_task("Transferring...", total=output_path.stat().st_size)

            def on_transfer_progress(sent: int, total: int) -> None:
                progress.update(task, completed=sent)

            remote_filename, fxx_dir = push_to_device(lockdown, output_path, on_transfer_progress)

        print_success(f"Transferred → {fxx_dir}/{remote_filename}")

        # Step 5: MediaLibrary.sqlitedb injection
        if metadata:
            try:
                from mediaporter.mediadb import (
                    pull_media_db, push_media_db, inject_item, trigger_reindex,
                )
                import tempfile as tf

                db_dir = Path(tf.mkdtemp())
                db_path = pull_media_db(lockdown, db_dir)

                # Get file info for DB entry
                file_size = output_path.stat().st_size
                duration_ms = media_info.duration * 1000 if media_info.duration else 0
                width = media_info.video_streams[0].width if media_info.video_streams else None
                height = media_info.video_streams[0].height if media_info.video_streams else None

                item_pid = inject_item(
                    db_path, remote_filename, fxx_dir, metadata,
                    file_size, duration_ms, width, height,
                )
                print_success(f"DB entry created (pid={item_pid})")

                push_media_db(lockdown, db_dir)
                print_success("Database pushed back to device")

                trigger_reindex(lockdown)
                print_success("Re-index triggered — check TV app!")

            except MediaPorterError as e:
                print_warning(f"DB injection failed: {e}")
            except Exception as e:
                print_warning(f"DB injection failed: {e}")

    except MediaPorterError as e:
        print_error(f"Transfer failed: {e}")
        print_warning(f"File saved at: {output_path}")
        return

    # Cleanup
    if not options.keep_files and not options.output_path:
        output_path.unlink(missing_ok=True)


def run_pipeline(path: str, options: PipelineOptions) -> None:
    """Run the full pipeline for a file or directory."""
    files = _collect_video_files(path)
    if not files:
        print_error(f"No video files found in {path}")
        return

    console.print(f"\n[bold]Processing {len(files)} file(s)[/bold]")

    for i, file_path in enumerate(files, 1):
        console.print(f"\n[dim]({i}/{len(files)})[/dim]")
        try:
            _process_single_file(file_path, options)
        except MediaPorterError as e:
            print_error(f"Failed: {e}")
        except KeyboardInterrupt:
            print_warning("Interrupted by user")
            break

    console.print("\n[bold]Done.[/bold]")
