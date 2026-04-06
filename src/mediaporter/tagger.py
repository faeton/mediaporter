"""M4V metadata tag writer using mutagen."""

from __future__ import annotations

from pathlib import Path

from mutagen.mp4 import MP4, MP4Cover

from mediaporter.compat import get_hd_flag
from mediaporter.metadata import EpisodeMetadata, MovieMetadata
from mediaporter.probe import MediaInfo


def tag_movie(m4v_path: Path, meta: MovieMetadata, media_info: MediaInfo | None = None) -> None:
    """Write movie metadata tags to an M4V file."""
    video = MP4(str(m4v_path))

    video["stik"] = [9]  # Movie
    video["\xa9nam"] = [meta.title]

    if meta.year:
        video["\xa9day"] = [meta.year]
    if meta.genre:
        video["\xa9gen"] = [meta.genre]
    if meta.overview:
        video["desc"] = [meta.overview]
    if meta.long_overview:
        video["ldes"] = [meta.long_overview]
    if meta.director:
        video["\xa9ART"] = [meta.director]

    # HD flag from video resolution
    if media_info and media_info.video_streams:
        vs = media_info.video_streams[0]
        video["hdvd"] = [get_hd_flag(vs.width, vs.height)]

    # Cover art
    if meta.poster_data:
        video["covr"] = [MP4Cover(meta.poster_data, imageformat=MP4Cover.FORMAT_JPEG)]

    video.save()


def tag_tv_episode(m4v_path: Path, meta: EpisodeMetadata, media_info: MediaInfo | None = None) -> None:
    """Write TV episode metadata tags to an M4V file."""
    video = MP4(str(m4v_path))

    # MANDATORY for TV Shows tab
    video["stik"] = [10]  # TV Show
    video["tvsh"] = [meta.show_name]
    video["tvsn"] = [meta.season]
    video["tves"] = [meta.episode]

    # Episode ID string
    if meta.episode_id:
        video["tven"] = [meta.episode_id]

    # Episode title
    if meta.episode_title:
        video["\xa9nam"] = [meta.episode_title]
    else:
        video["\xa9nam"] = [f"Episode {meta.episode}"]

    # Album = "Show Name, Season N"
    video["\xa9alb"] = [f"{meta.show_name}, Season {meta.season}"]

    # Sort show name
    video["sosn"] = [meta.show_name]

    # Track number = episode number
    video["trkn"] = [(meta.episode, 0)]

    if meta.year:
        video["\xa9day"] = [meta.year]
    if meta.genre:
        video["\xa9gen"] = [meta.genre]
    if meta.network:
        video["tvnn"] = [meta.network]
    if meta.overview:
        video["desc"] = [meta.overview]
    if meta.long_overview:
        video["ldes"] = [meta.long_overview]

    # HD flag
    if media_info and media_info.video_streams:
        vs = media_info.video_streams[0]
        video["hdvd"] = [get_hd_flag(vs.width, vs.height)]

    # Cover art — prefer episode-specific, fall back to show poster
    poster = meta.poster_data or meta.show_poster_data
    if poster:
        video["covr"] = [MP4Cover(poster, imageformat=MP4Cover.FORMAT_JPEG)]

    video.save()


def tag_file(
    m4v_path: Path,
    metadata: MovieMetadata | EpisodeMetadata,
    media_info: MediaInfo | None = None,
) -> None:
    """Tag an M4V file with the appropriate metadata type."""
    if isinstance(metadata, EpisodeMetadata):
        tag_tv_episode(m4v_path, metadata, media_info)
    else:
        tag_movie(m4v_path, metadata, media_info)
