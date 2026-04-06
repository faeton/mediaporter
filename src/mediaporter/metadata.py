"""Metadata lookup: filename parsing (guessit) + TMDb API search."""

from __future__ import annotations

import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from mediaporter.exceptions import MetadataError


@dataclass
class MovieMetadata:
    """Metadata for a movie."""
    title: str
    year: str | None = None
    genre: str | None = None
    overview: str | None = None
    long_overview: str | None = None
    director: str | None = None
    network: str | None = None
    poster_url: str | None = None
    poster_data: bytes | None = None
    tmdb_id: int | None = None


@dataclass
class EpisodeMetadata:
    """Metadata for a TV episode."""
    show_name: str
    season: int
    episode: int
    episode_title: str | None = None
    episode_id: str | None = None  # e.g., "S01E05"
    year: str | None = None
    genre: str | None = None
    overview: str | None = None
    long_overview: str | None = None
    network: str | None = None
    poster_url: str | None = None
    poster_data: bytes | None = None
    show_poster_url: str | None = None
    show_poster_data: bytes | None = None
    tmdb_show_id: int | None = None


def parse_filename(path: Path) -> dict:
    """Parse a video filename to extract title, year, season, episode, etc."""
    try:
        from guessit import guessit
    except ImportError:
        raise MetadataError("guessit not installed. Run: pip install guessit")

    return dict(guessit(path.name))


def search_movie(title: str, year: str | None = None, api_key: str | None = None) -> list[MovieMetadata]:
    """Search TMDb for a movie by title and optional year."""
    if not api_key:
        raise MetadataError("TMDb API key required. Set TMDB_API_KEY or use --tmdb-key.")

    try:
        import tmdbsimple as tmdb
    except ImportError:
        raise MetadataError("tmdbsimple not installed. Run: pip install tmdbsimple")

    tmdb.API_KEY = api_key
    search = tmdb.Search()
    params = {"query": title}
    if year:
        params["year"] = year
    search.movie(**params)

    results = []
    for item in search.results[:5]:
        genres = ""
        if item.get("genre_ids"):
            # We'd need a genre lookup; use first genre_id description for now
            genres = ""  # simplified; tagger will handle

        results.append(MovieMetadata(
            title=item.get("title", title),
            year=item.get("release_date", "")[:4] or None,
            overview=item.get("overview", "")[:255],
            long_overview=item.get("overview"),
            poster_url=f"https://image.tmdb.org/t/p/w500{item['poster_path']}" if item.get("poster_path") else None,
            tmdb_id=item.get("id"),
        ))

    return results


def search_tv_episode(
    show_name: str, season: int, episode: int, api_key: str | None = None
) -> EpisodeMetadata | None:
    """Search TMDb for a TV episode."""
    if not api_key:
        raise MetadataError("TMDb API key required. Set TMDB_API_KEY or use --tmdb-key.")

    try:
        import tmdbsimple as tmdb
    except ImportError:
        raise MetadataError("tmdbsimple not installed. Run: pip install tmdbsimple")

    tmdb.API_KEY = api_key

    # Search for the show
    search = tmdb.Search()
    search.tv(query=show_name)
    if not search.results:
        return None

    show = search.results[0]
    show_id = show["id"]

    # Get episode details
    try:
        ep = tmdb.TV_Episodes(show_id, season, episode)
        ep_info = ep.info()
    except Exception:
        return None

    # Get show details for genre/network
    try:
        show_detail = tmdb.TV(show_id)
        show_info = show_detail.info()
        genre = show_info.get("genres", [{}])[0].get("name") if show_info.get("genres") else None
        network = show_info.get("networks", [{}])[0].get("name") if show_info.get("networks") else None
    except Exception:
        genre = None
        network = None

    show_poster_url = (
        f"https://image.tmdb.org/t/p/w500{show['poster_path']}" if show.get("poster_path") else None
    )
    ep_still_url = (
        f"https://image.tmdb.org/t/p/w500{ep_info['still_path']}" if ep_info.get("still_path") else None
    )

    return EpisodeMetadata(
        show_name=show.get("name", show_name),
        season=season,
        episode=episode,
        episode_title=ep_info.get("name"),
        episode_id=f"S{season:02d}E{episode:02d}",
        year=show.get("first_air_date", "")[:4] or None,
        genre=genre,
        overview=ep_info.get("overview", "")[:255] if ep_info.get("overview") else None,
        long_overview=ep_info.get("overview"),
        network=network,
        poster_url=ep_still_url or show_poster_url,
        show_poster_url=show_poster_url,
        tmdb_show_id=show_id,
    )


def download_poster(url: str) -> bytes | None:
    """Download a poster image from URL."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "mediaporter/0.1"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read()
    except Exception:
        return None


def lookup_metadata(
    path: Path,
    media_type: str | None = None,
    show_override: str | None = None,
    season_override: int | None = None,
    episode_override: int | None = None,
    api_key: str | None = None,
    non_interactive: bool = False,
) -> MovieMetadata | EpisodeMetadata | None:
    """Full metadata lookup pipeline: parse filename → search TMDb → download poster."""
    guess = parse_filename(path)

    # Determine type
    guessed_type = guess.get("type", "movie")
    if media_type:
        guessed_type = "episode" if media_type == "tv" else "movie"

    title = show_override or guess.get("title", path.stem)
    year = guess.get("year")

    if guessed_type == "episode" or season_override is not None or episode_override is not None:
        season = season_override or guess.get("season", 1)
        episode = episode_override or guess.get("episode", 1)
        show = show_override or guess.get("title", path.stem)

        if api_key:
            meta = search_tv_episode(show, season, episode, api_key)
            if meta:
                # Download poster
                if meta.poster_url:
                    meta.poster_data = download_poster(meta.poster_url)
                if meta.show_poster_url and meta.show_poster_url != meta.poster_url:
                    meta.show_poster_data = download_poster(meta.show_poster_url)
                return meta

        # Fallback: return basic metadata from filename
        return EpisodeMetadata(
            show_name=show,
            season=season,
            episode=episode,
            episode_id=f"S{season:02d}E{episode:02d}",
        )

    else:
        # Movie
        if api_key:
            results = search_movie(title, str(year) if year else None, api_key)
            if results:
                meta = results[0]  # auto-pick first for now
                if meta.poster_url:
                    meta.poster_data = download_poster(meta.poster_url)
                return meta

        # Fallback
        return MovieMetadata(title=title, year=str(year) if year else None)
